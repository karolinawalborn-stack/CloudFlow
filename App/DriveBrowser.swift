import SwiftUI
import WebKit

@MainActor final class LoginSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var notice = "完成网页登录后，点右上角保存并验证。"
    @Published var busy = false
    let disk: Disk
    let webView: WKWebView
    private var observedHeaders: [String: String] = [:]
    init(_ disk: Disk, url: URL? = nil) {
        self.disk = disk
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        if disk == .xunlei {
            let controller = configuration.userContentController
            controller.add(WeakLoginHandler(self), name: "cloudflowSession")
            controller.addUserScript(WKUserScript(source: Self.sessionObserver, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url ?? disk.homeURL))
    }
    // The login page owns the session. Observe only its requests to the drive API,
    // retain the known session headers in memory, and persist only on explicit Save.
    private static let sessionObserver = #"""
    (() => {
      if (!(location.hostname === 'xunlei.com' || location.hostname.endsWith('.xunlei.com'))) return;
      const allowed = ['authorization','x-client-id','x-device-id','x-captcha-token'];
      const send = (url, headers) => {
        try {
          if (new URL(url, location.href).hostname !== 'api-pan.xunlei.com') return;
          const out = {};
          new Headers(headers || {}).forEach((value, key) => { if (allowed.includes(key)) out[key] = value; });
          if (Object.keys(out).length) window.webkit.messageHandlers.cloudflowSession.postMessage(out);
        } catch (_) {}
      };
      const originalFetch = window.fetch;
      window.fetch = function(input, init) {
        const headers = new Headers(input instanceof Request ? input.headers : {});
        new Headers(init && init.headers || {}).forEach((value,key) => headers.set(key,value));
        send(input instanceof Request ? input.url : input, headers);
        return originalFetch.apply(this, arguments);
      };
      const open = XMLHttpRequest.prototype.open, set = XMLHttpRequest.prototype.setRequestHeader, start = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method,url) { this.__cfURL = url; this.__cfHeaders = {}; return open.apply(this,arguments); };
      XMLHttpRequest.prototype.setRequestHeader = function(name,value) { if (allowed.includes(name.toLowerCase())) this.__cfHeaders[name.toLowerCase()] = value; return set.apply(this,arguments); };
      XMLHttpRequest.prototype.send = function() { send(this.__cfURL,this.__cfHeaders); return start.apply(this,arguments); };
    })()
    """#
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let host = message.frameInfo.securityOrigin.host
        guard disk == .xunlei, message.frameInfo.isMainFrame,
              host == "xunlei.com" || host.hasSuffix(".xunlei.com"),
              let fields = message.body as? [String: String] else { return }
        for key in ["authorization", "x-client-id", "x-device-id", "x-captcha-token"] {
            if let value = fields[key], !value.isEmpty { observedHeaders[key] = value }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { notice = "页面加载失败，请刷新重试。" }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, ["https", "about"].contains(url.scheme ?? "") else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, url.scheme == "https" { webView.load(action.request) }
        return nil
    }
    func save() async -> Bool {
        busy = true; defer { busy = false }
        var account = DriveAccount.read(disk)
        let cookies = await DriveWebData.cookies(for: disk)
        if !cookies.isEmpty { account.cookie = cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ") }
        if disk == .xunlei, let host = webView.url?.host, host == "xunlei.com" || host.hasSuffix(".xunlei.com") {
            // Only session fields are read, following the user's explicit Save action.
            let script = #"""
            (() => {
              const out = {}, fields = ['access_token','refresh_token','captcha_token','client_id','device_id'];
              function inspect(value, depth) {
                if (!value || typeof value !== 'object' || depth > 4) return;
                for (const [key, item] of Object.entries(value)) {
                  if (fields.includes(key) && typeof item === 'string' && item) out[key] = item;
                  if (item && typeof item === 'object') inspect(item, depth + 1);
                }
              }
              for (const storage of [localStorage, sessionStorage]) {
                for (let i = 0; i < storage.length; i++) {
                  const key = storage.key(i);
                  if (!/token|auth|user|client|device|captcha|credential|session/i.test(key)) continue;
                  const value = storage.getItem(key);
                  if (fields.includes(key) && value) out[key] = value.replace(/^"|"$/g, '');
                  try { inspect(JSON.parse(value), 0); } catch (_) {}
                }
              }
              return out;
            })()
            """#
            if let data = try? await webView.evaluateJavaScript(script) as? [String: String] {
                account.accessToken = data["access_token"] ?? account.accessToken
                account.refreshToken = data["refresh_token"] ?? account.refreshToken
                account.captchaToken = data["captcha_token"] ?? account.captchaToken
                account.clientID = data["client_id"] ?? account.clientID
                account.deviceID = data["device_id"] ?? account.deviceID
            }
        }
        if disk == .xunlei {
            if let bearer = observedHeaders["authorization"], bearer.lowercased().hasPrefix("bearer ") { account.accessToken = String(bearer.dropFirst(7)) }
            account.captchaToken = observedHeaders["x-captcha-token"] ?? account.captchaToken
            account.deviceID = observedHeaders["x-device-id"] ?? account.deviceID
            account.clientID = observedHeaders["x-client-id"] ?? account.clientID
        }
        do {
            guard account.configured else { throw ServiceError("尚未读取到登录会话，请完成网页登录后重试。") }
            account.verifiedAt = nil; try account.save(disk)
            try await DirectDrive(disk, account: account).validate()
            notice = "登录已验证，已保存在本机。"; return true
        } catch { notice = error.localizedDescription; return false }
    }
}

private final class WeakLoginHandler: NSObject, WKScriptMessageHandler {
    weak var owner: LoginSession?
    init(_ owner: LoginSession) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { owner?.userContentController(controller, didReceive: message) }
}

struct SessionWebView: UIViewRepresentable {
    let session: LoginSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct DriveLogin: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: LoginSession
    let onSaved: () -> Void
    init(disk: Disk, url: URL? = nil, onSaved: @escaping () -> Void) {
        _session = StateObject(wrappedValue: LoginSession(disk, url: url)); self.onSaved = onSaved
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if session.busy { ProgressView() }
                    Text(session.notice).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    Button { session.webView.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("刷新登录页")
                }.padding(.horizontal, 16).background(FlowStyle.surface)
                SessionWebView(session: session)
            }
            .navigationTitle(session.disk.title + "网盘").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并验证") { Task { if await session.save() { onSaved(); dismiss() } } }.disabled(session.busy)
                }
            }
        }
    }
}

struct AccountSettings: View {
    @Environment(\.dismiss) private var dismiss
    let disk: Disk
    let onChanged: () -> Void
    @State private var account: DriveAccount
    @State private var showsLogin = false
    @State private var busy = false
    @State private var notice = ""
    init(disk: Disk, onChanged: @escaping () -> Void) {
        self.disk = disk; self.onChanged = onChanged; _account = State(initialValue: DriveAccount.read(disk))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("打开" + disk.title + "网页登录") { showsLogin = true }
                    LabeledContent("状态", value: account.verifiedAt == nil ? "待验证" : "已验证登录")
                    Text("会话保存在这部 iPhone，转存直接连接网盘。").font(.caption).foregroundStyle(.secondary)
                }
                Section("保存位置") {
                    TextField(disk == .baidu ? "文件夹路径，默认 /CloudFlow" : "文件夹 ID，留空为根目录", text: $account.directory).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("手动导入会话（可选）") {
                    SecureField("Cookie", text: $account.cookie)
                    if disk == .xunlei {
                        SecureField("Refresh Token", text: $account.refreshToken)
                        SecureField("Access Token", text: $account.accessToken)
                        SecureField("Captcha Token", text: $account.captchaToken)
                        TextField("Client ID", text: $account.clientID)
                        TextField("Device ID", text: $account.deviceID)
                    }
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                Section {
                    Button(busy ? "正在验证…" : "保存并验证") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do { account.verifiedAt = nil; try account.save(disk); let driver = DirectDrive(disk, account: account); try await driver.validate(); account = driver.account; onChanged(); notice = "连接验证通过。" }
                            catch { notice = error.localizedDescription }
                        }
                    }.disabled(busy)
                    Button("退出此网盘", role: .destructive) {
                        Task { do { try await DriveWebData.signOut(disk); account = DriveAccount(); onChanged(); notice = "已退出。" } catch { notice = error.localizedDescription } }
                    }.disabled(busy)
                    if !notice.isEmpty { Text(notice).font(.footnote) }
                }
            }
            .navigationTitle(disk.title + "账号").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showsLogin) { DriveLogin(disk: disk) { account = DriveAccount.read(disk); onChanged() } }
        }
    }
}

struct ImportShare: View {
    @Environment(\.dismiss) private var dismiss
    @State private var shareText = ""
    @State private var showsError = false
    let job: ShareJob
    let onSave: (TransferResult) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section(job.disk.title + "网盘的新分享链接") {
                    TextEditor(text: $shareText).frame(minHeight: 120).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("新分享链接与提取码")
                    PasteButton(payloadType: String.self) { if let text = $0.first { shareText = text } }
                    if showsError { Text("请输入一条同平台的新分享链接，不能与原链接相同。").foregroundStyle(.red) }
                }
            }.navigationTitle("导入新链接").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            guard let result = ShareText.importedShare(shareText, for: job) else { showsError = true; return }
                            onSave(result); dismiss()
                        }.disabled(shareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
