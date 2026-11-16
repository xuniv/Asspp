import ApplePackage
import Foundation

/// Metadata comes from ipatool's framework/AMD/KBSync entitlement flow. IPA
/// transfers and signature injection keep using the existing download manager.
enum StoreDownloadService {
    static func download(account: inout Account, package: AppStore.AppPackage) async throws -> DownloadOutput {
        try await ModernStore.download(account: account, package: package)
    }
    static func versions(account: inout Account, package: AppStore.AppPackage) async throws -> [String] {
        try await ModernStore.versions(account: account, package: package)
    }
    static func versionMetadata(account: inout Account, package: AppStore.AppPackage, versionID: String) async throws -> VersionMetadata {
        try await ModernStore.versionMetadata(account: account, package: package, version: versionID)
    }
}
