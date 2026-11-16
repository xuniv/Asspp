import ApplePackage
import CryptoKit
import Foundation
import KeychainAccess

/// Serialize the complete read/execute/save transaction, including across awaits.
/// Provisioning records are private Keychain data, never WebKit or disk files.
actor StoreRuntimeClient {
    static let shared = StoreRuntimeClient()
    private let keychain = Keychain(service: "wiki.qaq.Asspp.StoreRuntime")
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var epochs: [String: Int] = [:]

    private func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func unlock() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
    private func prefix(_ email: String) -> String {
        SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined() + "."
    }
    func remove(email: String) {
        epochs[email, default: 0] += 1
        let start = prefix(email)
        for key in keychain.allKeys() where key.hasPrefix(start) { try? keychain.remove(key) }
    }
    func exchange(_ input: Data, email: String, guid: String) async throws -> Data {
        await lock()
        defer { unlock() }
        let epoch = epochs[email, default: 0]
        let name = prefix(email) + guid.lowercased()
        guard var request = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw StoreRuntimeError.unavailable
        }
        if let state = try keychain.getData(name) {
            request["state"] = try JSONSerialization.jsonObject(with: state)
        }
        request["deviceID"] = guid
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: data, encoding: .utf8) else { throw StoreRuntimeError.unavailable }
        let output = try await StoreRuntime.shared.run(text)
        guard epochs[email, default: 0] == epoch, let bytes = output.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { throw StoreRuntimeError.unavailable }
        if let state = response["state"] as? [String: Any], state["records"] is [String: Any] {
            try keychain.set(JSONSerialization.data(withJSONObject: state), key: name)
        }
        let code = response["error"] as? String ?? "operation_failed"
        if response["ok"] as? Bool != true, code != "license_exists" {
            if code == "verification_required" { throw ApplePackage.AuthenticationError.verificationCodeRequired }
            if code == "license_required" { throw ApplePackageError.licenseRequired }
            throw StoreRuntimeError.operation(code, response["status"] as? Int ?? 0)
        }
        return try JSONSerialization.data(withJSONObject: response["value"] ?? NSNull(), options: [.fragmentsAllowed])
    }
}

/// The facade keeps ApplePackage's public models for the rest of the UI.
enum ModernStore {
    private static func call(_ operation: String, email: String, fields: [String: Any]) async throws -> Data {
        var request = fields
        request["operation"] = operation
        let data = try JSONSerialization.data(withJSONObject: request)
        return try await StoreRuntimeClient.shared.exchange(data, email: email, guid: Configuration.deviceIdentifier)
    }
    static func login(email: String, password: String, code: String, previous: Account?) async throws -> Account {
        let data = try await call("login", email: email, fields: ["Email": email, "Password": password, "Code": code])
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = value["passwordToken"] as? String, !token.isEmpty,
              let dsid = value["directoryServicesIdentifier"] as? String, !dsid.isEmpty
        else { throw StoreRuntimeError.unavailable }
        let name = value["name"] as? String ?? ""
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        let store = (value["storeFront"] as? String)?.split(separator: "-").first.map(String.init) ?? previous?.store ?? ""
        guard !store.isEmpty else { throw StoreRuntimeError.unavailable }
        return Account(email: email, password: password, appleId: value["email"] as? String ?? email, store: store,
                       firstName: parts.first ?? previous?.firstName ?? "",
                       lastName: parts.dropFirst().first ?? previous?.lastName ?? "",
                       passwordToken: token, directoryServicesIdentifier: dsid,
                       cookie: previous?.cookie ?? [], pod: value["pod"] as? String ?? previous?.pod)
    }
    private static func account(_ account: Account) -> [String: Any] {
        var value: [String: Any] = ["email": account.email, "password": account.password,
                                  "passwordToken": account.passwordToken, "directoryServicesIdentifier": account.directoryServicesIdentifier,
                                  "storeFront": account.store, "name": account.firstName + " " + account.lastName]
        if let pod = account.pod { value["pod"] = pod }
        return value
    }
    private static func fields(_ account: Account, package: AppStore.AppPackage, version: String? = nil) -> [String: Any] {
        let software = package.software
        var result: [String: Any] = ["account": self.account(account),
                                    "app": ["trackId": software.id, "bundleId": software.bundleID,
                                            "trackName": software.name, "version": software.version, "price": software.price ?? 0],
                                    "platform": (package.entityType ?? .iPhone).rawValue.lowercased()]
        if let version, !version.isEmpty { result["versionID"] = version }
        return result
    }
    static func download(account: Account, package: AppStore.AppPackage) async throws -> DownloadOutput {
        let data = try await call("download", email: account.email, fields: fields(account, package: package, version: package.externalVersionID))
        return try JSONDecoder().decode(DownloadOutput.self, from: data)
    }
    static func purchase(account: Account, package: AppStore.AppPackage) async throws {
        _ = try await call("purchase", email: account.email, fields: fields(account, package: package))
    }
    static func versions(account: Account, package: AppStore.AppPackage) async throws -> [String] {
        let data = try await call("versions", email: account.email, fields: fields(account, package: package))
        guard let output = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = output["ExternalVersionIdentifiers"] as? [String], !versions.isEmpty
        else { throw StoreRuntimeError.unavailable }
        return versions
    }
    static func versionMetadata(account: Account, package: AppStore.AppPackage, version: String) async throws -> VersionMetadata {
        let data = try await call("versionMetadata", email: account.email, fields: fields(account, package: package, version: version))
        guard let output = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let display = output["DisplayVersion"] as? String,
              let release = output["ReleaseDate"] as? String,
              let date = ISO8601DateFormatter().date(from: release)
        else { throw StoreRuntimeError.unavailable }
        return VersionMetadata(displayVersion: display, releaseDate: date)
    }
}
