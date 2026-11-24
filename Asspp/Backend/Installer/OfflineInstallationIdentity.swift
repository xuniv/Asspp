#if canImport(Security)
    import Foundation
    import Security

    struct OfflineInstallationIdentity: Codable {
        let leaf: Data
        let root: Data
        let leafKey: Data
        let expires: Date

        private static let name = "Asspp Offline Installation CA"
        #if os(iOS)
            private static let lock = NSLock()

            static func load(replace: Bool = false) throws -> Self {
                try lock.withLock {
                    let manager = FileManager.default
                    var directory = URL.applicationSupportDirectory.appendingPathComponent("AssppInstallation", isDirectory: true)
                    let file = directory.appendingPathComponent("OfflineIdentity.plist")
                    if !replace, manager.fileExists(atPath: file.path) {
                        let identity = try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: file))
                        guard identity.expires > Date() else { throw InstallationError.offlineIdentityExpired }
                        return identity
                    }

                    let identity = try make()
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                        .posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                    ])
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try directory.setResourceValues(values)
                    try PropertyListEncoder().encode(identity).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    return identity
                }
            }

        #endif

        static func make() throws -> Self {
            func key() throws -> SecKey {
                let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
                guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil) else {
                    throw InstallationError.certificateUnavailable
                }
                return key
            }

            func representation(_ key: SecKey) throws -> Data {
                guard let data = SecKeyCopyExternalRepresentation(key, nil) else { throw InstallationError.certificateUnavailable }
                return data as Data
            }

            let authority = try key()
            let leafKey = try key()
            let now = Date()
            let start = now.addingTimeInterval(-300)
            let end = now.addingTimeInterval(365 * 24 * 3600)
            func issue(name: String, key: SecKey, until expires: Date, host: String? = nil) throws -> Data {
                guard let publicKey = SecKeyCopyPublicKey(key) else { throw InstallationError.certificateUnavailable }
                var serial = [UInt8](repeating: 0, count: 16)
                let status = serial.withUnsafeMutableBytes { bytes in
                    SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
                }
                guard status == errSecSuccess else { throw InstallationError.certificateUnavailable }
                return try LocalCertificate.issue(
                    name: name, issuer: Self.name, publicKey: representation(publicKey), serial: Data(serial),
                    from: start, until: expires, host: host,
                ) { data in
                    guard let signature = SecKeyCreateSignature(authority, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, nil) else {
                        throw InstallationError.certificateUnavailable
                    }
                    return signature as Data
                }
            }

            let root = try issue(name: name, key: authority, until: now.addingTimeInterval(5 * 365 * 24 * 3600))
            let leaf = try issue(name: InstallationHost.offline.rawValue, key: leafKey, until: end, host: InstallationHost.offline.rawValue)
            // The signing key for the root was never persisted.
            return Self(leaf: leaf, root: root, leafKey: try representation(leafKey), expires: end)
        }
    }
#endif
