import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@main
struct StoreRuntimeSmoke {
    @MainActor
    static func main() {
        #if os(iOS)
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(StoreRuntimeSmokeDelegate.self))
        #else
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        run()
        app.run()
        #endif
    }

    @MainActor
    static func run() {
        Task { @MainActor in
            do {
                for operation in ["preflight", "adi-preflight", "framework-preflight"] {
                    let input = try JSONSerialization.data(withJSONObject: ["operation": operation, "deviceID": "020000000001"])
                    let output = try await StoreRuntime.shared.run(String(decoding: input, as: UTF8.self))
                    guard let data = output.data(using: .utf8),
                          let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          result["ok"] as? Bool == true
                    else {
                        // Only synthetic offline operations run in this executable.
                        print("Offline guest failure: " + output)
                        fflush(stdout)
                        exit(1)
                    }
                    print("WKWebView \(operation) passed")
                }
                print("Asspp runtime checks passed")
                fflush(stdout)
                exit(0)
            } catch {
                // Synthetic, offline requests only; never retain WKError payloads.
                let code = (error as? StoreRuntimeError)?.diagnostic ?? "unavailable"
                fputs("Bundled WKWebView interpreter check failed: \(code)\n", stderr)
                exit(1)
            }
        }
    }
}

#if os(iOS)
@MainActor
final class StoreRuntimeSmokeDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        StoreRuntimeSmoke.run()
        return true
    }
}
#endif
