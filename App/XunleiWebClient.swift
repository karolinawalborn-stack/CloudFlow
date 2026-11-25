import Foundation
import WebKit

// Use the signed-in website's own request client, which refreshes per-request
// credentials. No cached captcha header is replayed across unrelated actions.
@MainActor final class XunleiWebClient: NSObject, WKNavigationDelegate {
    static let shared = XunleiWebClient()
    private var webView: WKWebView?
    private var loaded = false
    private var loadError: Error?
    func reset() { webView?.stopLoading(); webView = nil; loaded = false; loadError = nil }

    private func prepare() async throws -> WKWebView {
        if webView == nil {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .default()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            view.navigationDelegate = self
            webView = view; loaded = false; loadError = nil
            view.load(URLRequest(url: Disk.xunlei.homeURL))
        }
        for _ in 0..<60 {
            if let error = loadError { throw ServiceError("迅雷网页会话加载失败：" + error.localizedDescription) }
            if loaded { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard loaded, let view = webView else { reset(); throw ServiceError("迅雷网页会话连接超时，请打开迅雷登录页重试。") }
        // webpack 4 exposes the same published request module used by this page.
        let bootstrap = #"""
        (() => {
          if (window.__cloudflowRequire) return !!window.__cloudflowRequire(2).f;
          if (!window.webpackJsonp || !window.webpackJsonp.push) return false;
          const id = 980000000 + Math.floor(Math.random() * 1000000);
          window.webpackJsonp.push([[id], { [id]: function(module,exports,require) { window.__cloudflowRequire = require; } }, [[id]]]);
          return !!(window.__cloudflowRequire && window.__cloudflowRequire(2).f);
        })()
        """#
        for _ in 0..<30 {
            if (try? await view.evaluateJavaScript(bootstrap) as? Bool) == true { return view }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ServiceError("迅雷网页接口已更新，请打开登录页刷新会话后重试。")
    }
    func request(_ path: String, query: [String: String], body: [String: Any]?, mutation: Bool) async throws -> [String: Any] {
        guard path == "/share" || path == "/share/restore" || path == "/files" || path.hasPrefix("/tasks/") else { throw ServiceError("迅雷操作地址无效。") }
        let view = try await prepare()
        let script = #"""
        try {
          const request = window.__cloudflowRequire(2).f;
          const result = await request(path.replace(/^\//,''), payload, { method });
          return { ok: true, value: JSON.parse(JSON.stringify(result || {})) };
        } catch (error) {
          const source = error && (error.data || error.response && error.response.data) || error || {};
          return { ok: false, error: String(source.error_description || source.message || source.error || error.message || '网页请求失败'), status: Number(error.status || error.response && error.response.status || 0), explicit: !!(source.error || source.error_description) };
        }
        """#
        let raw: Any
        do { raw = try await view.callAsyncJavaScript(script, arguments: ["path": path, "payload": body ?? query as [String: Any], "method": body == nil ? "GET" : "POST"], in: nil, contentWorld: .page) }
        catch { throw ServiceError("迅雷网页请求中断，请核对任务。", uncertain: mutation) }
        guard let envelope = raw as? [String: Any] else { throw ServiceError("迅雷网页响应格式异常。", uncertain: mutation) }
        guard envelope["ok"] as? Bool == true else {
            let detail = DriveJSON.string(envelope, "error")
            let explicit = envelope["explicit"] as? Bool == true
            throw ServiceError("迅雷 · " + DriveHTTP.operation("/drive/v1" + path) + "：" + String(detail.prefix(220)), uncertain: mutation && !explicit)
        }
        let value = DriveJSON.dict(envelope, "value")
        if !DriveJSON.string(value, "error").isEmpty { throw ServiceError("迅雷：" + DriveJSON.string(value, "error_description")) }
        return (value["data"] as? [String: Any]) ?? value
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadError = error }
}

