import Foundation

enum InstallationHost: String, CaseIterable, Sendable {
    case legacy = "app.localhost.qaq.wiki"
    case offline = "asspp.localhost"

    static let preferenceKey = "InstallationHost"

    static var selected: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .legacy
    }
}

enum InstallationError: LocalizedError {
    case certificateUnavailable, certificateTrustRequired, unreachable, offlineUnreachable, offlineIdentityExpired, linkRejected, invalidIPA

    var errorDescription: String? {
        switch self {
        case .certificateUnavailable: String(localized: "The local installation certificate could not be loaded.")
        case .certificateTrustRequired: String(localized: "Install the Asspp certificate profile in Settings > General > VPN & Device Management, then enable full trust for Asspp Local Installation CA in Settings > General > About > Certificate Trust Settings. Replace any older Asspp certificate profile first.")
        case .unreachable: String(localized: "The local installation server could not be reached. Allow local network access for Asspp and check that app.localhost.qaq.wiki resolves to 127.0.0.1 in your DNS or VPN settings.")
        case .offlineUnreachable: String(localized: "Asspp could not reach asspp.localhost. Check local network access or select the compatible installation domain in Tools.")
        case .offlineIdentityExpired: String(localized: "The offline installation certificate has expired. Replace it and trust the new profile in Tools.")
        case .linkRejected: String(localized: "iOS could not open the installation link. Retry after checking certificate trust and local network permission.")
        case .invalidIPA: String(localized: "Choose an iOS IPA containing one main app with a valid bundle identifier and build version.")
        }
    }
}

enum InstallationProtocol {
    static let hostname = InstallationHost.legacy.rawValue
    static let profilePath = "/Asspp-Local-Installation.mobileconfig"

    struct ImportedMetadata {
        let bundleID: String
        let name: String
        let build: String
    }

    static func importedMetadata(_ info: [String: Any]) throws -> ImportedMetadata {
        func text(_ key: String, limit: Int = 255) -> String? {
            guard let value = info[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= limit, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return value
        }
        guard let bundleID = text("CFBundleIdentifier"),
              bundleID.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$"#, options: .regularExpression) != nil,
              let build = text("CFBundleVersion", limit: 128) ?? text("CFBundleShortVersionString", limit: 128),
              (info["CFBundleSupportedPlatforms"] as? [String] ?? []).contains("iPhoneOS") || (info["DTPlatformName"] as? String)?.lowercased() == "iphoneos"
        else { throw InstallationError.invalidIPA }
        return ImportedMetadata(bundleID: bundleID, name: text("CFBundleDisplayName") ?? text("CFBundleName") ?? bundleID, build: build)
    }

    static func endpoint(port: Int, path: String, host: InstallationHost = .legacy) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host.rawValue
        parts.port = port
        parts.path = path
        return parts.url!
    }

    static func installLink(manifest: URL) -> URL {
        var parts = URLComponents()
        parts.scheme = "itms-services"
        parts.host = ""
        // The port belongs inside the HTTPS manifest URL, never on itms-services.
        parts.queryItems = [URLQueryItem(name: "action", value: "download-manifest"), URLQueryItem(name: "url", value: manifest.absoluteString)]
        return parts.url!
    }

    static func certificateDER(pem: Data) throws -> Data {
        guard let text = String(data: pem, encoding: .utf8),
              let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----"), start.upperBound < end.lowerBound,
              let data = Data(base64Encoded: String(text[start.upperBound ..< end.lowerBound]), options: .ignoreUnknownCharacters), !data.isEmpty
        else { throw InstallationError.certificateUnavailable }
        return data
    }

    static func certificateProfile(certificate: Data, host: InstallationHost = .legacy) throws -> Data {
        let offline = host == .offline
        let identifier = offline ? "wiki.qaq.Asspp.offline-installation" : "wiki.qaq.Asspp.local-installation"
        let name = offline ? "Asspp Offline Installation CA" : "Asspp Local Installation CA"
        return try PropertyListSerialization.data(fromPropertyList: [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": offline ? UUID().uuidString : "442D39AA-42E7-4449-971E-7F59845138B3",
            "PayloadDisplayName": name,
            "PayloadDescription": "Trust the local Asspp installation server. Enable full trust in Certificate Trust Settings after installing this profile.",
            "PayloadOrganization": "Asspp", "PayloadRemovalDisallowed": false,
            "PayloadContent": [[
                "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
                "PayloadIdentifier": identifier + ".root",
                "PayloadUUID": offline ? UUID().uuidString : "3A6C0D63-F6D7-44FB-AD75-04CE18627470",
                "PayloadDisplayName": name,
                "PayloadCertificateFileName": "Asspp-Local-Installation-CA.cer",
                "PayloadContent": certificate,
            ]],
        ], format: .xml, options: 0)
    }
}
