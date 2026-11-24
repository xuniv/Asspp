import Foundation
import Observation

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
                try UnfairPlayArtifactStore.shared.register(source: source, url: destination, package: package, operation: action,
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
