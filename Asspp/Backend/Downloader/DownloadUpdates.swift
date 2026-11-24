import ApplePackage
import Foundation
import Observation

enum DownloadUpdateError: LocalizedError {
    case unknownStorefront, lookupFailed, accountUnavailable, latestUnavailable, transferFailed

    var errorDescription: String? {
        switch self {
        case .unknownStorefront: String(localized: "The original App Store country is unavailable.")
        case .lookupFailed: String(localized: "The latest version could not be checked in this App Store country.")
        case .accountUnavailable: String(localized: "Sign in again with the original account in this App Store country to download the update.")
        case .latestUnavailable: String(localized: "The latest listed version is not available for this download.")
        case .transferFailed: String(localized: "The update did not finish. See the download for its status.")
        }
    }
}

struct DownloadUpdateKey: Hashable {
    let app: String
    let country: String?
    let platform: EntityType

    init(_ manifest: PackageManifest) {
        app = Self.appKey(manifest)
        country = manifest.storefront
        platform = manifest.package.entityType ?? .iPhone
    }

    static func appKey(_ manifest: PackageManifest) -> String {
        let software = manifest.package.software
        return software.bundleID.isEmpty ? "store:\(software.id)" : software.bundleID.lowercased()
    }
}

@MainActor
@Observable
final class DownloadUpdates {
    struct Result {
        let package: AppStore.AppPackage
    }

    struct Batch {
        let total: Int
        let downloadsUpdates: Bool
        var finished = 0
        var found = 0
        var downloaded = 0
        var failed = 0
        var canceled = false
    }

    private(set) var results: [DownloadUpdateKey: Result] = [:]
    private(set) var batch: Batch?
    private(set) var currentTransfer: PackageManifest?
    private(set) var operation: Task<Void, Never>?

    var isRunning: Bool { operation != nil }

    func available(for manifest: PackageManifest) -> AppStore.AppPackage? {
        guard manifest.completed, let result = results[DownloadUpdateKey(manifest)],
              DownloadVersion.compare(result.package.software.version, manifest.version) == .orderedDescending else { return nil }
        return result.package
    }

    func check(_ manifest: PackageManifest) async throws -> Result {
        await manifest.resolveDownloadedVersion()
        let key = DownloadUpdateKey(manifest)
        guard let country = key.country else { throw DownloadUpdateError.unknownStorefront }
        do {
            let original = manifest.package.software
            let software = try await Lookup.lookup(bundleID: original.bundleID, countryCode: country, entityType: key.platform)
            guard !software.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  software.bundleID.caseInsensitiveCompare(original.bundleID) == .orderedSame,
                  original.id <= 0 || software.id == original.id else { throw DownloadUpdateError.lookupFailed }
            try Task.checkCancellation()
            let result = Result(package: .init(software: software, entityType: key.platform))
            results[key] = result
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            results[key] = nil
            throw DownloadUpdateError.lookupFailed
        }
    }

    func downloadLatest(from manifest: PackageManifest, package: AppStore.AppPackage) async throws -> PackageManifest {
        let key = DownloadUpdateKey(manifest)
        guard let country = key.country,
              AppStore.this.eligibleAccounts(for: country).contains(where: { $0.id == manifest.account.id })
        else { throw DownloadUpdateError.accountUnavailable }
        if let existing = Downloads.this.manifests.first(where: {
            DownloadUpdateKey($0) == key && $0.account.id == manifest.account.id
                && DownloadVersion.compare($0.version, package.software.version) != .orderedAscending
                && [.completed, .pending, .downloading, .paused].contains($0.state.status)
        }) {
            if existing.state.status == .paused { Downloads.this.resume(request: existing) }
            return existing
        }
        return try await Downloads.this.startDownload(for: package, accountID: manifest.account.id, expectingLatest: true)
    }

    func startBatch(download: Bool) {
        guard operation == nil else { return }
        let groups = Dictionary(grouping: Downloads.this.manifests.filter { $0.fileSize != nil }, by: DownloadUpdateKey.init)
        guard !groups.isEmpty else { return }
        batch = Batch(total: groups.count, downloadsUpdates: download)
        operation = Task {
            defer {
                currentTransfer = nil
                operation = nil
            }
            for versions in groups.values.sorted(by: { ($0.first?.creation ?? .distantPast) > ($1.first?.creation ?? .distantPast) }) {
                if Task.isCancelled { break }
                for version in versions { await version.resolveDownloadedVersion() }
                guard let manifest = versions.max(by: { a, b in
                    let comparison = DownloadVersion.compare(a.version, b.version)
                    return comparison == .orderedSame ? a.creation < b.creation : comparison == .orderedAscending
                }) else { continue }
                do {
                    _ = try await check(manifest)
                    if let package = available(for: manifest) {
                        batch?.found += 1
                        if download {
                            let transfer = try await downloadLatest(from: manifest, package: package)
                            currentTransfer = transfer
                            await transfer.waitForCompletion(timeout: 3600)
                            try Task.checkCancellation()
                            currentTransfer = nil
                            guard transfer.completed else { throw DownloadUpdateError.transferFailed }
                            batch?.downloaded += 1
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    batch?.failed += 1
                }
                batch?.finished += 1
            }
            batch?.canceled = Task.isCancelled
        }
    }

    func cancelBatch() { operation?.cancel() }
    func dismissBatch() { if !isRunning { batch = nil } }
}
