import Foundation
#if canImport(Security)
    import Security
#endif

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
        let offline = InstallationProtocol.endpoint(port: 5678, path: "/synthetic.plist", host: .offline)
        precondition(offline.host == "asspp.localhost" && offline.port == 5678 && offline.scheme == "https")
        let root = try InstallationProtocol.certificateDER(pem: Data(contentsOf: URL(fileURLWithPath: "Certificates/localhost.qaq.wiki/rootCA.pem")))
        let profile = try InstallationProtocol.certificateProfile(certificate: root)
        let parsed = try PropertyListSerialization.propertyList(from: profile, format: nil) as! [String: Any]
        precondition(parsed["PayloadType"] as? String == "Configuration")
        let payload = (parsed["PayloadContent"] as! [[String: Any]])[0]
        precondition(payload["PayloadType"] as? String == "com.apple.security.root" && payload["PayloadContent"] as? Data == root)
        let offlineProfile = try InstallationProtocol.certificateProfile(certificate: root, host: .offline)
        let offlinePlist = try PropertyListSerialization.propertyList(from: offlineProfile, format: nil) as! [String: Any]
        precondition(offlinePlist["PayloadIdentifier"] as? String == "wiki.qaq.Asspp.offline-installation")
        precondition(offlinePlist["PayloadIdentifier"] as? String != parsed["PayloadIdentifier"] as? String)
        let offlinePayload = (offlinePlist["PayloadContent"] as! [[String: Any]])[0]
        precondition(offlinePayload["PayloadContent"] as? Data == root)
        precondition(!String(data: offlineProfile, encoding: .utf8)!.contains("PRIVATE KEY"))
        if CommandLine.arguments.count == 2 {
            try checkOfflineChain(directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        }
        precondition(!String(data: profile, encoding: .utf8)!.contains("PRIVATE KEY"))
        do { _ = try InstallationProtocol.certificateDER(pem: Data("invalid".utf8)); fatalError("Accepted invalid certificate data") }
        catch InstallationError.certificateUnavailable {}
        let info: [String: Any] = ["CFBundleIdentifier": "example.app", "CFBundleVersion": "42", "CFBundleShortVersionString": "1.2", "CFBundleDisplayName": "Test & Install", "CFBundleSupportedPlatforms": ["iPhoneOS"]]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
            let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            let metadata = try InstallationProtocol.importedMetadata(decoded)
            precondition(metadata.bundleID == "example.app" && metadata.build == "42" && metadata.name == "Test & Install")
        }
        for field in ["CFBundleIdentifier", "CFBundleVersion", "CFBundleSupportedPlatforms"] {
            var malformed = info
            malformed.removeValue(forKey: field)
            if field == "CFBundleVersion" { malformed.removeValue(forKey: "CFBundleShortVersionString") }
            do { _ = try InstallationProtocol.importedMetadata(malformed); fatalError("Accepted invalid IPA metadata") }
            catch InstallationError.invalidIPA {}
        }
        var otherPlatform = info
        otherPlatform["CFBundleSupportedPlatforms"] = ["AppleTVOS"]
        do { _ = try InstallationProtocol.importedMetadata(otherPlatform); fatalError("Accepted a tvOS IPA") }
        catch InstallationError.invalidIPA {}
        print("Authentication endpoint, retry, credential-error, install URL, and CA profile checks passed.")
    }

    private static func checkOfflineChain(directory: URL) throws {
        #if canImport(Security)
            let identity = try OfflineInstallationIdentity.make()
            let issued = SecCertificateCreateWithData(nil, identity.leaf as CFData)!
            let authority = SecCertificateCreateWithData(nil, identity.root as CFData)!
            func trusted(_ host: String) -> Bool {
                var trust: SecTrust?
                precondition(SecTrustCreateWithCertificates(issued, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess)
                // This synthetic CA is an explicit anchor only in the test process.
                precondition(SecTrustSetAnchorCertificates(trust!, [authority] as CFArray) == errSecSuccess)
                SecTrustSetNetworkFetchAllowed(trust!, false)
                return SecTrustEvaluateWithError(trust!, nil)
            }
            precondition(trusted("asspp.localhost"))
            precondition(!trusted("app.localhost.qaq.wiki"))
        #else
            func openssl(_ args: [String], succeeds: Bool = true) throws -> Data {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                precondition((process.terminationStatus == 0) == succeeds, "unexpected OpenSSL result: \(args[0])")
                return bytes
            }
            let root = directory.appendingPathComponent("test-ca.pem")
            let leaf = directory.appendingPathComponent("test-leaf.pem")
            let hostname = "asspp.localhost"
            let key = directory.appendingPathComponent("test-rsa.pem")
            let leafKey = directory.appendingPathComponent("server-rsa.pem")
            _ = try openssl(["genrsa", "-out", key.path, "2048"])
            _ = try openssl(["genrsa", "-out", leafKey.path, "2048"])
            let keyBytes = try openssl(["rsa", "-in", key.path, "-RSAPublicKey_out", "-outform", "DER"])
            let leafBytes = try openssl(["rsa", "-in", leafKey.path, "-RSAPublicKey_out", "-outform", "DER"])
            let body = directory.appendingPathComponent("tbs.der")
            let authority = "Asspp Test CA"
            let now = Date()
            func issue(_ name: String, serial: UInt8, publicKey: Data, host: String?) throws -> Data {
                try LocalCertificate.issue(
                    name: name, issuer: authority, publicKey: publicKey, serial: Data([serial]),
                    from: now.addingTimeInterval(-300), until: now.addingTimeInterval(86400), host: host,
                ) { bytes in
                    try bytes.write(to: body)
                    return try openssl(["dgst", "-sha256", "-sign", key.path, body.path])
                }
            }
            try LocalCertificate.pem(issue(authority, serial: 0x81, publicKey: keyBytes, host: nil), label: "CERTIFICATE").write(to: root)
            try LocalCertificate.pem(issue(hostname, serial: 0x82, publicKey: leafBytes, host: hostname), label: "CERTIFICATE").write(to: leaf)
            _ = try openssl(["verify", "-purpose", "sslserver", "-verify_hostname", hostname, "-CAfile", root.path, leaf.path])
            _ = try openssl(["verify", "-purpose", "sslserver", "-verify_hostname", "app.localhost.qaq.wiki", "-CAfile", root.path, leaf.path], succeeds: false)
            let details = try openssl(["x509", "-in", leaf.path, "-noout", "-text"])
            precondition(String(decoding: details, as: UTF8.self).contains("DNS:asspp.localhost"))
        #endif
        print("Offline local CA chain, server usage and hostname checks passed.")
    }
}
