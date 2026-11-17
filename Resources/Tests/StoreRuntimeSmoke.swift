import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@main
struct StoreRuntimeSmoke {
    static var resultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("runtime-smoke-result.txt")
    }

    static func record(_ value: String) {
        // Synthetic check status only: never account/provisioning data.
        try? FileManager.default.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(value.utf8).write(to: resultURL, options: .atomic)
    }

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
                // Check the Swift/C-string request boundary before a guest runs.
                for invalid in ["{}", "{\"operation\":\"unknown\"}", "{}\u{0000}", String(repeating: " ", count: 8 * 1024 * 1024 + 1)] {
                    do {
                        _ = try await StoreRuntime.shared.run(invalid)
                        throw StoreRuntimeError.startup("invalid-request-accepted")
                    } catch StoreRuntimeError.operation("invalid_request", 0) {
                        // Expected; no native operation should receive this input.
                    }
                }
                var operations = ["bridge-preflight", "memory-preflight", "preflight"] + Array(repeating: "adi-preflight", count: 3) + ["framework-preflight"]
                if ProcessInfo.processInfo.environment["ASS_RUNTIME_LIVE_APPLE"] == "1" {
                    operations += ["network-preflight", "sap-test", "anisette-preflight"]
                }
                for operation in operations {
                    record("running:" + operation)
                    print("Native Store runtime \(operation) starting")
                    fflush(stdout)
                    let input = try JSONSerialization.data(withJSONObject: ["operation": operation, "deviceID": "020000000001"])
                    let output = try await StoreRuntime.shared.run(String(decoding: input, as: UTF8.self))
                    guard let data = output.data(using: .utf8),
                          let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          result["ok"] as? Bool == true
                    else {
                        // Even optional public probes must not print state,
                        // signatures, Apple messages or raw native responses.
                        let response = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
                        let code = StoreRuntimeError.safeOperationCode(response?["error"] as? String ?? "operation_failed")
                        print("Native guest failure: " + code)
                        record("failed:guest")
                        fflush(stdout)
                        exit(1)
                    }
                    print("Native Store runtime \(operation) passed")
                    fflush(stdout)
                }
                try await UnfairPlaySmoke.run()
                print("Asspp runtime checks passed")
                record("passed")
                fflush(stdout)
                exit(0)
            } catch {
                // Retain fixed diagnostics only, never native error payloads.
                let code = (error as? StoreRuntimeError)?.diagnostic ?? "unavailable"
                record("failed:" + code)
                fputs("Native Store runtime check failed: \(code)\n", stderr)
                exit(1)
            }
        }
    }
}

#if os(iOS)
@MainActor
final class StoreRuntimeSmokeDelegate: NSObject, UIApplicationDelegate {
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        StoreRuntimeSmoke.record("starting")
        return true
    }

    func application(_: UIApplication, configurationForConnecting session: UISceneSession,
                     options _: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "RuntimeCheck", sessionRole: session.role)
        configuration.delegateClass = StoreRuntimeSmokeSceneDelegate.self
        return configuration
    }
}

@MainActor
final class StoreRuntimeSmokeSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private var started = false

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        StoreRuntimeSmoke.record("scene-connected")
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_: UIScene) {
        guard !started else { return }
        started = true
        StoreRuntimeSmoke.run()
    }
}
#endif
