import Foundation
@preconcurrency import Network

actor StoreRuntimeSockets {
    private var next = 1
    private var sockets: [Int: RuntimeSocket] = [:]

    private func approved(_ host: String) -> Bool {
        let names = ["gsa.apple.com", "www.apple.com", "updates.cdn-apple.com", "mesu.apple.com", "wkms-public.apple.com", "fcs-keys-pub-prod.cdn-apple.com"]
        return names.contains(host) || host.range(of: #"^(?:[a-z0-9-]+\.)*(?:itunes\.apple\.com|mzstatic\.com)$"#, options: .regularExpression) != nil
    }
    func open(_ host: String) async throws -> Int {
        guard approved(host), sockets.count < 32 else { throw StoreRuntimeError.unavailable }
        let id = next
        next += 1
        let socket = RuntimeSocket(host: host)
        sockets[id] = socket
        do { try await socket.start(); return id }
        catch { socket.close(); sockets.removeValue(forKey: id); throw StoreRuntimeError.unavailable }
    }
    func read(_ id: Int, count: Int) async throws -> Data {
        guard let socket = sockets[id], (1 ... 65536).contains(count) else { throw StoreRuntimeError.unavailable }
        return try await socket.read(count: count)
    }
    func write(_ id: Int, data: Data) async throws -> Int {
        guard let socket = sockets[id], data.count <= 1024 * 1024 else { throw StoreRuntimeError.unavailable }
        try await socket.write(data)
        return data.count
    }
    func close(_ id: Int) { sockets.removeValue(forKey: id)?.close() }
    func closeAll() { sockets.values.forEach { $0.close() }; sockets.removeAll() }
}

/// This layer never performs TLS or receives plaintext Apple HTTP requests.
private final class RuntimeSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Asspp.Store.TCP")
    private let lock = NSLock()
    private var startup: CheckedContinuation<Void, Error>?
    private var timer: DispatchWorkItem?

    init(host: String) { connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tcp) }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { startup = continuation }
            let timeout = DispatchWorkItem { [weak self] in self?.complete(StoreRuntimeError.unavailable); self?.connection.cancel() }
            timer = timeout
            queue.asyncAfter(deadline: .now() + 15, execute: timeout)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.complete()
                case .failed, .cancelled: self?.complete(StoreRuntimeError.unavailable)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
    private func complete(_ error: Error? = nil) {
        let continuation = lock.withLock { let value = startup; startup = nil; return value }
        guard let continuation else { return }
        timer?.cancel()
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
    func read(count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: count) { data, _, _, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if error != nil { continuation.resume(throwing: StoreRuntimeError.unavailable) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: StoreRuntimeError.unavailable) }
                else { continuation.resume() }
            })
        }
    }
    func close() { complete(StoreRuntimeError.unavailable); connection.cancel() }
}
