import Foundation
import Observation
import WebKit
#if os(iOS)
import UIKit
#endif

/// An isolated, bundled page runs the same interpreter as the browser client.
/// It never loads remote scripts or serves an authentication HTTP endpoint.
@MainActor
@Observable
final class StoreRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = StoreRuntime()
    var stage = ""
    private var webView: WKWebView?
    private var ready = false
    private var starting = false
    private var startupTimer: Task<Void, Never>?
    private var startupStep = "page"
    private var lastFailure: StoreRuntimeError?
    private var assetReads = 0
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private let sockets = StoreRuntimeSockets()

    var progressText: String {
        stage == "preparing"
            ? String(localized: "Preparing Apple authentication. The first run may take several minutes.")
            : String(localized: "Communicating with Apple…")
    }

    private var directory: URL? {
        Bundle.main.url(forResource: "StoreRuntime", withExtension: "bundle")
    }

    func run(_ input: String) async throws -> String {
        try await load()
        guard let webView else { throw StoreRuntimeError.unavailable }
        do {
            let output = try await webView.callAsyncJavaScript(
                "return await window.asspp.run(input)", arguments: ["input": input],
                in: nil, contentWorld: .page
            )
            guard let output = output as? String, output.utf8.count <= 12 * 1024 * 1024 else {
                throw StoreRuntimeError.unavailable
            }
            return output
        } catch {
            // WKError descriptions can retain evaluated arguments. Do not log
            // or propagate their userInfo, scripts, request bodies or URLs.
            let failure = lastFailure ?? .startup("javascript-\((error as NSError).domain == WKError.errorDomain ? (error as NSError).code : 0)")
            fail(failure)
            await sockets.closeAll()
            throw failure
        }
    }

    private func load() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            guard !starting else { return }
            starting = true
            lastFailure = nil
            startupStep = "page"
            assetReads = 0
            guard let directory else { fail(.startup("bundle-missing")); return }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.userContentController.add(self, name: "storeRuntime")
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            view.navigationDelegate = self
            webView = view
            #if os(iOS)
            // An unattached iOS WKWebView may suspend the timers used by Go's
            // scheduler. Keep a transparent, noninteractive view in the active
            // window for the lifetime of the interpreter; no private WebKit APIs.
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let window = scenes.filter({ $0.activationState == .foregroundActive })
                .flatMap(\.windows).first(where: \.isKeyWindow)
                ?? UIApplication.shared.windows.first(where: \.isKeyWindow)
            else { fail(.startup("window-unavailable")); return }
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            window.addSubview(view)
            #endif
            view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
            startupTimer = Task { [weak self, weak view] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, let view, self.webView === view, self.starting else { return }
                self.fail(.startup("timeout-" + self.startupStep))
            }
        }
    }

    private func finish(_ error: Error? = nil) {
        startupTimer?.cancel()
        startupTimer = nil
        starting = false
        ready = error == nil
        let current = waiters
        waiters.removeAll()
        for continuation in current {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }

    private func fail(_ error: StoreRuntimeError) {
        lastFailure = error
        stage = ""
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "storeRuntime")
        webView?.removeFromSuperview()
        webView = nil
        finish(error)
        Task { await sockets.closeAll() }
    }

    private func trustedPage(_ url: URL) -> Bool {
        guard url.isFileURL, let directory else { return false }
        // iOS may report /var/... for a bundle addressed through /private/var/....
        return url.resolvingSymlinksInPath().standardizedFileURL.path
            == directory.appendingPathComponent("index.html").resolvingSymlinksInPath().standardizedFileURL.path
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let frameURL = message.frameInfo.request.url, trustedPage(frameURL),
              let body = message.body as? [String: Any], let id = body["id"] as? Int,
              let method = body["method"] as? String,
              let payload = body["payload"] as? [String: Any]
        else { return }
        let sender = message.webView
        Task { [weak self, weak sender] in
            guard let self, let sender, self.webView === sender else { return }
            do {
                let value = try await handle(method, payload: payload)
                guard self.webView === sender else { return }
                await reply(id, value: value)
            } catch {
                guard self.webView === sender else { return }
                await reply(id, error: true)
            }
        }
    }

    private func reply(_ id: Int, value: Any = NSNull(), error: Bool = false) async {
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.assppHostReply({id, value, error})", arguments: ["id": id, "value": value, "error": error],
            in: nil, contentWorld: .page
        )
    }

    private func handle(_ method: String, payload: [String: Any]) async throws -> Any {
        switch method {
        case "ready": finish(); return NSNull()
        case "initializationFailed": fail(.startup("initialization-" + startupStep)); return NSNull()
        case "progress": stage = payload["stage"] as? String ?? ""; return NSNull()
        case "runtimeBinary":
            startupStep = "wasm"
            guard let file = directory?.appendingPathComponent("runtime.wasm"),
                  let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 40 * 1024 * 1024
            else { throw StoreRuntimeError.unavailable }
            return try Data(contentsOf: file, options: .mappedIfSafe).base64EncodedString()
        case "readAsset":
            assetReads += 1
            startupStep = "asset-\(min(assetReads, 7))"
            guard let name = payload["name"] as? String else { throw StoreRuntimeError.unavailable }
            if let data = try StoreRuntimeAssets.read(name) { return data.base64EncodedString() }
            return NSNull()
        case "writeAsset":
            guard let name = payload["name"] as? String, let encoded = payload["data"] as? String,
                  encoded.utf8.count <= 44 * 1024 * 1024, let data = Data(base64Encoded: encoded)
            else { throw StoreRuntimeError.unavailable }
            try StoreRuntimeAssets.write(name, data: data)
            return NSNull()
        case "socketOpen":
            guard let host = payload["host"] as? String, payload["port"] as? Int == 443 else { throw StoreRuntimeError.unavailable }
            return try await sockets.open(host)
        case "socketRead":
            guard let id = payload["id"] as? Int, let count = payload["max"] as? Int else { throw StoreRuntimeError.unavailable }
            return try await sockets.read(id, count: count).base64EncodedString()
        case "socketWrite":
            guard let id = payload["id"] as? Int, let text = payload["data"] as? String,
                  text.utf8.count <= 1_400_000, let data = Data(base64Encoded: text), data.count <= 1024 * 1024
            else { throw StoreRuntimeError.unavailable }
            return try await sockets.write(id, data: data)
        case "socketClose":
            guard let id = payload["id"] as? Int else { throw StoreRuntimeError.unavailable }
            await sockets.close(id)
            return NSNull()
        default: throw StoreRuntimeError.unavailable
        }
    }

    func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, trustedPage(url)
        else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        guard view === webView else { return }
        fail(.startup("navigation"))
    }

    func webView(_ view: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        guard view === webView else { return }
        fail(.startup("navigation"))
    }

    func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
        guard view === webView else { return }
        fail(.startup("webcontent-terminated"))
    }
}

enum StoreRuntimeError: LocalizedError, StoreDiagnosticError {
    case unavailable
    case startup(String)
    case operation(String, Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Apple authentication could not start. Check your connection and try again.")
        case let .startup(code):
            String(localized: "Apple authentication could not start. Check your connection and try again.")
                + " (runtime: \(code))"
        case let .operation(code, status):
            String(localized: "Apple could not complete the request. Try signing in again.")
                + (status > 0 ? " (HTTP \(status))" : " (\(code))")
        }
    }

    var diagnostic: String {
        switch self {
        case .unavailable: "unavailable"
        case let .startup(code): code
        case let .operation(code, status): "\(code) http=\(status)"
        }
    }
}
