import Foundation
import Observation

/// The pinned Store engine runs in-process on one background queue.
/// StoreRuntimeClient persists private state in Keychain after each call.
@MainActor
@Observable
final class StoreRuntime {
    static let shared = StoreRuntime()
    private(set) var stage = ""
    private let worker = NativeStoreRuntimeWorker()
    private var prepared = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var progressText: String {
        stage == "preparing"
            ? String(localized: "Preparing Apple authentication. The first run may take several minutes.")
            : String(localized: "Communicating with Apple…")
    }

    func run(_ input: String) async throws -> String {
        try Task.checkCancellation()
        await lock()
        defer { stage = ""; unlock() }
        try Task.checkCancellation()
        guard let bundle = Bundle.main.url(forResource: "StoreRuntime", withExtension: "bundle") else {
            throw StoreRuntimeError.startup("bundle-missing")
        }
        let assets = bundle.appendingPathComponent("assets", isDirectory: true)
        stage = prepared ? "request" : "preparing"
        let result = try await worker.run(input, assets: assets.path)
        prepared = true
        // A running native call cannot be interrupted. Return completed state
        // even if cancellation arrived meanwhile, so Keychain retains it.
        return result
    }

    private func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}

/// Only this dedicated queue accesses configuredAssets and the blocking C ABI.
/// The Swift cooperative executor never executes an interpreter call.
private final class NativeStoreRuntimeWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wiki.qaq.Asspp.StoreRuntime", qos: .userInitiated)
    private var configuredAssets: String?
    private static let inputLimit = 8 * 1024 * 1024
    private static let outputLimit = 12 * 1024 * 1024

    private struct Request: Decodable { let operation: String }
    private struct Response: Decodable {
        let ok: Bool
        let error: String?
        let status: Int?
    }

    func run(_ input: String, assets: String) async throws -> String {
        // Embedded NUL would truncate the C string before native JSON parsing.
        guard input.utf8.count <= Self.inputLimit, !input.utf8.contains(0),
              let data = input.data(using: .utf8),
              let request = try? JSONDecoder().decode(Request.self, from: data),
              Self.operations.contains(request.operation)
        else { throw StoreRuntimeError.operation("invalid_request", 0) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if let configured = self.configuredAssets {
                        guard configured == assets else { throw StoreRuntimeError.startup("native-configuration") }
                    } else {
                        let code = assets.withCString { asspp_runtime_configure($0) }
                        guard code == 0 else { throw StoreRuntimeError.startup("native-configuration") }
                        self.configuredAssets = assets
                    }
                    let bytes = try Self.call(input)
                    guard let response = try? JSONDecoder().decode(Response.self, from: bytes),
                          response.status.map({ $0 == 0 || (100 ... 599).contains($0) }) ?? true,
                          response.ok || response.error != nil,
                          let output = String(data: bytes, encoding: .utf8)
                    else { throw StoreRuntimeError.startup("native-response") }
                    continuation.resume(returning: output)
                } catch let error as StoreRuntimeError {
                    continuation.resume(throwing: error)
                } catch {
                    // Do not propagate decoder/native descriptions or arguments.
                    continuation.resume(throwing: StoreRuntimeError.startup("native-response"))
                }
            }
        }
    }

    private static func call(_ input: String) throws -> Data {
        guard let response = input.withCString({ asspp_runtime_call($0) }) else {
            throw StoreRuntimeError.startup("native-allocation")
        }
        defer { asspp_runtime_free(response) }
        let count = strnlen(response, outputLimit + 1)
        guard (1 ... outputLimit).contains(count) else { throw StoreRuntimeError.startup("native-response-size") }
        return Data(bytes: response, count: count)
    }

    private static let operations: Set<String> = [
        "login", "purchase", "download", "versions", "versionMetadata", "prepare",
        "bridge-preflight", "memory-preflight", "preflight", "adi-preflight",
        "framework-preflight", "network-preflight", "sap-test", "anisette-preflight",
    ]
}

enum StoreRuntimeError: LocalizedError, StoreDiagnosticError {
    case unavailable
    case startup(String)
    case operation(String, Int)

    static func safeOperationCode(_ code: String) -> String {
        operationCodes.contains(code) ? code : "operation_failed"
    }

    private static let operationCodes: Set<String> = [
        "invalid_request", "invalid_device_id", "invalid_state", "invalid_platform",
        "runtime_failed", "runtime_not_configured", "memory_isolation_failed",
        "host_bridge_failed", "asset_preparation_failed", "operation_failed",
        "tls_untrusted_certificate", "tls_hostname_mismatch", "tls_certificate_failed",
        "request_timeout", "connection_closed", "connection_failed",
        "verification_required", "token_expired", "license_required", "license_exists",
    ]

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Apple authentication could not start. Check your connection and try again.")
        case let .startup(code):
            String(localized: "Apple authentication could not start. Check your connection and try again.")
                + " (runtime: \(code))"
        case let .operation(code, status):
            String(localized: "Apple could not complete the request. Try signing in again.")
                + ((100 ... 599).contains(status) ? " (HTTP \(status))" : " (\(Self.safeOperationCode(code)))")
        }
    }

    var diagnostic: String {
        switch self {
        case .unavailable: "unavailable"
        case let .startup(code): code
        case let .operation(code, status): "\(Self.safeOperationCode(code)) http=\((100 ... 599).contains(status) ? status : 0)"
        }
    }
}
