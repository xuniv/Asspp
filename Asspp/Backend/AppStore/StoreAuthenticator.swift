import ApplePackage
import Foundation

/// SAP signs every POST. Foundation keeps normal system TLS verification enabled;
/// redirects are explicit so credentials cannot follow an unapproved destination.
actor StoreAuthenticator {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
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
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue(try await signer.sign(body).base64EncodedString(), forHTTPHeaderField: "X-Apple-ActionSignature")
            for (name, value) in cookies.buildCookieHeader(endpoint) { request.setValue(value, forHTTPHeaderField: name) }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) {
                statuses.append(0)
                guard statuses.count < StoreAuthenticationProtocol.attempts else { throw StoreAuthenticationError.exhausted(statuses) }
                rotation = (rotation + 1) % endpoints.count
                endpoint = endpoints[rotation]
                try await Task.sleep(for: .seconds(2))
                continue
            }
            guard let response = response as? HTTPURLResponse, data.count <= 2 * 1024 * 1024 else { throw StoreAuthenticationError.invalidResponse }
            mergeCookies(response)
            if let value = response.value(forHTTPHeaderField: "x-set-apple-store-front")?.split(separator: "-").first { store = String(value) }
            if let value = response.value(forHTTPHeaderField: "pod"), !value.isEmpty { pod = value }
            let dictionary = StoreProtocol.plist(data)
            if StoreAuthenticationProtocol.isTransient(status: response.statusCode, dictionary: dictionary) {
                statuses.append(response.statusCode)
                logger.warning("Sign-in transient response HTTP=\(response.statusCode) attempt=\(statuses.count)")
                guard statuses.count < StoreAuthenticationProtocol.attempts else { throw StoreAuthenticationError.exhausted(statuses) }
                let delay = try StoreAuthenticationProtocol.retryDelay(response.value(forHTTPHeaderField: "Retry-After"))
                rotation = (rotation + 1) % endpoints.count
                endpoint = endpoints[rotation]
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard redirects < 3, let location = response.value(forHTTPHeaderField: "Location"),
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
            guard response.statusCode == 200, failure.isEmpty,
                  let info = dictionary["accountInfo"] as? [String: Any], let address = info["address"] as? [String: Any]
            else { throw StoreAuthenticationError.rejected(message ?? String(localized: "Apple rejected sign-in.")) }
            return try Account(email: email, password: password, appleId: info["appleId"] as? String, store: store,
                               firstName: address["firstName"] as? String, lastName: address["lastName"] as? String,
                               passwordToken: dictionary["passwordToken"] as? String,
                               directoryServicesIdentifier: StoreProtocol.string(dictionary["dsPersonId"]), cookie: cookies, pod: pod)
        }
    }

    private func mergeCookies(_ response: HTTPURLResponse) {
        guard let url = response.url else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String { result[name] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let domain = StoreProtocol.storeCookieDomain(cookie.domain)
            guard let domain, domain == "itunes.apple.com" || domain.hasSuffix(".itunes.apple.com") else { continue }
            cookies.removeAll { $0.name == cookie.name && $0.path == cookie.path && StoreProtocol.storeCookieDomain($0.domain) == domain }
            if let expiry = cookie.expiresDate, expiry <= Date() { continue }
            cookies.append(Cookie(name: cookie.name, value: cookie.value, path: cookie.path, domain: domain,
                                  expiresAt: cookie.expiresDate?.timeIntervalSince1970, httpOnly: cookie.isHTTPOnly, secure: cookie.isSecure))
        }
    }
}
