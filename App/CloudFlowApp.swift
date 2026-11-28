import SwiftUI
import UIKit

@main struct CloudFlowApp: App {
    var body: some Scene { WindowGroup { Workspace().preferredColorScheme(.dark) } }
}

struct Workspace: View {
    enum Page: String, CaseIterable, Identifiable {
        case desk = "工作台", tasks = "任务", copy = "文案", settings = "设置"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .desk: return "square.grid.2x2.fill"
            case .tasks: return "arrow.triangle.2.circlepath"
            case .copy: return "sparkles"
            case .settings: return "slider.horizontal.3"
            }
        }
        var eyebrow: String {
            switch self {
            case .desk: return "YOUR CONTENT, CONNECTED."
            case .tasks: return "EVERY TRANSFER, IN VIEW."
            case .copy: return "MAKE IT YOUR OWN."
            case .settings: return "CONNECTED, ON YOUR TERMS."
            }
        }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FlowStyle.lowMotionKey) private var lowMotion = false
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
    @State private var taskSearch = ""
    @State private var taskDisk: Disk?
    @State private var copyStage = "原文"
    @State private var keyboardVisible = false

    var body: some View {
        NavigationStack { canvas }
            .toolbar(.hidden, for: .navigationBar)
    }

    private var canvas: some View {
        ZStack {
            FlowBackdrop()
            // Only the visible page is alive, so edits on one page never
            // re-render the other three.
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible {
                FlowTabBar(page: $page, attention: model.attentionCount, running: model.running)
                    .padding(.top, 8)
                    .background(FlowStyle.background.opacity(0.96))
            }
        }
        .foregroundStyle(FlowStyle.text)
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .desk:
            DeskPage(model: model, accountDisk: $accountDisk, keyboardVisible: keyboardVisible, onPublication: { copyStage = "发布稿"; page = .copy }, onTasks: { filter = "需处理"; taskSearch = ""; taskDisk = nil; page = .tasks }).transition(pageTransition)
        case .tasks:
            TasksPage(model: model, filter: $filter, search: $taskSearch, disk: $taskDisk, openedJob: $openedJob, importing: $importing, resetJob: $resetJob).transition(pageTransition)
        case .copy:
            CopyPage(model: model, stage: $copyStage, keyboardVisible: keyboardVisible, onSettings: { page = .settings }).transition(pageTransition)
        case .settings:
            SettingsPage(model: model, accountDisk: $accountDisk).transition(pageTransition)
        }
    }
    private var pageTransition: AnyTransition {
        if reduceMotion || lowMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.985)), removal: .opacity)
    }
}

// MARK: - Chrome

struct FlowTabBar: View {
    @Binding var page: Workspace.Page
    let attention: Int
    let running: Bool
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Workspace.Page.allCases) { item in
                let selected = item == page
                Button {
                    guard !selected else { return }
                    Haptics.select()
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.84)) { page = item }
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: item.icon).font(.system(size: 17, weight: .semibold)).frame(width: 28, height: 22)
                            if item == .tasks && (attention > 0 || running) {
                                PulseDot(color: running ? FlowStyle.accent : FlowStyle.warning, active: running, size: 7).offset(x: 3, y: -1)
                            }
                        }
                        Text(item.rawValue).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(selected ? FlowStyle.accent : FlowStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(FlowStyle.accent.opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(FlowStyle.accent.opacity(0.35), lineWidth: 1))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityIdentifier("tab-" + String(describing: item))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(FlowStyle.surface.opacity(0.96))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(FlowStyle.hairline, lineWidth: 1))
        .frame(maxWidth: 520)
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }
}

struct FlowHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowStyle.accentGradient)
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(FlowStyle.ink)
            }
            .frame(width: 28, height: 28)
            .shadow(color: FlowStyle.accent.opacity(0.4), radius: 8)
            .accessibilityHidden(true)
            Text("CloudFlow").font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
            HStack(spacing: 7) {
                PulseDot(color: FlowStyle.success, active: true, size: 6)
                Text("本机直连").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(FlowStyle.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(FlowStyle.border, lineWidth: 1))
        }
    }
}

struct PageScaffold<Content: View>: View {
    let page: Workspace.Page
    let content: Content
    init(_ page: Workspace.Page, @ViewBuilder content: () -> Content) { self.page = page; self.content = content() }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                FlowHeader()
                VStack(alignment: .leading, spacing: 6) {
                    Text(page.rawValue).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text(page.eyebrow).font(FlowStyle.mono).tracking(1.5).foregroundStyle(FlowStyle.accentGradient)
                }
                .riseIn(0)
                content
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - Shared blocks

struct HeroPanel: View {
    let pending: Int
    let completed: Int
    let connected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    TechLabel(index: "SYS", title: "CONTENT RELAY")
                    Text("好内容，\n即刻变成你的分享。").font(.system(size: 24, weight: .bold, design: .rounded)).lineSpacing(4)
                    Text("批量转存 · 链接焕新 · AI 文案").font(.caption).foregroundStyle(FlowStyle.muted)
                }
                Spacer(minLength: 8)
                FlowCore().padding(.top, 2)
            }
            HStack(spacing: 10) {
                MetricTile(title: "待处理", value: pending, tint: FlowStyle.accent2)
                MetricTile(title: "已完成", value: completed, tint: FlowStyle.success)
                MetricTile(title: "已连接", value: connected, suffix: "/3", tint: FlowStyle.accent)
            }
        }
        .padding(20)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.12, blue: 0.24), Color(red: 0.045, green: 0.055, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                RadialGradient(colors: [FlowStyle.accent.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
        }
        .orbitBorder(cornerRadius: 26)
    }
}

struct AccountBand: View {
    let accounts: [Disk: Bool]
    let onSelect: (Disk) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 3), spacing: 10) {
            ForEach(Disk.allCases) { disk in
                let connected = accounts[disk] == true
                Button { Haptics.tap(); onSelect(disk) } label: { DiskTile(disk: disk, connected: connected) }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(disk.title + (connected ? "已连接，管理账号" : "登录账号"))
            }
        }
    }
}

struct DiskTile: View {
    let disk: Disk
    let connected: Bool

    var body: some View {
        let tint = FlowStyle.diskColor(disk)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                FlowGlyph(symbol: FlowStyle.diskIcon(disk), color: tint, size: 34)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(FlowStyle.muted.opacity(0.6))
            }
            Text(disk.title + "网盘").font(.subheadline.bold()).foregroundStyle(FlowStyle.text).lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                PulseDot(color: connected ? FlowStyle.success : FlowStyle.muted.opacity(0.6), active: connected, size: 6)
                Text(connected ? "已连接" : "点击登录").font(.caption2).foregroundStyle(connected ? FlowStyle.success : FlowStyle.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(FlowStyle.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(connected ? AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.65), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(FlowStyle.hairline), lineWidth: 1)
        )
    }
}

struct TaskRow: View {
    let job: ShareJob
    let compact: Bool
    let running: Bool
    var onToggle: () -> Void = {}
    var onCopy: (String) -> Void = { _ in }
    var onStart: () -> Void = {}
    var onOpen: () -> Void = {}
    var onImport: () -> Void = {}
    var onReset: () -> Void = {}

    private var title: String {
        if let result = job.result, !result.title.isEmpty { return result.title }
        return job.disk.title + "分享"
    }

    var body: some View {
        let tint = FlowStyle.diskColor(job.disk)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if compact && job.status != .uncertain && job.status != .running {
                    Button(action: onToggle) {
                        ZStack {
                            Circle().strokeBorder(job.selected ? FlowStyle.accent : FlowStyle.muted.opacity(0.5), lineWidth: 1.5)
                            if job.selected {
                                Circle().fill(FlowStyle.accentGradient).padding(3).transition(.scale.combined(with: .opacity))
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(FlowStyle.ink)
                            }
                        }
                        .frame(width: 26, height: 26)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(running || job.status == .uncertain || job.status == .running)
                    .accessibilityLabel(job.selected ? "取消选择任务" : "选择任务")
                } else {
                    FlowGlyph(symbol: FlowStyle.diskIcon(job.disk), color: tint)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(job.disk.title).font(FlowStyle.mono).foregroundStyle(tint)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(tint.opacity(0.12)))
                        Text(title).font(.subheadline.bold()).lineLimit(2)
                    }
                    Text(job.originalURL).font(.system(size: 11, design: .monospaced)).foregroundStyle(FlowStyle.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                StatusPill(status: job.status)
            }
            if job.status == .running { ScanLine() }
            if let result = job.result, job.status == .done {
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.shareText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(FlowStyle.accent)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button { onCopy(result.shareText) } label: { Label("复制链接", systemImage: "doc.on.doc") }
                            .buttonStyle(ChipStyle(tint: FlowStyle.accent))
                        Spacer()
                        ShareLink(item: result.shareText) { Image(systemName: "square.and.arrow.up").font(.subheadline.weight(.semibold)).frame(width: 44, height: 44) }
                            .accessibilityLabel("分享新链接")
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FlowStyle.success.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(FlowStyle.success.opacity(0.2), lineWidth: 1))
            }
            if let error = job.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(job.status == .uncertain ? FlowStyle.warning : FlowStyle.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !compact && job.status != .done && job.status != .running {
                HStack(spacing: 10) {
                    Button(job.status == .uncertain ? "继续核对" : "转存此条", action: onStart)
                        .buttonStyle(FlowButtonStyle(primary: true)).disabled(running)
                    Button("打开原链接", action: onOpen).buttonStyle(FlowButtonStyle(primary: false))
                }
                HStack {
                    Button("导入已有分享", action: onImport).buttonStyle(ChipStyle())
                    Spacer()
                    if job.checkpoint != nil {
                        Button("重置任务", role: .destructive, action: onReset).buttonStyle(ChipStyle(tint: FlowStyle.danger)).disabled(running)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(FlowStyle.cardFill))
        .orbitBorder(cornerRadius: 22, active: job.status == .running)
    }
}

// MARK: - 工作台

struct DeskPage: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var accountDisk: Disk?
    let keyboardVisible: Bool
    var onPublication: () -> Void
    var onTasks: () -> Void
    @State private var showAccounts = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PageScaffold(.desk) {
            importCard.riseIn(1)
            FlowCard(padding: 14) {
                DisclosureGroup(isExpanded: $showAccounts) {
                    AccountBand(accounts: model.accounts) { accountDisk = $0 }.padding(.top, 10)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.badge.person.crop").foregroundStyle(FlowStyle.accent)
                        Text("网盘账号").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(model.connectedCount)/3 已连接").font(.caption).foregroundStyle(FlowStyle.muted)
                    }
                    .frame(minHeight: 32)
                }
            }.riseIn(2)
            detected
            NoticeBanner(text: model.notice)
            if model.importedJobs.contains(where: { $0.status == .failed || $0.status == .uncertain }) {
                Button(action: onTasks) { Label("查看失败原因与待核对任务", systemImage: "arrow.right.circle") }
                    .buttonStyle(FlowButtonStyle(primary: false))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible {
                BatchActionBar(model: model, onPublication: onPublication)
            }
        }
        .onAppear { showAccounts = model.connectedCount == 0 }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86), value: model.running)
    }

    private var importCard: some View {
        FlowCard {
            HStack(alignment: .top) {
                SectionTitle(index: "01", title: "粘贴素材，自动整理", subtitle: "转存 → 生成你的分享 → 自动换链")
                Spacer()
                if model.detectedCount > 0 {
                    Text("检测到 \(model.detectedCount) 条")
                        .font(FlowStyle.mono)
                        .foregroundStyle(FlowStyle.accent)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Capsule().fill(FlowStyle.accent.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(FlowStyle.accent.opacity(0.25), lineWidth: 1))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.detectedCount > 0)
            FlowEditor(title: "链接与文案", text: $model.source, height: 130, prompt: "粘贴夸克、迅雷、百度分享链接\n也支持带链接的整段文案…")
                .accessibilityIdentifier("sourceEditor")
                .disabled(model.running)
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { if let text = $0.first { model.source = text; model.identify() } }
                    .labelStyle(.titleAndIcon)
                    .tint(FlowStyle.accent2)
                    .buttonBorderShape(.roundedRectangle(radius: 13))
                if !model.source.isEmpty {
                    Button { Haptics.tap(); model.source = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(FlowButtonStyle(primary: false))
                        .accessibilityLabel("清空素材")
                }
                Spacer(minLength: 8)
                Button { Haptics.tap(); model.identify() } label: { Label("识别链接", systemImage: "viewfinder") }
                    .buttonStyle(FlowButtonStyle(primary: true))
                    .disabled(model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(model.running)
        }
    }

    @ViewBuilder private var detected: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionTitle(index: "02", title: "本次识别", subtitle: "成功记录也保留显示，避免重复转存")
            Spacer()
            Text("\(model.importedJobs.count)")
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(FlowStyle.accentGradient)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.importedJobs.count)
        }
        if model.importedJobs.isEmpty {
            EmptyState(title: "还没有识别链接", detail: "粘贴素材，开始你的第一条内容流。", symbol: "tray")
        } else {
            HStack(spacing: 8) {
                Button("全选") { Haptics.select(); withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { model.selectAll(true) } }.buttonStyle(ChipStyle())
                Button("取消全选") { Haptics.select(); withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { model.selectAll(false) } }.buttonStyle(ChipStyle())
                Spacer()
                Text("已选 \(model.selected.count)").font(.caption.monospacedDigit()).foregroundStyle(FlowStyle.muted)
            }
            .disabled(model.running)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { providerCounts }
                VStack(alignment: .leading, spacing: 6) { providerCounts }
            }
            LazyVStack(spacing: 12) {
                ForEach(model.importedJobs) { job in
                    TaskRow(
                        job: job,
                        compact: job.status != .done,
                        running: model.running,
                        onToggle: {
                            Haptics.select()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { model.update(job.id) { $0.selected.toggle() } }
                        },
                        onCopy: { text in UIPasteboard.general.string = text; model.notice = "分享链接已复制。"; Haptics.success() }
                    )
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    @ViewBuilder private var providerCounts: some View {
        ForEach(Disk.allCases) { disk in
            let count = model.importedJobs.filter { $0.disk == disk }.count
            Label("\(disk.title) \(count)", systemImage: FlowStyle.diskIcon(disk))
                .font(.caption.weight(.medium)).foregroundStyle(FlowStyle.diskColor(disk))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Capsule().fill(FlowStyle.diskColor(disk).opacity(0.08)))
        }
    }
}

struct BatchActionBar: View {
    @ObservedObject var model: WorkspaceModel
    let onPublication: () -> Void
    private var needsIdentification: Bool { model.detectedCount > model.importedJobs.count }

    var body: some View {
        VStack(spacing: 10) {
        if model.running {
                HStack(spacing: 12) {
                    ProgressView().tint(FlowStyle.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.stopRequested ? "当前任务结束后停止" : "正在转存 · \(model.jobs.first(where: { $0.status == .running })?.disk.title ?? "准备中")")
                            .font(.subheadline.weight(.semibold))
                        Text("已处理 \(model.batchDone)/\(model.batchTotal) · 请保持前台").font(.caption.monospacedDigit()).foregroundStyle(FlowStyle.muted)
                    }
                    Spacer(minLength: 0)
                    Button("停止") { Haptics.tap(); model.stopRequested = true }
                        .buttonStyle(ChipStyle(tint: FlowStyle.warning)).disabled(model.stopRequested)
                }
                ProgressView(value: Double(model.batchDone), total: Double(max(1, model.batchTotal)))
                    .tint(FlowStyle.accent).accessibilityLabel("本批次进度")
        } else {
            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    if needsIdentification { model.identify() } else { model.start() }
                } label: {
                    HStack {
                        Image(systemName: needsIdentification ? "viewfinder" : "bolt.horizontal.fill")
                        Text(actionTitle)
                            .font(.subheadline.weight(.semibold))
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(FlowButtonStyle(.hero))
                .accessibilityIdentifier("batchTransferButton")
                .disabled(!needsIdentification && model.selected.isEmpty)
                if !model.output.isEmpty {
                    Button(action: onPublication) {
                        VStack(spacing: 3) {
                            Image(systemName: "doc.text").font(.body)
                            Text("发布稿").font(.caption2)
                        }.frame(minWidth: 48)
                    }
                    .buttonStyle(FlowButtonStyle(primary: false)).accessibilityLabel("查看自动换链后的发布稿")
                }
            }
        }
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(FlowStyle.background.opacity(0.97))
    }

    private var actionTitle: String {
        if needsIdentification { return "识别 \(model.detectedCount) 条链接" }
        if !model.selected.isEmpty { return "转存并生成链接 · \(model.selected.count)" }
        if model.importedJobs.isEmpty { return "请先粘贴分享链接" }
        if model.importedJobs.allSatisfy({ $0.status == .done }) { return "本次链接已全部完成" }
        return "请勾选任务，或到任务页核对"
    }
}

// MARK: - 任务

struct TasksPage: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var filter: String
    @Binding var search: String
    @Binding var disk: Disk?
    @Binding var openedJob: ShareJob?
    @Binding var importing: ShareJob?
    @Binding var resetJob: ShareJob?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let visible = WorkspaceInsights.matching(model.jobs, status: filter, disk: disk, search: search)
        let links = WorkspaceInsights.successfulLinks(visible)
        PageScaffold(.tasks) {
            HStack(spacing: 10) {
                MetricTile(title: "全部任务", value: model.jobs.count, tint: FlowStyle.accent2)
                MetricTile(title: "已成功", value: model.completed, tint: FlowStyle.success)
                MetricTile(title: "需处理", value: model.needsActionCount, tint: FlowStyle.warning)
            }
            .riseIn(1)
            FlowCard(padding: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(FlowStyle.muted)
                    TextField("搜索标题、链接或失败原因", text: $search)
                        .accessibilityIdentifier("taskSearch")
                        .font(.subheadline).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .submitLabel(.search).accessibilityLabel("搜索任务")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                            .buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }.frame(minHeight: 44)
                FlowSegmented(options: ["全部", "成功", "需处理"], selection: $filter)
                HStack {
                    Menu {
                        Button("全部网盘") { disk = nil }
                        ForEach(Disk.allCases) { item in Button(item.title + "网盘") { disk = item } }
                    } label: { Label(disk.map { $0.title + "网盘" } ?? "全部网盘", systemImage: "line.3.horizontal.decrease.circle") }
                        .buttonStyle(ChipStyle(tint: FlowStyle.accent))
                    Spacer()
                    Text("显示 \(visible.count) 条").font(.caption.monospacedDigit()).foregroundStyle(FlowStyle.muted)
                }
                if !links.isEmpty {
                    Button {
                        UIPasteboard.general.string = links
                        model.notice = "已复制当前筛选内的成功链接，未包含失败或待核对任务。"
                        Haptics.success()
                    } label: { Label("复制筛选内的成功链接", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                        .buttonStyle(FlowButtonStyle(primary: false))
                }
            }.riseIn(2)
            if visible.isEmpty {
                EmptyState(title: model.jobs.isEmpty ? "这里暂时没有任务" : "没有符合条件的任务", detail: model.jobs.isEmpty ? "在工作台粘贴素材，任务记录会自动保存在本机。" : "换个关键词，或清除筛选查看全部记录。", symbol: "checklist").riseIn(3)
                if !model.jobs.isEmpty {
                    Button("清除全部筛选") { search = ""; disk = nil; filter = "全部" }.buttonStyle(FlowButtonStyle(primary: false))
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(visible) { job in
                        TaskRow(
                            job: job,
                            compact: false,
                            running: model.running,
                            onCopy: { text in UIPasteboard.general.string = text; model.notice = "分享链接已复制。"; Haptics.success() },
                            onStart: { Haptics.tap(); model.start(only: job.id) },
                            onOpen: { openedJob = job },
                            onImport: { importing = job },
                            onReset: { resetJob = job }
                        )
                        .contextMenu {
                            Button { UIPasteboard.general.string = job.originalURL; model.notice = "原链接已复制。" } label: { Label("复制原链接", systemImage: "link") }
                            if let result = job.result, job.status == .done {
                                Button { UIPasteboard.general.string = result.shareText; model.notice = "分享链接已复制。" } label: { Label("复制新链接", systemImage: "doc.on.doc") }
                            }
                            if !model.running && job.status != .running && job.status != .uncertain {
                                Button(role: .destructive) { model.remove(job) } label: { Label("删除本机记录", systemImage: "trash") }
                            }
                        }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: filter)
            }
            NoticeBanner(text: model.notice)
            if !model.jobs.isEmpty {
                Text("长按任务卡片可复制链接或删除本机记录").font(.caption2).foregroundStyle(FlowStyle.muted).frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - 文案

struct CopyPage: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var stage: String
    let keyboardVisible: Bool
    let onSettings: () -> Void
    @State private var confirmPartialCopy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let stages = ["原文", "改写稿", "发布稿"]

    var body: some View {
        PageScaffold(.copy) {
            FlowCard {
                SectionTitle(index: "01", title: "内容焕新", subtitle: "保留原文事实，换一种表达")
                FlowSegmented(options: Self.stages, selection: $stage, marks: [!model.original.isEmpty, !model.draft.isEmpty, !model.output.isEmpty])
                switch stage {
                case "改写稿":
                    FlowEditor(title: "改写稿", text: $model.draft, height: 260, prompt: "生成后的文案显示在这里，可继续编辑。")
                case "发布稿":
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.output.isEmpty ? "粘贴原文后，自动整理的发布稿会显示在这里。" : model.output)
                            .font(.body).lineSpacing(6).textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                        Text("需要修改文字？在原文或改写稿中编辑，发布稿会自动同步。")
                            .font(.caption).foregroundStyle(FlowStyle.muted)
                    }
                    .padding(14).background(RoundedRectangle(cornerRadius: 16).fill(FlowStyle.field))
                default:
                    FlowEditor(title: "原文", text: $model.original, height: 230, prompt: "粘贴要改写的原文与分享链接…")
                    Button { Haptics.tap(); model.original = model.source } label: { Label("导入工作台素材", systemImage: "square.and.arrow.down") }
                        .buttonStyle(FlowButtonStyle(primary: false))
                        .disabled(model.source.isEmpty)
                }
            }
            .riseIn(1)
            if !model.output.isEmpty { publicationSummary }
            FlowCard {
                SectionTitle(index: "02", title: "改写偏好", subtitle: model.modelID.isEmpty ? "请先在设置中连接模型" : "当前模型 · " + model.modelID)
                FlowSegmented(options: ["自然分享", "简洁直给", "内容推荐"], selection: $model.tone)
                if !model.models.isEmpty {
                    HStack {
                        Text("选择模型").font(.caption.weight(.medium)).foregroundStyle(FlowStyle.muted)
                        Spacer()
                        Picker("选择模型", selection: $model.modelID) { ForEach(model.models, id: \.self) { Text($0) } }
                            .pickerStyle(.menu)
                            .tint(FlowStyle.accent)
                    }
                }
                Button { Haptics.tap(); model.rewrite() } label: {
                    HStack(spacing: 8) {
                        if model.rewriting { ProgressView().tint(FlowStyle.ink) } else { Image(systemName: "sparkles") }
                        Text(model.rewriting ? "正在生成文案…" : "AI 改写文案")
                        Spacer(minLength: 4)
                        Image(systemName: "wand.and.stars")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(FlowButtonStyle(.hero))
                .overlay { if model.rewriting { ShimmerOverlay(cornerRadius: 18) } }
                .disabled(model.rewriting || model.original.isEmpty)
                Label("转存成功后自动换成你的链接", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(FlowStyle.success)
                if model.modelID.isEmpty {
                    Button(action: onSettings) { Label("去设置连接 AI 模型", systemImage: "arrow.right.circle") }.buttonStyle(ChipStyle(tint: FlowStyle.accent))
                }
            }
            .riseIn(2)
            NoticeBanner(text: model.copyNotice)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible {
                Button {
                    if publicationCounts.pending > 0 { confirmPartialCopy = true } else { copyPublication() }
                } label: {
                    Label("复制发布稿", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(FlowButtonStyle(.hero)).disabled(model.output.isEmpty)
                .accessibilityIdentifier("copyPublicationButton")
                .frame(maxWidth: 640).padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: .infinity).background(FlowStyle.background.opacity(0.97))
            }
        }
        .confirmationDialog("还有 \(publicationCounts.pending) 条原链接未替换", isPresented: $confirmPartialCopy, titleVisibility: .visible) {
            Button("仍然复制（包含原链接）") { copyPublication() }
            Button("继续处理任务", role: .cancel) {}
        } message: {
            Text("这些链接尚未转存成功，复制后仍是原分享者的链接。已成功的链接已经自动替换。")
        }
        // Switch to the publication only after a rewrite actually succeeded.
        .onChange(of: model.rewriteCount) { _ in
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)) { stage = "发布稿" }
        }
    }

    private var publicationCounts: (ready: Int, pending: Int) {
        (model.publicationReady, model.publicationPending)
    }
    private var publicationSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: publicationCounts.pending == 0 ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                .font(.title2).foregroundStyle(publicationCounts.pending == 0 ? FlowStyle.success : FlowStyle.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(publicationCounts.pending == 0 ? "发布稿已就绪" : "还有 \(publicationCounts.pending) 条等待转存").font(.subheadline.weight(.semibold))
                Text("\(model.output.count) 字 · 已替换 \(publicationCounts.ready) 条链接 · 自动保存到本机")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
            }
            Spacer(minLength: 0)
        }.padding(14).background(RoundedRectangle(cornerRadius: 16).fill(FlowStyle.surfaceHigh.opacity(0.8)))
    }
    private func copyPublication() {
        UIPasteboard.general.string = model.output
        model.copyNotice = "发布稿已复制。"; Haptics.success()
    }
}

// MARK: - 设置

struct SettingsPage: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var accountDisk: Disk?
    @AppStorage(FlowStyle.lowMotionKey) private var lowMotion = false

    var body: some View {
        PageScaffold(.settings) {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(index: "01", title: "网盘账号", subtitle: "登录后直接转存，无需部署服务器")
                AccountBand(accounts: model.accounts) { accountDisk = $0 }
            }
            .riseIn(1)
            FlowCard {
                SectionTitle(index: "02", title: "AI 模型中转站", subtitle: "兼容 OpenAI 接口，模型自由选择")
                FlowField(title: "API 地址", prompt: "https://你的中转站/v1", text: $model.modelBase)
                FlowField(title: "API Key", prompt: "输入密钥", text: $model.modelKey, secure: true)
                Button { Haptics.tap(); model.loadModels() } label: {
                    HStack(spacing: 8) {
                        if model.loadingModels { ProgressView().tint(FlowStyle.ink) } else { Image(systemName: "arrow.clockwise") }
                        Text(model.loadingModels ? "正在读取模型…" : "连接并读取模型")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(FlowButtonStyle(primary: true))
                .disabled(model.loadingModels)
                if !model.models.isEmpty {
                    HStack {
                        Text("当前模型").font(.caption.weight(.medium)).foregroundStyle(FlowStyle.muted)
                        Spacer()
                        Picker("当前模型", selection: $model.modelID) { ForEach(model.models, id: \.self) { Text($0) } }
                            .pickerStyle(.menu)
                            .tint(FlowStyle.accent)
                    }
                }
                FlowField(title: "模型名称（也可手动填写）", prompt: "输入中转站中的模型 ID", text: $model.modelID)
                Button {
                    do { try model.saveModelSettings(); model.modelNotice = "模型配置已保存。"; Haptics.success() }
                    catch { model.modelNotice = error.localizedDescription; Haptics.warning() }
                } label: { Text("保存模型设置").frame(maxWidth: .infinity) }
                .buttonStyle(FlowButtonStyle(primary: false))
                NoticeBanner(text: model.modelNotice)
            }
            .riseIn(2)
            FlowCard {
                SectionTitle(index: "03", title: "显示与性能", subtitle: "动态效果均为轻量动画；旧机型或省电时可一键关闭")
                Toggle(isOn: $lowMotion) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("流畅优先").font(.subheadline.weight(.semibold))
                        Text("关闭背景流光、边框扫描等循环动画").font(.caption).foregroundStyle(FlowStyle.muted)
                    }
                }
                .tint(FlowStyle.accent)
            }
            .riseIn(3)
            FlowCard {
                HStack(spacing: 12) {
                    FlowGlyph(symbol: "lock.shield.fill", color: FlowStyle.success, size: 36)
                    Text("你的内容，留在你的手机").font(.subheadline.bold())
                }
                Text("账号凭证保存在系统钥匙串。任务与草稿保存在本机；调用 AI 时才将文案发送给你配置的中转站。")
                    .font(.caption).foregroundStyle(FlowStyle.muted).lineSpacing(5)
            }
            .riseIn(4)
            Text("CloudFlow 0.4.1 · PHONE FIRST")
                .font(.caption2.monospaced())
                .foregroundStyle(FlowStyle.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }
}
