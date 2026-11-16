import CryptoKit
import Compression
import Foundation

/// Only immutable, pinned public Apple images may enter this disk cache.
enum StoreRuntimeAssets {
    private static let manifest: [String: (Int, String)] = [
        "AppleMediaServices": (14813888, "95f4558aa2c0ccd9f96ed479e336b630b46bf4b4e0baabc1c1ac8c7d55e21ab4"),
        "commerce": (2735088, "c4b2088dd39aeb353f59cb57597902e8317aec66ae7da0414b03c5f932771343"),
        "adid": (3047808, "43419a206c28bc93ecb8884256088d18306a0a462350f83adbced8e60a94e390"),
        "CoreFP": (30764976, "afbc123e688a822d980d5816cc2b52f69fde669d1dca92cf85627e1cbee587f6"),
        "CoreFP.icxs": (7365344, "cb8f55330ec567da3e692dab5f5388bed0312dd9093340477c5759078cc2aa7b"),
        "fairplayd": (17389744, "1e58d37e9602dd0ca5e24b14762063b6c310248b4d3a94272771d815e4ea1784"),
        "FairPlayIOKit": (2132320, "47452960ec010d3a80b02cceec73a65f8a9758850fd0fb7b2fdac7a5d1b81025"),
    ]
    private static func file(_ name: String) throws -> URL {
        guard manifest[name] != nil else { throw StoreRuntimeError.unavailable }
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("Asspp-Store-macOS27-26A434-v5", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
    }
    private static func valid(_ name: String, data: Data) -> Bool {
        guard let spec = manifest[name], data.count == spec.0 else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == spec.1
    }
    static func read(_ name: String) throws -> Data? {
        let url = try file(name)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size == manifest[name]?.0, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           valid(name, data: data) { return data }
        try? FileManager.default.removeItem(at: url)
        guard let expected = manifest[name]?.0,
              let root = Bundle.main.url(forResource: "StoreRuntime", withExtension: "bundle")
        else { throw StoreRuntimeError.unavailable }
        let source = root.appendingPathComponent("assets").appendingPathComponent(name + ".zlib")
        let compressed = try Data(contentsOf: source, options: .mappedIfSafe)
        guard compressed.count >= 6, compressed.count <= 40 * 1024 * 1024,
              compressed[0] == 0x78, compressed[1] & 0x20 == 0,
              (Int(compressed[0]) * 256 + Int(compressed[1])) % 31 == 0
        else { throw StoreRuntimeError.unavailable }
        // Compression.framework consumes raw DEFLATE; remove zlib's header and
        // Adler-32 trailer. The pinned SHA-256 verifies the complete output.
        let payload = compressed.dropFirst(2).dropLast(4)
        var data = Data(count: expected)
        let count = data.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          source.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard count == expected, valid(name, data: data) else { throw StoreRuntimeError.unavailable }
        try? data.write(to: url, options: .atomic)
        return data
    }
    static func write(_ name: String, data: Data) throws {
        guard valid(name, data: data) else { throw StoreRuntimeError.unavailable }
        try? data.write(to: file(name), options: .atomic)
    }
}
