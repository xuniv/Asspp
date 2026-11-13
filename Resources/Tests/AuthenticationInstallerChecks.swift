import Foundation

#if os(Linux)
    // Linux Foundation has no localization API; macOS CI also compiles the catalog.
    extension String { init(localized value: String) { self = value } }
#endif

@main
struct AuthenticationInstallerChecks {
    static func main() throws {
        let legacy = StoreAuthenticationProtocol.legacy
        let native = StoreAuthenticationProtocol.native
        let candidates = try StoreAuthenticationProtocol.endpoints(bag: legacy, guid: "synthetic")
        precondition(candidates.count == 2 && candidates[0].host == "buy.itunes.apple.com" && candidates[1].host == "auth.itunes.apple.com")
        let nativeCandidates = try StoreAuthenticationProtocol.endpoints(bag: native, guid: "synthetic")
        precondition(nativeCandidates.count == 2)
        let normalized = try StoreAuthenticationProtocol.approved(URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?guid=old&x=1&guid=old2")!, guid: "new")
        let query = URLComponents(url: normalized, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.filter { $0.name == "guid" }.map(\.value) == ["new"] && normalized.path == legacy.path)
        for invalid in ["http://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/",
                        "https://buy.itunes.apple.com.evil.invalid/WebObjects/MZFinance.woa/wa/authenticate/",
                        "https://user:password@buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/",
                        "https://buy.itunes.apple.com:8080/WebObjects/MZFinance.woa/wa/authenticate/",
                        "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct/", native.absoluteString + "#fragment"] {
            do { _ = try StoreAuthenticationProtocol.endpoints(bag: URL(string: invalid)!, guid: "synthetic"); fatalError("Accepted an unapproved auth endpoint") }
            catch StoreAuthenticationError.invalidEndpoint {}
        }
        for status in [204, 403, 404, 429, 500, 503] {
            precondition(StoreAuthenticationProtocol.isTransient(status: status, dictionary: nil))
            precondition(!StoreAuthenticationProtocol.isTransient(status: status, dictionary: ["failureType": "5005", "customerMessage": "Invalid code"]))
            precondition(!StoreAuthenticationProtocol.isTransient(status: status, dictionary: ["failureType": "", "customerMessage": "MZFinance.BadLogin.Configurator_message"]))
        }
        for status in [200, 301, 302, 401] { precondition(!StoreAuthenticationProtocol.isTransient(status: status, dictionary: nil)) }
        precondition(StoreAuthenticationProtocol.attempts == 8)
        let delays = try [nil, "0", "5", "invalid"].map { try StoreAuthenticationProtocol.retryDelay($0) }
        precondition(delays == [2, 1, 5, 2])
        for value in ["31", "3600", "999999999999999999999999999999"] {
            do { _ = try StoreAuthenticationProtocol.retryDelay(value); fatalError("Ignored Retry-After") }
            catch StoreAuthenticationError.retryLater {}
        }

        let manifest = InstallationProtocol.endpoint(port: 5678, path: "/synthetic.plist")
        let link = InstallationProtocol.installLink(manifest: manifest)
        precondition(link.absoluteString.hasPrefix("itms-services://?"))
        precondition(link.port == nil && (link.host ?? "").isEmpty)
        let linkQuery = URLComponents(url: link, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(linkQuery.first { $0.name == "url" }!.value == manifest.absoluteString && manifest.port == 5678)
        let root = try InstallationProtocol.certificateDER(pem: Data(contentsOf: URL(fileURLWithPath: "Certificates/localhost.qaq.wiki/rootCA.pem")))
        let profile = try InstallationProtocol.certificateProfile(certificate: root)
        let parsed = try PropertyListSerialization.propertyList(from: profile, format: nil) as! [String: Any]
        precondition(parsed["PayloadType"] as? String == "Configuration")
        let payload = (parsed["PayloadContent"] as! [[String: Any]])[0]
        precondition(payload["PayloadType"] as? String == "com.apple.security.root" && payload["PayloadContent"] as? Data == root)
        precondition(!String(data: profile, encoding: .utf8)!.contains("PRIVATE KEY"))
        do { _ = try InstallationProtocol.certificateDER(pem: Data("invalid".utf8)); fatalError("Accepted invalid certificate data") }
        catch InstallationError.certificateUnavailable {}
        print("Authentication endpoint, retry, credential-error, install URL, and CA profile checks passed.")
    }
}
