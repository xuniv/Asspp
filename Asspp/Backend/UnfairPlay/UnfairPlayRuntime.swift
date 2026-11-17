import Foundation

enum UnfairPlayOperation: String, Codable, Sendable {
    case modelInspect = "model_inspect"
    case doctor
    case verify
    case decrypt
    case stripAccountData = "strip_account_data"
    case convertIPAMacOS = "convert_ipa_macos"

    var createsIPA: Bool {
        self == .decrypt || self == .stripAccountData || self == .convertIPAMacOS
    }
}

struct UnfairPlayReport: Decodable, Sendable {
    let outputPath: String?
    let plaintextVerified: Bool?
    let encryptedImages: Int?
    let decryptedPages: Int?
    let accountDataStripped: Bool?
    let removedLicenseFiles: Int?
    let removedMetadataFields: Int?
    let modelCount: Int?
    let modelVersions: [Int]?
    let ready: Bool?
}

enum UnfairPlayError: LocalizedError {
    case invalidFile
    case invalidModel
    case modelLimit
    case duplicateModel
    case modelStorage
    case missingModels
    case invalidSelection
    case requiresV2Model
    case outputLimit
    case native(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            String(localized: "Choose a regular IPA file no larger than 8 GiB.")
        case .invalidModel:
            String(localized: "This model is unsupported or cannot be combined with the saved models.")
        case .modelLimit:
            String(localized: "The saved model limit has been reached.")
        case .duplicateModel:
            String(localized: "The selected models are already imported.")
        case .modelStorage:
            String(localized: "Private models could not be accessed. Unlock your device and try again.")
        case .missingModels:
            String(localized: "Import a matching FairPlay model first.")
        case .invalidSelection:
            String(localized: "A V1 model must be selected alone. Deselect the other models before continuing.")
        case .requiresV2Model:
            String(localized: "Select a matching V2 model for encrypted macOS conversion. V1 and V3 models are not supported for this operation.")
        case .outputLimit:
            String(localized: "The processed IPA exceeds the available storage limit.")
        case let .native(code):
            switch code {
            case "invalid_model":
                String(localized: "This model is unsupported or cannot be combined with the saved models.")
            case "invalid_input":
                String(localized: "UnfairPlay could not read a supported IPA.")
            case "output_exists":
                String(localized: "The output already exists. Start a new operation.")
            case "output_limit":
                String(localized: "The processed IPA exceeds the available storage limit.")
            case "canceled":
                String(localized: "The operation was canceled.")
            default:
                String(localized: "UnfairPlay could not complete this operation. Check that the IPA and model belong to the same enrollment and are supported.")
            }
        }
    }
}

/// Only bounded model blobs cross this JSON boundary. IPAs are opened and
/// streamed by the native engine through file paths; no IPA bytes enter Swift.
final class UnfairPlayRuntime: @unchecked Sendable {
    static let shared = UnfairPlayRuntime()
    private let queue = DispatchQueue(label: "wiki.qaq.Asspp.UnfairPlay", qos: .userInitiated)

    private struct Request: Encodable, Sendable {
        let requestID: String
        let operation: UnfairPlayOperation
        let inputPath: String?
        let outputPath: String?
        let models: [Data]
        let stripAccountData: Bool
    }

    private struct Response: Decodable {
        let ok: Bool
        let error: String?
        let value: UnfairPlayReport?
    }

    func run(_ operation: UnfairPlayOperation, input: URL? = nil, output: URL? = nil,
             models: [Data] = [], stripAccountData: Bool = false) async throws -> UnfairPlayReport {
        try Task.checkCancellation()
        guard models.count <= 256, models.allSatisfy({ [4176, 4184, 8708].contains($0.count) }),
              [input, output].compactMap({ $0 }).allSatisfy({ $0.isFileURL && !$0.path.utf8.contains(0) })
        else { throw UnfairPlayError.invalidModel }
        let requestID = UUID().uuidString
        let cancellation = CancellationState()
        let request = Request(requestID: requestID, operation: operation, inputPath: input?.path, outputPath: output?.path,
                              models: models, stripAccountData: stripAccountData)
        return try await withTaskCancellationHandler {
            let report: UnfairPlayReport = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let data = try JSONEncoder().encode(request)
                        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
                            throw UnfairPlayError.invalidModel
                        }
                        try cancellation.check()
                        let bytes = try Self.call(text)
                        try cancellation.check()
                        let response = try JSONDecoder().decode(Response.self, from: bytes)
                        guard response.ok, let value = response.value else {
                            throw UnfairPlayError.native(Self.safeCode(response.error))
                        }
                        continuation.resume(returning: value)
                    } catch is CancellationError {
                        continuation.resume(throwing: UnfairPlayError.native("canceled"))
                    } catch let error as UnfairPlayError {
                        continuation.resume(throwing: error)
                    } catch {
                        // Never propagate native messages, private paths, model
                        // material, decoder context, account IDs or selectors.
                        continuation.resume(throwing: UnfairPlayError.native("processing_failed"))
                    }
                }
            }
            try Task.checkCancellation()
            return report
        } onCancel: {
            cancellation.cancel()
            // Do not enqueue behind the blocking native call. This only
            // cancels this UUID, never Store authentication or another task.
            requestID.withCString { asspp_unfairplay_cancel($0) }
        }
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var canceled = false

        func cancel() { lock.lock(); canceled = true; lock.unlock() }
        func check() throws {
            lock.lock()
            let value = canceled
            lock.unlock()
            if value { throw CancellationError() }
        }
    }

    private static func call(_ input: String) throws -> Data {
        guard let result = input.withCString({ asspp_unfairplay_call($0) }) else {
            throw UnfairPlayError.native("processing_failed")
        }
        defer { asspp_unfairplay_free(result) }
        let count = strnlen(result, 1024 * 1024 + 1)
        guard (1 ... 1024 * 1024).contains(count) else { throw UnfairPlayError.native("processing_failed") }
        return Data(bytes: result, count: count)
    }

    private static func safeCode(_ code: String?) -> String {
        let allowed: Set<String> = ["invalid_request", "invalid_input", "invalid_model", "output_exists",
                                    "unsupported_operation", "processing_failed", "canceled", "output_limit"]
        return code.flatMap { allowed.contains($0) ? $0 : nil } ?? "processing_failed"
    }
}
