import Foundation

enum InstallationError: LocalizedError {
    case certificateUnavailable, certificateTrustRequired, unreachable, linkRejected, invalidIPA

    var errorDescription: String? {
        switch self {
        case .certificateUnavailable: String(localized: "The local installation certificate could not be loaded.")
        case .certificateTrustRequired: String(localized: "Install the Asspp certificate profile in Settings > General > VPN & Device Management, then enable full trust for Asspp Local Installation CA in Settings > General > About > Certificate Trust Settings. Replace any older Asspp certificate profile first.")
        case .unreachable: String(localized: "The local installation server could not be reached. Allow local network access for Asspp and check that app.localhost.qaq.wiki resolves to 127.0.0.1 in your DNS or VPN settings.")
        case .linkRejected: String(localized: "iOS could not open the installation link. Retry after checking certificate trust and local network permission.")
        case .invalidIPA: String(localized: "Choose an iOS IPA containing one main app with a valid bundle identifier and build version.")
        }
    }
}

enum InstallationProtocol {
    static let hostname = "app.localhost.qaq.wiki"
    static let profilePath = "/Asspp-Local-Installation.mobileconfig"

    static func endpoint(port: Int, path: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = hostname
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

    static func certificateProfile(certificate: Data) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": "wiki.qaq.Asspp.local-installation",
            "PayloadUUID": "442D39AA-42E7-4449-971E-7F59845138B3",
            "PayloadDisplayName": "Asspp Local Installation",
            "PayloadDescription": "Trust the local Asspp installation server. Enable full trust in Certificate Trust Settings after installing this profile.",
            "PayloadOrganization": "Asspp", "PayloadRemovalDisallowed": false,
            "PayloadContent": [[
                "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
                "PayloadIdentifier": "wiki.qaq.Asspp.local-installation.root",
                "PayloadUUID": "3A6C0D63-F6D7-44FB-AD75-04CE18627470",
                "PayloadDisplayName": "Asspp Local Installation CA",
                "PayloadCertificateFileName": "Asspp-Local-Installation-CA.cer",
                "PayloadContent": certificate,
            ]],
        ], format: .xml, options: 0)
    }
}
