import Foundation
import Observation
import WebKit

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
            ready = false
            stage = ""
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "storeRuntime")
            self.webView = nil
            await sockets.closeAll()
            throw StoreRuntimeError.unavailable
        }
    }

    private func load() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            guard !starting else { return }
            starting = true
            guard let directory else { finish(StoreRuntimeError.unavailable); return }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.userContentController.add(self, name: "storeRuntime")
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            webView = view
            view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                if let self, !self.ready { self.finish(StoreRuntimeError.unavailable) }
            }
        }
    }

    private func finish(_ error: Error? = nil) {
        starting = false
        ready = error == nil
        let current = waiters
        waiters.removeAll()
        for continuation in current {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let frameURL = message.frameInfo.request.url, frameURL.isFileURL,
              let directory, frameURL.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/"),
              let body = message.body as? [String: Any], let id = body["id"] as? Int,
              let method = body["method"] as? String,
              let payload = body["payload"] as? [String: Any]
        else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await handle(method, payload: payload)
                await reply(id, value: value)
            } catch {
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
        case "initializationFailed": finish(StoreRuntimeError.unavailable); return NSNull()
        case "progress": stage = payload["stage"] as? String ?? ""; return NSNull()
        case "runtimeBinary":
            guard let file = directory?.appendingPathComponent("runtime.wasm"),
                  let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 40 * 1024 * 1024
            else { throw StoreRuntimeError.unavailable }
            return try Data(contentsOf: file, options: .mappedIfSafe).base64EncodedString()
        case "readAsset":
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
        guard let url = navigationAction.request.url, url.isFileURL, let directory,
              url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
        else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        finish(StoreRuntimeError.unavailable)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        ready = false
        stage = ""
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "storeRuntime")
        webView = nil
        finish(StoreRuntimeError.unavailable)
        Task { await sockets.closeAll() }
    }
}

enum StoreRuntimeError: LocalizedError {
    case unavailable
    case operation(String, Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Apple authentication could not start. Check your connection and try again.")
        case let .operation(code, status):
            String(localized: "Apple could not complete the request. Try signing in again.")
                + (status > 0 ? " (HTTP \(status))" : " (\(code))")
        }
    }
}
