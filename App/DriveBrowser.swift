import SwiftUI
import UIKit
import WebKit

@MainActor final class LoginSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var notice = "完成网页登录后，点右上角保存并验证。"
    @Published var busy = false
    @Published var desktopMode = false
    @Published var zoom: Double = 1
    @Published var progress: Double = 0
    let disk: Disk
    let webView: WKWebView
    private var observedHeaders: [String: String] = [:]
    private var progressObservation: NSKeyValueObservation?
    init(_ disk: Disk, url: URL? = nil) {
        self.disk = disk
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.userContentController.addUserScript(WKUserScript(source: Self.mobileLayout, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        if disk == .xunlei {
            let controller = configuration.userContentController
            controller.add(WeakLoginHandler(self), name: "cloudflowSession")
            controller.addUserScript(WKUserScript(source: Self.sessionObserver, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView.scrollView.bouncesZoom = true
        webView.scrollView.showsHorizontalScrollIndicator = true
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.allowsBackForwardNavigationGestures = true
        webView.backgroundColor = UIColor(red: 0.020, green: 0.027, blue: 0.055, alpha: 1)
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
            guard let owner = self else { return }
            let value = change.newValue ?? 0
            Task { @MainActor in owner.progress = value }
        }
        webView.load(URLRequest(url: url ?? disk.homeURL))
    }
    private static let mobileLayout = #"""
    (() => {
      const host = location.hostname;
      if (!['xunlei.com','baidu.com','quark.cn'].some(domain => host === domain || host.endsWith('.' + domain))) return;
      let meta = document.querySelector('meta[name="viewport"]');
      if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; document.head.appendChild(meta); }
      meta.content = 'width=device-width,initial-scale=1,minimum-scale=0.25,maximum-scale=5,user-scalable=yes,viewport-fit=cover';
      const style = document.createElement('style');
      style.id = 'cloudflow-mobile-login';
      style.textContent = 'html,body{min-width:0!important;-webkit-text-size-adjust:100%} @media(max-width:600px){[role="dialog"],.login-dialog,.login-modal,.login-panel,.login-container,.el-dialog,.ant-modal,.universal-login-container{box-sizing:border-box!important;max-width:calc(100vw - 16px)!important} [role="dialog"],.login-dialog,.login-modal,.el-dialog,.ant-modal{max-height:calc(100dvh - 16px)!important;overflow:auto!important} iframe[src*="xunlei"],iframe[src*="passport.baidu"],iframe[src*="quark"]{max-width:calc(100vw - 16px)!important} input{font-size:max(16px,1em)}}';
      document.head.appendChild(style);
    })()
    """#
    func setDesktop(_ value: Bool) {
        desktopMode = value; zoom = 1; webView.pageZoom = 1
        webView.customUserAgent = value ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" : nil
        webView.configuration.defaultWebpagePreferences.preferredContentMode = value ? .desktop : .mobile
        webView.reload()
    }
    func changeZoom(_ delta: Double) { zoom = min(2, max(0.3, zoom + delta)); webView.pageZoom = zoom }
    func fitScreen() {
        Task {
            let script = "Math.max(document.documentElement.scrollWidth,document.body ? document.body.scrollWidth : 0,window.innerWidth)"
            if let width = try? await webView.evaluateJavaScript(script) as? Double, width > 0 {
                zoom = min(1, max(0.3, Double(webView.bounds.width) / width)); webView.pageZoom = zoom
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if desktopMode { fitScreen() } }
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
        if !cookies.isEmpty {
            account.cookie = cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ")
            account.scopedCookies = cookies.map(StoredDriveCookie.init)
        }
        if disk == .xunlei { account.usesWebsiteSession = true }
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
            if disk == .xunlei { XunleiWebClient.shared.reset() }
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
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        FlowGlyph(symbol: FlowStyle.diskIcon(session.disk), color: FlowStyle.diskColor(session.disk), size: 30)
                        Text(session.notice).font(.caption).foregroundStyle(FlowStyle.text.opacity(0.86))
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        if session.busy { ProgressView().tint(FlowStyle.accent) }
                        Button { Haptics.tap(); session.webView.reload() } label: { Image(systemName: "arrow.clockwise").font(.subheadline.weight(.semibold)).frame(width: 44, height: 44) }
                            .accessibilityLabel("刷新登录页")
                    }
                    HStack(spacing: 8) {
                        Button { Haptics.select(); session.setDesktop(!session.desktopMode) } label: {
                            Label(session.desktopMode ? "切换手机版" : "切换桌面版", systemImage: session.desktopMode ? "iphone" : "desktopcomputer")
                        }
                        .buttonStyle(ChipStyle(tint: FlowStyle.accent))
                        Spacer(minLength: 4)
                        Button { session.changeZoom(-0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                            .buttonStyle(ChipStyle()).accessibilityLabel("缩小登录页面")
                        Button("适合屏幕") { session.fitScreen() }.buttonStyle(ChipStyle())
                        Button { session.changeZoom(0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                            .buttonStyle(ChipStyle()).accessibilityLabel("放大登录页面")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(FlowStyle.surface)
                LoadBar(progress: session.progress)
                SessionWebView(session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(FlowStyle.background.ignoresSafeArea())
            .navigationTitle(session.disk.title + "网盘").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlowStyle.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(FlowStyle.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并验证") {
                        Task {
                            if await session.save() { Haptics.success(); onSaved(); dismiss() } else { Haptics.warning() }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(session.busy)
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
                    HStack(spacing: 14) {
                        FlowGlyph(symbol: FlowStyle.diskIcon(disk), color: FlowStyle.diskColor(disk), size: 46)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(disk.title + "网盘").font(.headline)
                            HStack(spacing: 6) {
                                PulseDot(color: account.verifiedAt == nil ? FlowStyle.warning : FlowStyle.success, active: account.verifiedAt != nil, size: 6)
                                Text(account.verifiedAt == nil ? "待验证" : "已验证登录").font(.caption).foregroundStyle(account.verifiedAt == nil ? FlowStyle.warning : FlowStyle.success)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    Button { Haptics.tap(); showsLogin = true } label: { Label("打开" + disk.title + "网页登录", systemImage: "safari") }
                    Text("会话保存在这部 iPhone，转存直接连接网盘。").font(.caption).foregroundStyle(FlowStyle.muted)
                }
                .listRowBackground(FlowStyle.surface.opacity(0.92))
                Section {
                    TextField(disk == .baidu ? "文件夹路径，默认 /CloudFlow" : "文件夹 ID，留空为根目录", text: $account.directory).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("保存位置").foregroundStyle(FlowStyle.muted) }
                .listRowBackground(FlowStyle.surface.opacity(0.92))
                Section {
                    SecureField("Cookie", text: $account.cookie)
                    if disk == .xunlei {
                        SecureField("Refresh Token", text: $account.refreshToken)
                        SecureField("Access Token", text: $account.accessToken)
                        SecureField("Captcha Token", text: $account.captchaToken)
                        TextField("Client ID", text: $account.clientID)
                        TextField("Device ID", text: $account.deviceID)
                    }
                } header: { Text("手动导入会话（可选）").foregroundStyle(FlowStyle.muted) }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .listRowBackground(FlowStyle.surface.opacity(0.92))
                Section {
                    Button {
                        busy = true
                        Task {
                            defer { busy = false }
                            do { account.verifiedAt = nil; if disk == .xunlei { account.usesWebsiteSession = account.accessToken.isEmpty && account.refreshToken.isEmpty }; try account.save(disk); let driver = DirectDrive(disk, account: account); try await driver.validate(); account = driver.account; onChanged(); notice = "连接验证通过。"; Haptics.success() }
                            catch { notice = error.localizedDescription; Haptics.warning() }
                        }
                    } label: {
                        HStack { if busy { ProgressView().tint(FlowStyle.accent) }; Text(busy ? "正在验证…" : "保存并验证").fontWeight(.semibold) }
                    }
                    .disabled(busy)
                    Button("退出此网盘", role: .destructive) {
                        Task { do { try await DriveWebData.signOut(disk); account = DriveAccount(); onChanged(); notice = "已退出。" } catch { notice = error.localizedDescription } }
                    }.disabled(busy)
                    if !notice.isEmpty { Text(notice).font(.footnote).foregroundStyle(FlowStyle.text.opacity(0.86)) }
                }
                .listRowBackground(FlowStyle.surface.opacity(0.92))
            }
            .flowFormChrome()
            .navigationTitle(disk.title + "账号").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fullScreenCover(isPresented: $showsLogin) { DriveLogin(disk: disk) { account = DriveAccount.read(disk); onChanged() } }
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
                Section {
                    TextEditor(text: $shareText).frame(minHeight: 120).textInputAutocapitalization(.never).autocorrectionDisabled().scrollContentBackground(.hidden).accessibilityLabel("新分享链接与提取码")
                    PasteButton(payloadType: String.self) { if let text = $0.first { shareText = text } }.tint(FlowStyle.accent2)
                    if showsError { Label("请输入一条同平台的新分享链接，不能与原链接相同。", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(FlowStyle.danger) }
                } header: { Text(job.disk.title + "网盘的新分享链接").foregroundStyle(FlowStyle.muted) }
                .listRowBackground(FlowStyle.surface.opacity(0.92))
            }
            .flowFormChrome()
            .navigationTitle("导入新链接").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let result = ShareText.importedShare(shareText, for: job) else { withAnimation { showsError = true }; Haptics.warning(); return }
                        onSave(result); dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(shareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
