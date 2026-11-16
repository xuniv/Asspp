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
                var operations = ["bridge-preflight", "memory-preflight", "preflight"] + Array(repeating: "adi-preflight", count: 3) + ["framework-preflight"]
                if ProcessInfo.processInfo.environment["ASS_RUNTIME_LIVE_APPLE"] == "1" {
                    operations += ["network-preflight", "sap-test", "anisette-preflight"]
                }
                for operation in operations {
                    record("running:" + operation)
                    print("WKWebView \(operation) starting")
                    fflush(stdout)
                    let input = try JSONSerialization.data(withJSONObject: ["operation": operation, "deviceID": "020000000001"])
                    let output = try await StoreRuntime.shared.run(String(decoding: input, as: UTF8.self))
                    guard let data = output.data(using: .utf8),
                          let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          result["ok"] as? Bool == true
                    else {
                        // Only synthetic offline operations run in this executable.
                        print("Offline guest failure: " + output)
                        record("failed:guest")
                        fflush(stdout)
                        exit(1)
                    }
                    print("WKWebView \(operation) passed")
                    fflush(stdout)
                }
                print("Asspp runtime checks passed")
                record("passed")
                fflush(stdout)
                exit(0)
            } catch {
                // Synthetic, offline requests only; never retain WKError payloads.
                let code = (error as? StoreRuntimeError)?.diagnostic ?? "unavailable"
                record("failed:" + code)
                fputs("Bundled WKWebView interpreter check failed: \(code)\n", stderr)
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
