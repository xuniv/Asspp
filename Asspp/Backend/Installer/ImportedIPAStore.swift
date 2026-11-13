import Foundation

@MainActor
@Observable
final class ImportedIPAStore {
    struct Item: Identifiable {
        let id: UUID
        let package: AppStore.AppPackage
        let url: URL
        let size: Int64
        let createdAt: Date
    }

    static let shared = ImportedIPAStore()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Asspp-Imported-IPAs", isDirectory: true)
    private let maxBytes: Int64 = 8 * 1024 * 1024 * 1024
    private(set) var items: [Item] = []
    private var timer: Timer?

    private init() {
        // Deliberately separate from persistent downloaded packages and accounts.
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.cleanup() }
        }
    }

    func add(_ source: URL) async throws {
        cleanup()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard source.pathExtension.lowercased() == "ipa", values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, Int64(size) <= maxBytes else { throw InstallationError.invalidIPA }
        let id = UUID()
        let target = directory.appendingPathComponent(id.uuidString).appendingPathExtension("ipa")
        do {
            let package = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source, to: target)
                return try StorePackageValidator.importedPackage(at: target)
            }.value
            // Evict only after the replacement file has passed validation.
            while items.reduce(Int64(size), { $0 + $1.size }) > maxBytes, let oldest = items.last { remove(oldest) }
            items.insert(Item(id: id, package: package, url: target, size: Int64(size), createdAt: Date()), at: 0)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
    }

    func cleanup() {
        let expired = items.filter { $0.createdAt < Date().addingTimeInterval(-24 * 3600) || !FileManager.default.fileExists(atPath: $0.url.path) }
        expired.forEach(remove)
    }
}
