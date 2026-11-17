import Foundation
import Observation

struct UnfairPlayArtifact: Identifiable {
    let id: UUID
    let source: URL
    let url: URL
    let package: AppStore.AppPackage
    let operation: UnfairPlayOperation
    let stripped: Bool
    let report: UnfairPlayReport
    let size: Int64
    let createdAt: Date
}

/// Processed copies have their own private, temporary location. Downloaded and
/// imported originals are never replaced or added to a different account.
@MainActor
@Observable
final class UnfairPlayArtifactStore {
    static let shared = UnfairPlayArtifactStore()
    static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Asspp-UnfairPlay", isDirectory: true)
    private(set) var items: [UnfairPlayArtifact] = []

    private init() {
        try? FileManager.default.removeItem(at: directory)
        try? prepareDirectory(directory)
    }

    func destination(_ operation: UnfairPlayOperation, stripped: Bool) throws -> URL {
        cleanup()
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try prepareDirectory(folder)
        let name: String
        switch operation {
        case .decrypt: name = stripped ? "Decrypted-Redacted.ipa" : "Decrypted.ipa"
        case .stripAccountData: name = "Redacted.ipa"
        case .convertIPAMacOS: name = "macOS.ipa"
        default: name = "Result.ipa"
        }
        return folder.appendingPathComponent(name)
    }

    func register(source: URL, url: URL, package: AppStore.AppPackage, operation: UnfairPlayOperation,
                  stripped: Bool, report: UnfairPlayReport, size: Int64) {
        while items.reduce(size, { $0 + $1.size }) > Self.maximumBytes, let oldest = items.last { remove(oldest) }
        items.insert(UnfairPlayArtifact(id: UUID(), source: source, url: url, package: package, operation: operation,
                                       stripped: stripped, report: report, size: size, createdAt: Date()), at: 0)
    }

    func outputs(for source: URL) -> [UnfairPlayArtifact] { items.filter { $0.source == source } }

    func remove(_ item: UnfairPlayArtifact) {
        discard(item.url)
        items.removeAll { $0.id == item.id }
    }

    func discard(_ url: URL) {
        guard url.deletingLastPathComponent().deletingLastPathComponent() == directory else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func cleanup() {
        let expired = items.filter { $0.createdAt < Date().addingTimeInterval(-24 * 3600) || !FileManager.default.fileExists(atPath: $0.url.path) }
        expired.forEach(remove)
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

@MainActor
@Observable
final class UnfairPlaySession {
    private var task: Task<Void, Never>?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var report: UnfairPlayReport?
    private(set) var operation: UnfairPlayOperation?

    func start(_ action: UnfairPlayOperation, source: URL, package: AppStore.AppPackage,
               stripAccountData: Bool = false) {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await perform(action, source: source, package: package, stripAccountData: stripAccountData)
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func perform(_ action: UnfairPlayOperation, source: URL, package: AppStore.AppPackage,
                 stripAccountData: Bool = false) async {
        guard !busy else { return }
        busy = true
        error = nil
        report = nil
        operation = action
        var destination: URL?
        let maximumBytes = UnfairPlayArtifactStore.maximumBytes
        defer { busy = false }
        do {
            try Task.checkCancellation()
            let models = try UnfairPlayModelStore.shared.modelData(for: action)
            if action == .decrypt || action == .verify || action == .convertIPAMacOS {
                guard !models.isEmpty else { throw UnfairPlayError.missingModels }
            }
            let valid = try await Task.detached(priority: .userInitiated) {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                return source.isFileURL && source.pathExtension.lowercased() == "ipa" && values.isRegularFile == true
                    && values.isSymbolicLink != true && (values.fileSize.map { $0 > 0 && Int64($0) <= maximumBytes } ?? false)
            }.value
            try Task.checkCancellation()
            guard valid else { throw UnfairPlayError.invalidFile }
            if action.createsIPA { destination = try UnfairPlayArtifactStore.shared.destination(action, stripped: stripAccountData) }
            let result = try await UnfairPlayRuntime.shared.run(action, input: source, output: destination,
                                                               models: models, stripAccountData: stripAccountData)
            if let destination {
                guard result.outputPath == destination.path else { throw UnfairPlayError.native("processing_failed") }
                let size = try await Task.detached(priority: .userInitiated) {
                    let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                          size > 0, Int64(size) <= maximumBytes else { throw UnfairPlayError.outputLimit }
                    try StorePackageValidator.validate(at: destination, package: package)
                    return Int64(size)
                }.value
                try Task.checkCancellation()
                UnfairPlayArtifactStore.shared.register(source: source, url: destination, package: package, operation: action,
                                                       stripped: stripAccountData || action == .stripAccountData, report: result, size: size)
            }
            report = result
        } catch {
            if let destination { UnfairPlayArtifactStore.shared.discard(destination) }
            self.error = (error is CancellationError ? UnfairPlayError.native("canceled") :
                error as? UnfairPlayError ?? .native("processing_failed")).localizedDescription
        }
    }
}
