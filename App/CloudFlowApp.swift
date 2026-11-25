import SwiftUI
import UIKit

@main struct CloudFlowApp: App {
    var body: some Scene { WindowGroup { Workspace().preferredColorScheme(.dark) } }
}

struct Workspace: View {
    enum Page: String, CaseIterable { case desk = "工作台", tasks = "任务", copy = "文案", settings = "设置" }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var model = WorkspaceModel()
    @State private var page = Self.initialPage()
    private static func initialPage() -> Page {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--preview-page"), i + 1 < args.count {
            switch args[i + 1] { case "tasks": return .tasks; case "copy": return .copy; case "settings": return .settings; default: break }
        }
        #endif
        return .desk
    }
    @State private var accountDisk: Disk?
    @State private var openedJob: ShareJob?
    @State private var importing: ShareJob?
    @State private var resetJob: ShareJob?
    @State private var filter = "全部"
    @State private var copyStage = "原文"

    var body: some View {
        TabView(selection: $page) {
            screen(.desk, eyebrow: "YOUR CONTENT, CONNECTED.") { desk }.tabItem { Label("工作台", systemImage: "square.grid.2x2.fill") }.tag(Page.desk)
            screen(.tasks, eyebrow: "EVERY TRANSFER, IN VIEW.") { tasks }.tabItem { Label("任务", systemImage: "arrow.triangle.2.circlepath") }.tag(Page.tasks)
            screen(.copy, eyebrow: "MAKE IT YOUR OWN.") { copyStudio }.tabItem { Label("文案", systemImage: "sparkles") }.tag(Page.copy)
            screen(.settings, eyebrow: "CONNECTED, ON YOUR TERMS.") { settings }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(Page.settings)
        }
        .tint(FlowStyle.accent)
        .sheet(item: $accountDisk) { disk in AccountSettings(disk: disk) { model.refreshAccounts() } }
        .fullScreenCover(item: $openedJob) { job in DriveLogin(disk: job.disk, url: URL(string: job.originalURL)) { model.refreshAccounts() } }
        .sheet(item: $importing) { job in ImportShare(job: job) { model.importResult($0, for: job) } }
        .alert("已在网盘核对？", isPresented: Binding(get: { resetJob != nil }, set: { if !$0 { resetJob = nil } })) {
            Button("取消", role: .cancel) { resetJob = nil }
            Button("确认重置并重新转存", role: .destructive) { if let job = resetJob { model.reset(job) }; resetJob = nil }
        } message: { Text("重置将清除断点，下次重新发起转存。若网盘内已有文件，请先导入已有分享链接，避免重复。") }
        .onChange(of: scenePhase) { phase in if phase != .active { model.persistDraft() } }
        .onChange(of: page) { _ in model.persistDraft() }
    }
    private func screen<V: View>(_ page: Page, eyebrow: String, @ViewBuilder content: () -> V) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.fill").foregroundStyle(FlowStyle.accent)
                        Text("CloudFlow").font(.headline)
                    }
                    Spacer()
                    Label("本机直连", systemImage: "iphone").font(.caption.weight(.medium)).foregroundStyle(FlowStyle.muted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(eyebrow).font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(FlowStyle.accent)
                    Text(page.rawValue).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                }
                content()
            }.frame(maxWidth: 680, alignment: .leading).padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 28).frame(maxWidth: .infinity)
        }
        .background(FlowBackdrop().ignoresSafeArea())
        .foregroundStyle(FlowStyle.text)
        .scrollDismissesKeyboard(.interactively)
        .toolbarBackground(FlowStyle.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
    private var desk: some View {
        VStack(alignment: .leading, spacing: 24) {
            hero
            accountBand
            FlowCard {
                HStack { section("导入素材", subtitle: "链接与文案，一次粘贴"); Spacer(); Image(systemName: "arrow.down.doc").foregroundStyle(FlowStyle.accent) }
                editor("链接与文案", text: $model.source, height: 145, prompt: "粘贴夸克、迅雷、百度分享链接\n也支持带链接的整段文案…")
                HStack {
                    PasteButton(payloadType: String.self) { if let text = $0.first { model.source = text } }.labelStyle(.titleAndIcon).tint(FlowStyle.accent)
                    Spacer(minLength: 8)
                    Button { model.identify() } label: { Label("识别链接", systemImage: "viewfinder") }.buttonStyle(FlowButtonStyle(primary: true)).disabled(model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack { section("本次识别", subtitle: "成功记录也保留显示，避免重复转存"); Spacer(); Text("\(model.importedJobs.count)").font(.title3.monospacedDigit().bold()).foregroundStyle(FlowStyle.accent) }
            if model.importedJobs.isEmpty { empty("还没有识别链接", detail: "粘贴素材，开始你的第一条内容流。", symbol: "tray") }
            else {
                HStack {
                    Button("全选") { model.selectAll(true) }
                    Text("/").foregroundStyle(FlowStyle.muted)
                    Button("取消全选") { model.selectAll(false) }
                    Spacer(); Text("已选 \(model.selected.count)").font(.caption).foregroundStyle(FlowStyle.muted)
                }.font(.subheadline).frame(minHeight: 44)
                ForEach(model.importedJobs) { job in taskCard(job, compact: job.status != .done).transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom))) }
            }
            notice(model.notice)
            if model.running {
                FlowCard {
                    HStack { ProgressView().tint(FlowStyle.accent); Text("正在转存并生成分享链接").font(.subheadline.weight(.medium)); Spacer() }
                    Button(model.stopRequested ? "将在当前任务完成后停止" : "完成当前任务后停止") { model.stopRequested = true }.buttonStyle(FlowButtonStyle(primary: false)).disabled(model.stopRequested)
                }
            } else {
                Button { model.start() } label: { HStack { Text("批量转存并生成链接"); Spacer(); Image(systemName: "arrow.up.right") }.frame(maxWidth: .infinity) }
                    .buttonStyle(FlowButtonStyle(primary: true)).disabled(model.selected.isEmpty)
            }
        }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("好内容，\n即刻变成你的分享。").font(.title2.weight(.bold)).lineSpacing(5)
                    Text("批量转存 · 链接焕新 · AI 文案").font(.caption).foregroundStyle(FlowStyle.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.triangle.branch").font(.system(size: 42, weight: .light)).foregroundStyle(FlowStyle.accent).rotationEffect(.degrees(-90)).padding(.top, 8).accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                metric("待处理", value: String(model.pending.count))
                Divider().overlay(FlowStyle.border)
                metric("已完成", value: String(model.completed))
                Divider().overlay(FlowStyle.border)
                metric("已连接", value: "\(model.accounts.values.filter { $0 }.count)/3")
            }.fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .background(LinearGradient(colors: [Color(red: 0.08, green: 0.20, blue: 0.22), FlowStyle.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(FlowStyle.accent.opacity(0.2)) }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(value).font(.title2.monospacedDigit().weight(.semibold)); Text(title).font(.caption2).foregroundStyle(FlowStyle.muted) }.frame(maxWidth: .infinity, alignment: .center)
    }
    private var accountBand: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 3), spacing: 10) {
            ForEach(Disk.allCases) { disk in
                Button { accountDisk = disk } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { FlowGlyph(symbol: FlowStyle.diskIcon(disk), color: FlowStyle.diskColor(disk), size: 34); Spacer(minLength: 0) }
                        Text(disk.title).font(.subheadline.bold()).foregroundStyle(FlowStyle.text)
                        HStack(spacing: 4) { Circle().fill(model.accounts[disk] == true ? FlowStyle.success : FlowStyle.muted).frame(width: 5, height: 5); Text(model.accounts[disk] == true ? "已连接" : "点击登录").font(.caption2).foregroundStyle(FlowStyle.muted) }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 18)).overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(FlowStyle.border) }
                }.buttonStyle(.plain).accessibilityLabel(disk.title + (model.accounts[disk] == true ? "已连接，管理账号" : "登录账号"))
            }
        }
    }
    private var tasks: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { section("任务记录", subtitle: "成功与中断，都有迹可循"); Spacer(); Text("\(model.completed)/\(model.jobs.count)").font(.headline.monospacedDigit()).foregroundStyle(FlowStyle.accent) }
            Picker("任务筛选", selection: $filter) { ForEach(["全部", "成功", "需处理"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            let visible = model.jobs.filter { filter == "全部" || (filter == "成功" && $0.status == .done) || (filter == "需处理" && [.ready, .failed, .uncertain].contains($0.status)) }
            if visible.isEmpty { empty("这里暂时没有任务", detail: "处理过的链接将保存在本机。", symbol: "checklist") }
            ForEach(visible) { taskCard($0, compact: false) }
            notice(model.notice)
        }
    }
    private func taskCard(_ job: ShareJob, compact: Bool) -> some View {
        FlowCard {
            HStack(spacing: 12) {
                if compact {
                    Button { model.update(job.id) { $0.selected.toggle() } } label: { Image(systemName: job.selected ? "checkmark.circle.fill" : "circle").font(.title3).frame(width: 44, height: 44).foregroundStyle(job.selected ? FlowStyle.accent : FlowStyle.muted) }.disabled(model.running).accessibilityLabel(job.selected ? "取消选择任务" : "选择任务")
                } else { FlowGlyph(symbol: FlowStyle.diskIcon(job.disk), color: FlowStyle.diskColor(job.disk)) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.result?.title.isEmpty == false ? job.result!.title : job.disk.title + "分享").font(.subheadline.bold()).lineLimit(2)
                    Text(job.originalURL).font(.caption2).foregroundStyle(FlowStyle.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if job.status == .running { ProgressView().tint(FlowStyle.accent) }
                else { Text(status(job.status)).font(.caption2.weight(.semibold)).foregroundStyle(job.status == .done ? FlowStyle.success : job.status == .uncertain ? FlowStyle.warning : FlowStyle.muted) }
            }
            if let result = job.result, job.status == .done {
                Text(result.shareText).font(.caption).foregroundStyle(FlowStyle.accent).textSelection(.enabled)
                HStack {
                    Button { UIPasteboard.general.string = result.shareText; model.notice = "分享链接已复制。" } label: { Label("复制链接", systemImage: "doc.on.doc") }
                    Spacer()
                    ShareLink(item: result.shareText) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("分享新链接")
                }.font(.subheadline.weight(.medium))
            }
            if let error = job.error { Text(error).font(.caption).foregroundStyle(FlowStyle.warning).fixedSize(horizontal: false, vertical: true) }
            if job.status != .done && !compact {
                if job.status != .running {
                    HStack {
                        Button(job.status == .uncertain ? "继续核对" : "转存此条") { model.start(only: job.id) }.buttonStyle(FlowButtonStyle(primary: true)).disabled(model.running)
                        Button("打开原链接") { openedJob = job }.buttonStyle(FlowButtonStyle(primary: false))
                    }
                    HStack {
                        Button("导入已有分享") { importing = job }
                        Spacer()
                        if job.checkpoint != nil { Button("重置任务", role: .destructive) { resetJob = job }.disabled(model.running) }
                    }.font(.caption).frame(minHeight: 44)
                }
            }
        }
    }
    private var copyStudio: some View {
        VStack(alignment: .leading, spacing: 20) {
            FlowCard {
                section("内容焕新", subtitle: "保留原文事实，换一种表达")
                Picker("文案阶段", selection: $copyStage) { ForEach(["原文", "改写稿", "发布稿"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                if copyStage == "原文" {
                    editor("原文", text: $model.original, height: 230, prompt: "粘贴要改写的原文与分享链接…")
                    Button("导入工作台素材") { model.original = model.source }.buttonStyle(FlowButtonStyle(primary: false))
                } else if copyStage == "改写稿" { editor("改写稿", text: $model.draft, height: 260, prompt: "生成后的文案显示在这里，可继续编辑。") }
                else { editor("发布稿", text: $model.output, height: 260, prompt: "成功转存后自动更新发布稿。") }
            }
            FlowCard {
                section("改写偏好", subtitle: model.modelID.isEmpty ? "请先在设置中连接模型" : "当前模型 · " + model.modelID)
                Picker("文案语气", selection: $model.tone) { ForEach(["自然分享", "简洁直给", "内容推荐"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                if !model.models.isEmpty { Picker("选择模型", selection: $model.modelID) { ForEach(model.models, id: \.self) { Text($0) } }.tint(FlowStyle.accent) }
                Button { model.rewrite(); copyStage = "发布稿" } label: { HStack { if model.rewriting { ProgressView() }; Label(model.rewriting ? "正在生成文案" : "AI 改写文案", systemImage: "sparkles"); Spacer() } }.buttonStyle(FlowButtonStyle(primary: true)).disabled(model.rewriting || model.original.isEmpty)
                Label("转存成功后自动换成你的链接", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(FlowStyle.success)
            }
            notice(model.copyNotice)
            Button { UIPasteboard.general.string = model.output; model.copyNotice = "发布稿已复制。" } label: { HStack { Label("复制发布稿", systemImage: "doc.on.doc"); Spacer(); Image(systemName: "arrow.up.right") } }.buttonStyle(FlowButtonStyle(primary: true)).disabled(model.output.isEmpty)
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("网盘账号", subtitle: "登录后直接转存，无需部署服务器")
            accountBand
            FlowCard {
                section("AI 模型中转站", subtitle: "兼容 OpenAI 接口，模型自由选择")
                labeledField("API 地址", prompt: "https://你的中转站/v1", text: $model.modelBase)
                VStack(alignment: .leading, spacing: 8) { Text("API Key").font(.caption).foregroundStyle(FlowStyle.muted); SecureField("输入密钥", text: $model.modelKey).textInputAutocapitalization(.never).autocorrectionDisabled().padding(14).background(FlowStyle.background, in: RoundedRectangle(cornerRadius: 12)) }
                Button { model.loadModels() } label: { Label(model.loadingModels ? "正在读取模型…" : "连接并读取模型", systemImage: "arrow.clockwise") }.buttonStyle(FlowButtonStyle(primary: true)).disabled(model.loadingModels)
                if !model.models.isEmpty { Picker("当前模型", selection: $model.modelID) { ForEach(model.models, id: \.self) { Text($0) } } }
                labeledField("模型名称（也可手动填写）", prompt: "输入中转站中的模型 ID", text: $model.modelID)
                Button("保存模型设置") { do { try model.saveModelSettings(); model.modelNotice = "模型配置已保存。" } catch { model.modelNotice = error.localizedDescription } }.buttonStyle(FlowButtonStyle(primary: false))
                notice(model.modelNotice)
            }
            FlowCard {
                Label("你的内容，留在你的手机", systemImage: "lock.shield").font(.subheadline.bold())
                Text("账号凭证保存在系统钥匙串。任务与草稿保存在本机；调用 AI 时才将文案发送给你配置的中转站。").font(.caption).foregroundStyle(FlowStyle.muted).lineSpacing(5)
            }
            Text("CloudFlow 0.3.1 · PHONE FIRST").font(.caption2.monospaced()).foregroundStyle(FlowStyle.muted).frame(maxWidth: .infinity).padding(.top, 8)
        }
    }
    private func labeledField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(FlowStyle.muted); TextField(prompt, text: text).textInputAutocapitalization(.never).autocorrectionDisabled().padding(14).background(FlowStyle.background, in: RoundedRectangle(cornerRadius: 12)) }
    }
    private func section(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline).accessibilityAddTraits(.isHeader); Text(subtitle).font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true) }
    }
    private func editor(_ title: String, text: Binding<String>, height: CGFloat, prompt: String) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty { Text(prompt).font(.subheadline).foregroundStyle(FlowStyle.muted.opacity(0.8)).padding(.horizontal, 14).padding(.top, 18).allowsHitTesting(false) }
            TextEditor(text: text).font(.subheadline).lineSpacing(5).scrollContentBackground(.hidden).padding(8).frame(minHeight: height).accessibilityLabel(title)
        }.background(FlowStyle.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 14)).overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(FlowStyle.border) }
    }
    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        FlowCard { VStack(spacing: 10) { Image(systemName: symbol).font(.title).foregroundStyle(FlowStyle.accent.opacity(0.6)); Text(title).font(.subheadline.bold()); Text(detail).font(.caption).foregroundStyle(FlowStyle.muted) }.frame(maxWidth: .infinity).padding(.vertical, 20) }
    }
    @ViewBuilder private func notice(_ text: String) -> some View { if !text.isEmpty { Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true) } }
    private func status(_ value: ShareJob.Status) -> String {
        switch value { case .ready: return "待转存"; case .running: return "执行中"; case .done: return "已完成"; case .failed: return "需重试"; case .uncertain: return "待核对" }
    }
}
