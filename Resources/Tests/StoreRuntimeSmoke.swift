import AppKit
import Foundation

@main
struct StoreRuntimeSmoke {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                for operation in ["preflight", "adi-preflight", "framework-preflight"] {
                    let input = try JSONSerialization.data(withJSONObject: ["operation": operation, "deviceID": "020000000001"])
                    let output = try await StoreRuntime.shared.run(String(decoding: input, as: UTF8.self))
                    guard let data = output.data(using: .utf8),
                          let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          result["ok"] as? Bool == true
                    else { fatalError("Bundled interpreter check failed") }
                    print("WKWebView \(operation) passed")
                }
                exit(0)
            } catch {
                // Synthetic, offline requests only; never retain WKError payloads.
                fputs("Bundled WKWebView interpreter check failed\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
