import Foundation
import Observation

struct UnfairPlayArtifact: Identifiable {
    struct Record: Codable {
        let sourceID: String
        let package: AppStore.AppPackage
        let operation: UnfairPlayOperation
        let stripped: Bool
        let report: UnfairPlayReport
        let createdAt: Date
    }

    let id: UUID
    let url: URL
    let size: Int64
    let record: Record
    var package: AppStore.AppPackage { record.package }
    var operation: UnfairPlayOperation { record.operation }
    var stripped: Bool { record.stripped }
    var report: UnfairPlayReport { record.report }
    var createdAt: Date { record.createdAt }
}

@MainActor
@Observable
final class UnfairPlayArtifactStore {
    static let shared = UnfairPlayArtifactStore()
    static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Asspp/ProcessedIPAs", isDirectory: true)
    private var staging: URL { directory.appendingPathComponent(".staging", isDirectory: true) }
    private(set) var items: [UnfairPlayArtifact] = []

    private init() {
        // Anything still in staging was interrupted before the atomic move.
        try? FileManager.default.removeItem(at: staging)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
        ) else { return }
        items = folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let saved = try? Self.readRecord(folder.appendingPathComponent("metadata.json")),
                  saved.operation.createsIPA else { return nil }
            let url = folder.appendingPathComponent(Self.filename(saved.operation, stripped: saved.stripped))
            guard let size = Self.fileSize(url) else { return nil }
            return UnfairPlayArtifact(id: id, url: url, size: size, record: saved)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    func destination(_ operation: UnfairPlayOperation, stripped: Bool) throws -> URL {
        try prepareDirectory(directory)
        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try prepareDirectory(folder)
        return folder.appendingPathComponent(Self.filename(operation, stripped: stripped))
    }

    func register(source: URL, url: URL, package: AppStore.AppPackage, operation: UnfairPlayOperation,
                  stripped: Bool, report: UnfairPlayReport, size: Int64) throws {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent() == staging,
              let id = UUID(uuidString: folder.lastPathComponent) else { throw UnfairPlayError.invalidFile }
        var metadata = package
        metadata.downloadOutput = nil
        var summary = report
        summary.outputPath = nil
        let saved = UnfairPlayArtifact.Record(sourceID: source.lastPathComponent, package: metadata, operation: operation,
                                             stripped: stripped, report: summary, createdAt: Date())
        let data = try JSONEncoder().encode(saved)
        guard data.count <= 512 * 1024 else { throw UnfairPlayError.invalidFile }
        try data.write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        let finalFolder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: finalFolder)
        items.insert(UnfairPlayArtifact(id: id, url: finalFolder.appendingPathComponent(url.lastPathComponent),
                                        size: size, record: saved), at: 0)
    }

    func outputs(for source: URL) -> [UnfairPlayArtifact] {
        items.filter { $0.record.sourceID == source.lastPathComponent }
    }

    func hasDecryptedCopy(of package: AppStore.AppPackage, version: String) -> Bool {
        items.contains { $0.operation == .decrypt && $0.package.software.bundleID == package.software.bundleID
            && DownloadVersion.compare($0.package.software.version, version) == .orderedSame }
    }

    func remove(_ item: UnfairPlayArtifact) throws {
        guard items.contains(where: { $0.id == item.id }) else { return }
        try FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
        items.removeAll { $0.id == item.id }
    }

    func discard(_ url: URL) {
        guard url.deletingLastPathComponent().deletingLastPathComponent() == staging else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, Int64(size) <= maximumBytes else { return nil }
        return Int64(size)
    }

    private static func readRecord(_ url: URL) throws -> UnfairPlayArtifact.Record {
        guard let size = fileSize(url), size <= 512 * 1024 else { throw UnfairPlayError.invalidFile }
        return try JSONDecoder().decode(UnfairPlayArtifact.Record.self, from: Data(contentsOf: url))
    }

    private static func filename(_ operation: UnfairPlayOperation, stripped: Bool) -> String {
        switch operation {
        case .decrypt: stripped ? "Decrypted-Redacted.ipa" : "Decrypted.ipa"
        case .stripAccountData: "Redacted.ipa"
        case .convertIPAMacOS: "macOS.ipa"
        default: "Result.ipa"
        }
    }

    private func prepareDirectory(_ url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
}
