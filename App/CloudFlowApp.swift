import SwiftUI
import UIKit

@main struct CloudFlowApp: App {
    var body: some Scene { WindowGroup { Workspace().preferredColorScheme(.dark) } }
}

@MainActor struct Workspace: View {
    enum Page: Hashable { case desk, tasks, copy, settings }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("transferBase") private var transferBase = ""
    @AppStorage("modelBase") private var modelBase = ""
    @AppStorage("modelID") private var modelID = ""
    @State private var transferKey = Vault.read("transfer")
    @State private var modelKey = Vault.read("model")
    @State private var page = Page.desk
    @State private var source = ""
    @State private var original = ""
    @State private var draft = ""
    @State private var output = ""
    @State private var jobs = Self.restore()
    @State private var providers: [Disk: Bool] = [:]
    @State private var models: [String] = []
    @State private var tone = "自然分享"
    @State private var filter = "全部"
    @State private var deskNotice = ""
    @State private var taskNotice = ""
    @State private var copyNotice = ""
    @State private var transferNotice = ""
    @State private var modelNotice = ""
    @State private var running = false
    @State private var completed = 0
    @State private var total = 0
    @State private var checking = false
    @State private var loadingModels = false
    @State private var rewriting = false
    @State private var confirm = false
    private let bg = Color(red: 0.063, green: 0.078, blue: 0.073)
    private let panel = Color(red: 0.091, green: 0.115, blue: 0.102)
    private let mint = Color(red: 0.65, green: 0.95, blue: 0.75)
    private let muted = Color(red: 0.66, green: 0.72, blue: 0.68)

    var body: some View {
        TabView(selection: $page) {
            screen("01 / TRANSFER DESK", "批量转存工作台") { desk }.tabItem { Label("工作台", systemImage: "tray") }.tag(Page.desk)
            screen("02 / ACTIVITY", "任务") { activity }.tabItem { Label("任务", systemImage: "list.bullet.rectangle") }.tag(Page.tasks)
            screen("03 / COPY STUDIO", "文案二创") { copyStudio }.tabItem { Label("文案", systemImage: "sparkles") }.tag(Page.copy)
            screen("04 / CONNECTIONS", "连接设置") { settings }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(Page.settings)
        }
        .tint(mint)
        .onChange(of: transferBase) { _ in providers = [:] }
        .onChange(of: transferKey) { _ in providers = [:] }
        .onChange(of: modelBase) { _ in models = []; modelID = "" }
        .onChange(of: modelKey) { _ in models = []; modelID = "" }
    }

    private func screen<V: View>(_ index: String, _ title: String, @ViewBuilder content: () -> V) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("CloudFlow", systemImage: "checkmark.icloud").font(.headline).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(index).font(.caption.monospaced()).foregroundStyle(mint)
                    Text(title).font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                }
                content()
            }.frame(maxWidth: 620, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 21).frame(maxWidth: .infinity)
        }.background(bg.ignoresSafeArea()).scrollDismissesKeyboard(.interactively)
    }

    private var desk: some View {
        VStack(alignment: .leading, spacing: 13) {
            accountBand
            Divider()
            HStack { heading("分享链接与文案"); Spacer(); Text("\(jobs.count) 条已识别").font(.caption.monospacedDigit()).foregroundStyle(muted) }
            editor("分享链接与文案", $source, height: 145)
            HStack {
                PasteButton(payloadType: String.self) { if let text = $0.first { source = text } }.tint(mint)
                Spacer()
                action("识别链接", "link", primary: true) { importLinks() }.disabled(running || source.isEmpty)
            }
            notice(deskNotice)
            Divider()
            heading("转存队列")
            if jobs.allSatisfy({ $0.status != .ready }) { Text("没有待转存任务").font(.footnote).foregroundStyle(muted) }
            ForEach($jobs) { $job in
                if job.status == .ready {
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(isOn: $job.selected) { jobLabel(job) }.disabled(running)
                        TextField("提取码（可选）", text: $job.code).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.footnote).padding(.vertical, 6).disabled(running)
                        Divider()
                    }
                }
            }
            if running { ProgressView(value: Double(completed), total: Double(max(1, total))) { Text("已处理 \(completed) / \(total)").font(.footnote.monospacedDigit()) } }
            action("开始转存并生成分享", "arrow.down.to.line", primary: true) { confirm = true }
                .disabled(running || !jobs.contains { $0.selected && $0.status == .ready })
            if !taskNotice.isEmpty { notice(taskNotice) }
        }
        .confirmationDialog("转存到各自平台账号并创建分享？", isPresented: $confirm, titleVisibility: .visible) {
            Button("开始转存") { batch() }
            Button("取消", role: .cancel) {}
        } message: { Text("将把选中的资源转存到服务中配置的目录，并创建分享链接。") }
    }

    private var accountBand: some View {
        HStack(spacing: 6) {
            ForEach(Disk.allCases) { disk in
                VStack(alignment: .leading, spacing: 4) {
                    Label(disk.title, systemImage: "externaldrive").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(providers[disk] == true ? "已配置" : (providers[disk] == false ? "未配置" : "未检查"))
                        .font(.caption2).foregroundStyle(providers[disk] == true ? mint : muted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(panel, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("任务筛选", selection: $filter) { ForEach(["全部", "成功", "需处理"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            let visible = jobs.filter { filter == "全部" || (filter == "成功" && $0.status == .done) || (filter == "需处理" && [.failed, .uncertain].contains($0.status)) }
            if visible.isEmpty { Text("暂无此类任务").font(.footnote).foregroundStyle(muted) }
            ForEach(visible) { job in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { jobLabel(job); Spacer(); Text(label(job.status)).font(.caption).foregroundStyle(job.status == .done ? mint : muted) }
                    if let result = job.result {
                        Text(result.shareText).font(.caption).foregroundStyle(mint).textSelection(.enabled)
                        action("复制分享", "doc.on.doc") { UIPasteboard.general.string = result.shareText; taskNotice = "已复制分享链接" }
                    }
                    if let error = job.error { notice(error) }
                    if job.status == .failed {
                        action("返回队列", "arrow.uturn.backward") { update(job.id) { $0.status = .ready; $0.error = nil }; page = .desk }.disabled(running)
                    }
                    if job.status == .uncertain {
                        action("查询这次请求结果", "arrow.clockwise") { recover(job) }.disabled(running)
                    }
                    Divider()
                }
            }
            notice(taskNotice)
        }
    }

    private var copyStudio: some View {
        VStack(alignment: .leading, spacing: 13) {
            heading("原文")
            editor("原文", $original, height: 120)
            action("导入工作台原文", "square.and.arrow.down") { original = source }
            Divider()
            heading("改写稿")
            Picker("语气", selection: $tone) { ForEach(["自然分享", "简洁直给", "内容推荐"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if !models.isEmpty { Picker("模型", selection: $modelID) { ForEach(models, id: \.self) { Text($0) } } }
            else { Text(modelID.isEmpty ? "未选择模型" : modelID).font(.footnote).foregroundStyle(muted) }
            action(rewriting ? "正在生成" : "调用模型改写", "sparkles", primary: true) { rewrite() }.disabled(rewriting || original.isEmpty)
            editor("改写稿", $draft, height: 125)
            action("替换链接并预览", "link") {
                let result = ShareText.rewriteLinks(draft.isEmpty ? original : draft, using: jobs)
                output = result.text; copyNotice = "替换了 \(result.count) 处链接，未成功的原链接保留。"
            }.disabled(original.isEmpty && draft.isEmpty)
            heading("发布稿")
            editor("发布稿", $output, height: 120)
            action("复制发布稿", "doc.on.doc") { UIPasteboard.general.string = output; copyNotice = "已复制发布稿" }.disabled(output.isEmpty)
            notice(copyNotice)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 13) {
            heading("网盘转存服务")
            field("网盘服务 HTTPS 地址", $transferBase)
            secret("网盘服务密钥", $transferKey)
            action(checking ? "检查中" : "保存并检查服务", "externaldrive") { check() }.disabled(checking || running)
            accountBand
            notice(transferNotice)
            Divider()
            heading("文案模型中转站")
            field("API 基址（通常以 /v1 结尾）", $modelBase)
            secret("模型 API Key", $modelKey)
            action(loadingModels ? "读取中" : "保存并读取模型", "arrow.clockwise") { loadModels() }.disabled(loadingModels)
            if !models.isEmpty { Picker("使用模型", selection: $modelID) { ForEach(models, id: \.self) { Text($0) } } }
            notice(modelNotice)
        }
    }

    private func heading(_ value: String) -> some View { Text(value).font(.headline).accessibilityAddTraits(.isHeader) }
    @ViewBuilder private func notice(_ value: String) -> some View { if !value.isEmpty { Text(value).font(.footnote).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) } }
    private func editor(_ title: String, _ value: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: value).font(.body).scrollContentBackground(.hidden).padding(6).frame(minHeight: height)
            .background(panel, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(title)
    }
    private func field(_ title: String, _ value: Binding<String>) -> some View {
        TextField(title, text: value).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, 10).frame(minHeight: 44).background(panel, in: RoundedRectangle(cornerRadius: 8))
    }
    private func secret(_ title: String, _ value: Binding<String>) -> some View {
        SecureField(title, text: value).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, 10).frame(minHeight: 44).background(panel, in: RoundedRectangle(cornerRadius: 8))
    }
    private func action(_ title: String, _ symbol: String, primary: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).padding(.horizontal, 7).frame(minHeight: 36) }
            .buttonStyle(.borderedProminent).tint(primary ? mint : panel).foregroundStyle(primary ? bg : mint)
            .controlSize(.regular)
    }
    private func jobLabel(_ job: ShareJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.result?.title.isEmpty == false ? (job.result?.title ?? job.disk.title) : job.disk.title + "网盘").font(.subheadline.weight(.medium))
            Text(job.originalURL).font(.caption).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
        }
    }
    private func label(_ status: ShareJob.Status) -> String {
        switch status { case .ready: return "待转存"; case .running: return "运行中"; case .done: return "已生成"; case .failed: return "未执行"; case .uncertain: return "待核对" }
    }
    private func importLinks() {
        var seen = Set(jobs.map(\.originalURL))
        let fresh = ShareText.parse(source).filter { seen.insert($0.originalURL).inserted }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { jobs.append(contentsOf: fresh) }
        deskNotice = fresh.isEmpty ? "没有新增的有效分享链接。" : "新增 \(fresh.count) 条。"
        persist()
    }
    private func batch() {
        let selected = jobs.filter { $0.selected && $0.status == .ready }
        guard !running, !selected.isEmpty, !transferBase.isEmpty && !transferKey.isEmpty else { taskNotice = "请先配置网盘转存服务。"; return }
        let base = transferBase, key = transferKey
        running = true; completed = 0; total = selected.count; taskNotice = ""
        Task {
            for job in selected {
                update(job.id) { $0.status = .running }
                do {
                    let result = try await Service.transfer(job, base: base, key: key)
                    update(job.id) { $0.status = .done; $0.result = result; $0.error = nil }
                } catch {
                    update(job.id) { $0.status = (error as? ServiceError)?.uncertain == true ? .uncertain : .failed; $0.error = error.localizedDescription }
                }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { completed += 1 }
            }
            running = false
            let ids = Set(selected.map(\.id))
            let successes = jobs.filter { ids.contains($0.id) && $0.status == .done }.count
            taskNotice = "生成 \(successes) 条分享；\(selected.count - successes) 条需处理。"
        }
    }
    private func recover(_ job: ShareJob) {
        guard !running, !transferBase.isEmpty, !transferKey.isEmpty else { taskNotice = "请先配置网盘转存服务。"; return }
        let base = transferBase, key = transferKey
        running = true
        Task {
            defer { running = false }
            do {
                let result = try await Service.lookup(job, base: base, key: key)
                update(job.id) { $0.status = .done; $0.result = result; $0.error = nil }
                taskNotice = "已取回分享结果。"
            } catch { taskNotice = error.localizedDescription }
        }
    }
    private func check() {
        let base = transferBase, key = transferKey; checking = true
        Task {
            defer { checking = false }
            do {
                let states = try await Service.status(base: base, key: key)
                guard base == transferBase && key == transferKey else { return }
                guard Vault.write(key, to: "transfer") else { transferNotice = "钥匙串写入失败，密钥仅在本次打开时可用。"; return }
                providers = states; transferNotice = "已读取服务配置；账号实际有效性以转存结果为准。"
            } catch { transferNotice = error.localizedDescription }
        }
    }
    private func loadModels() {
        let base = modelBase, key = modelKey; loadingModels = true
        Task {
            defer { loadingModels = false }
            do {
                let list = try await Service.models(base: base, key: key)
                guard base == modelBase && key == modelKey else { return }
                models = list; if !list.contains(modelID) { modelID = list.first ?? "" }
                modelNotice = Vault.write(key, to: "model") ? "读取到 \(list.count) 个模型。" : "钥匙串写入失败，密钥仅在本次打开时可用。"
            } catch { modelNotice = error.localizedDescription }
        }
    }
    private func rewrite() {
        guard !modelID.isEmpty else { copyNotice = "请先在设置中读取并选择模型。"; return }
        let input = original, base = modelBase, key = modelKey, model = modelID, style = tone
        rewriting = true
        Task {
            defer { rewriting = false }
            do { draft = try await Service.rewrite(input, tone: style, model: model, base: base, key: key); copyNotice = "改写稿已生成。" }
            catch { copyNotice = error.localizedDescription }
        }
    }
    private func update(_ id: UUID, edit: (inout ShareJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        edit(&jobs[i]); persist()
    }
    private static var stateURL: URL { URL.documentsDirectory.appendingPathComponent("cloudflow-jobs.json") }
    private func persist() {
        do { try JSONEncoder().encode(jobs).write(to: Self.stateURL, options: [.atomic, .completeFileProtection]) }
        catch { taskNotice = "任务记录未能写入手机。" }
    }
    private static func restore() -> [ShareJob] {
        guard let data = try? Data(contentsOf: stateURL), var records = try? JSONDecoder().decode([ShareJob].self, from: data) else { return [] }
        for i in records.indices where records[i].status == .running { records[i].status = .uncertain; records[i].error = "上次请求中断，请查询结果。" }
        return records
    }
}
