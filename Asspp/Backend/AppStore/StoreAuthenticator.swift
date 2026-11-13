import ApplePackage
import AsyncHTTPClient
import Foundation

/// SAP signs every POST. The client keeps normal TLS verification enabled;
/// redirects are explicit so credentials cannot follow an unapproved destination.
actor StoreAuthenticator {
    private let signer: SAPSigner
    private let guid: String
    private let endpoints: [URL]
    private var endpoint: URL
    private var cookies: [Cookie]
    private var store: String
    private var pod: String?
    private var busy = false

    init(cookies: [Cookie] = [], previous: Account? = nil) async throws {
        guid = Configuration.deviceIdentifier
        let bag = try await Bag.fetchBag(redirectConfiguration: .disallow)
        endpoints = try StoreAuthenticationProtocol.endpoints(bag: bag.authEndpoint, guid: guid)
        endpoint = endpoints[0]
        signer = try await SAPSigner.connect()
        self.cookies = cookies
        store = previous?.store ?? ""
        pod = previous?.pod
    }

    func authenticate(email: String, password: String, code: String = "") async throws -> Account {
        guard !busy else { throw StoreAuthenticationError.busy }
        busy = true
        defer { busy = false }
        var configuration = HTTPClient.Configuration(redirectConfiguration: .disallow,
                                                     timeout: .init(connect: .seconds(15), read: .seconds(30)))
        // Keep the HTTP/1.1 transport used by ApplePackage and ipatool. Do not
        // inherit ApplePackage's development TLS settings or system cookie jars.
        configuration.httpVersion = .http1Only
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        defer { _ = client.shutdown() }
        var statuses: [Int] = []
        var redirects = 0
        var credentialRetry = false
        var rotation = endpoints.firstIndex(of: endpoint) ?? 0
        let body = try PropertyListSerialization.data(fromPropertyList: [
            "appleId": email, "password": password + code, "guid": guid,
            "attempt": code.isEmpty ? "4" : "2", "rmp": "0", "why": "signIn",
        ], format: .xml, options: 0)

        while true {
            try Task.checkCancellation()
            endpoint = try StoreAuthenticationProtocol.approved(endpoint)
            let signature = try await signer.sign(body)
            let headers = [("User-Agent", Configuration.userAgent), ("Content-Type", "application/x-apple-plist"),
                           ("X-Apple-ActionSignature", signature.base64EncodedString())] + cookies.buildCookieHeader(endpoint)
            let request = try HTTPClient.Request(url: endpoint.absoluteString, method: .POST, headers: .init(headers), body: .data(body))
            let response: HTTPClient.Response
            do {
                response = try await client.execute(request: request).get()
            } catch let error as HTTPClientError where [HTTPClientError.connectTimeout, .readTimeout, .remoteConnectionClosed].contains(error) {
                statuses.append(0)
                guard statuses.count < StoreAuthenticationProtocol.attempts else { throw StoreAuthenticationError.exhausted(statuses) }
                rotation = (rotation + 1) % endpoints.count
                endpoint = endpoints[rotation]
                try await Task.sleep(for: .seconds(2))
                continue
            }
            guard (response.body?.readableBytes ?? 0) <= 2 * 1024 * 1024 else { throw StoreAuthenticationError.invalidResponse }
            let data = response.body.map { Data($0.readableBytesView) } ?? Data()
            let status = Int(response.status.code)
            mergeCookies(response.headers.map { ($0.name, $0.value) }, url: endpoint)
            if let value = response.headers.first(name: "x-set-apple-store-front")?.split(separator: "-").first { store = String(value) }
            if let value = response.headers.first(name: "pod"), !value.isEmpty { pod = value }
            let dictionary = StoreProtocol.plist(data)
            if StoreAuthenticationProtocol.isTransient(status: status, dictionary: dictionary) {
                statuses.append(status)
                logger.warning("Sign-in transient response HTTP=\(status) attempt=\(statuses.count)")
                guard statuses.count < StoreAuthenticationProtocol.attempts else { throw StoreAuthenticationError.exhausted(statuses) }
                let delay = try StoreAuthenticationProtocol.retryDelay(response.headers.first(name: "Retry-After"))
                rotation = (rotation + 1) % endpoints.count
                endpoint = endpoints[rotation]
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            if [301, 302, 303, 307, 308].contains(status) {
                guard redirects < 3, let location = response.headers.first(name: "Location"),
                      let destination = URL(string: location, relativeTo: endpoint)?.absoluteURL else { throw StoreAuthenticationError.invalidEndpoint }
                endpoint = try StoreAuthenticationProtocol.approved(destination, guid: guid)
                redirects += 1
                continue
            }
            guard let dictionary else { throw StoreAuthenticationError.invalidResponse }
            let failure = StoreProtocol.string(dictionary["failureType"])
            let message = (dictionary["dialog"] as? [String: Any])?["explanation"] as? String ?? dictionary["customerMessage"] as? String
            if failure.isEmpty, code.isEmpty, message == "MZFinance.BadLogin.Configurator_message" {
                throw ApplePackage.AuthenticationError.verificationCodeRequired
            }
            if failure == "-5000", !credentialRetry {
                credentialRetry = true
                continue
            }
            guard status == 200, failure.isEmpty,
                  let info = dictionary["accountInfo"] as? [String: Any], let address = info["address"] as? [String: Any]
            else { throw StoreAuthenticationError.rejected(message ?? String(localized: "Apple rejected sign-in.")) }
            return try Account(email: email, password: password, appleId: info["appleId"] as? String, store: store,
                               firstName: address["firstName"] as? String, lastName: address["lastName"] as? String,
                               passwordToken: dictionary["passwordToken"] as? String,
                               directoryServicesIdentifier: StoreProtocol.string(dictionary["dsPersonId"]), cookie: cookies, pod: pod)
        }
    }

    private func mergeCookies(_ headers: [(String, String)], url: URL) {
        for (name, value) in headers where name.lowercased() == "set-cookie" {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url) {
                let domain = StoreProtocol.storeCookieDomain(cookie.domain)
                guard let domain, domain == "itunes.apple.com" || domain.hasSuffix(".itunes.apple.com") else { continue }
                cookies.removeAll { $0.name == cookie.name && $0.path == cookie.path && StoreProtocol.storeCookieDomain($0.domain) == domain }
                if let expiry = cookie.expiresDate, expiry <= Date() { continue }
                cookies.append(Cookie(name: cookie.name, value: cookie.value, path: cookie.path, domain: domain,
                                      expiresAt: cookie.expiresDate?.timeIntervalSince1970, httpOnly: cookie.isHTTPOnly, secure: cookie.isSecure))
            }
        }
    }
}
