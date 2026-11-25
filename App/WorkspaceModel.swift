import Foundation
import SwiftUI
import UIKit

@MainActor final class WorkspaceModel: ObservableObject {
    @Published var source = ""
    @Published var original = "" { didSet { if original != oldValue { draft = ""; refreshPublication() } } }
    @Published var draft = "" { didSet { if draft != oldValue { refreshPublication() } } }
    @Published var output = ""
    @Published var jobs: [ShareJob] = []
    @Published var accounts: [Disk: Bool] = [:]
    @Published var modelBase = UserDefaults.standard.string(forKey: "modelBase") ?? ""
    @Published var modelID = UserDefaults.standard.string(forKey: "modelID") ?? ""
    @Published var modelKey = Vault.read("model")
    @Published var models: [String] = []
    @Published var tone = "自然分享"
    @Published var notice = ""
    @Published var modelNotice = ""
    @Published var copyNotice = ""
    @Published var running = false
    @Published var stopRequested = false
    @Published var loadingModels = false
    @Published var rewriting = false
    private var backgroundID = UIBackgroundTaskIdentifier.invalid
    private var queue: Task<Void, Never>?
    var pending: [ShareJob] { jobs.filter { $0.status != .done } }
    var importedJobs: [ShareJob] {
        let keys = Set(ShareText.parse(source).map { ShareText.identity($0.originalURL) })
        return jobs.filter { keys.contains(ShareText.identity($0.originalURL)) }
    }
    var completed: Int { jobs.filter { $0.status == .done }.count }
    var selected: [ShareJob] { importedJobs.filter { $0.selected && [.ready, .failed].contains($0.status) } }

    init() {
        if let data = try? Data(contentsOf: Self.jobsURL), var records = try? JSONDecoder().decode([ShareJob].self, from: data) {
            for i in records.indices where records[i].status == .running { records[i].status = .uncertain; records[i].error = "上次执行中断，可继续核对任务。" }
            jobs = records
        }
        if let data = try? Data(contentsOf: Self.draftURL), let state = try? JSONDecoder().decode(DraftState.self, from: data) {
            source = state.source; original = state.original; draft = state.draft; output = state.output
        }
        refreshAccounts(); refreshPublication()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-workspace") { verifyWorkspace() }
        #endif
    }
    #if DEBUG
    private func verifyWorkspace() {
        let text = "https://pan.baidu.com/s/1fixtureA?pwd=igfg\nhttps://pan.quark.cn/s/fixtureA\nhttps://pan.xunlei.com/s/fixtureA?pwd=jqnr#\nhttps://pan.baidu.com/s/1fixtureB?pwd=gj39\nhttps://pan.quark.cn/s/fixtureB\nhttps://pan.xunlei.com/s/fixtureB?pwd=7ehq#"
        jobs = ShareText.parse(text)
        source = text; original = text
        let completedQuark = jobs.first { $0.disk == .quark }!
        update(completedQuark.id) { $0.status = .done; $0.result = TransferResult(shareURL: "https://pan.quark.cn/s/my-new-share", code: "", title: "测试") }
        precondition(importedJobs.count == 6, "Completed quark remains visible")
        precondition(output.contains("my-new-share"), "Share completion automatically replaces URL")
        precondition(selected.count == 5, "Completed task excluded from next batch")
        draft = "新文案 " + text
        precondition(output.hasPrefix("新文案 ") && output.contains("my-new-share"), "Editing draft automatically updates publication")
        let other = ShareText.parse("https://pan.baidu.com/s/old-history")[0]
        jobs.append(other)
        precondition(importedJobs.count == 6 && !selected.contains { $0.id == other.id }, "Unrelated task excluded from this import")
        original = "下一段 https://pan.quark.cn/s/fixtureA"
        precondition(draft.isEmpty && output.contains("my-new-share"), "New original clears stale draft and replaces links")
        try? "PASS: workspace auto-publication and six-link visibility".write(to: URL.documentsDirectory.appendingPathComponent("workspace-self-check.txt"), atomically: true, encoding: .utf8)
        jobs = []; source = ""; original = ""; draft = ""; output = ""; try? persistJobs()
    }
    #endif
    func refreshAccounts() { accounts = Dictionary(uniqueKeysWithValues: Disk.allCases.map { ($0, DriveAccount.read($0).verifiedAt != nil) }) }
    private static var jobsURL: URL { URL.documentsDirectory.appendingPathComponent("cloudflow-jobs.json") }
    private static var draftURL: URL { URL.documentsDirectory.appendingPathComponent("cloudflow-draft.json") }
    private struct DraftState: Codable { let source: String; let original: String; let draft: String; let output: String }
    func persistDraft() {
        do { try JSONEncoder().encode(DraftState(source: source, original: original, draft: draft, output: output)).write(to: Self.draftURL, options: [.atomic, .completeFileProtection]) }
        catch { copyNotice = "草稿保存失败，请保留当前内容。" }
    }
    private func persistJobs() throws { try JSONEncoder().encode(jobs).write(to: Self.jobsURL, options: [.atomic, .completeFileProtection]) }
    func update(_ id: UUID, _ edit: (inout ShareJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        edit(&jobs[i]); if jobs[i].status == .done { refreshPublication() }; do { try persistJobs() } catch { notice = "任务记录保存失败。" }
    }
    func identify() {
        let parsed = ShareText.parse(source)
        var seen = Set(jobs.map { ShareText.identity($0.originalURL) })
        let fresh = parsed.filter { seen.insert(ShareText.identity($0.originalURL)).inserted }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.22)) { jobs.insert(contentsOf: fresh, at: 0) }
        for link in parsed {
            if let i = jobs.firstIndex(where: { ShareText.identity($0.originalURL) == ShareText.identity(link.originalURL) }), jobs[i].status != .done && jobs[i].status != .running {
                jobs[i].code = link.code; jobs[i].selected = true
            }
        }
        let summary = Disk.allCases.compactMap { disk -> String? in
            let count = parsed.filter { $0.disk == disk }.count
            return count == 0 ? nil : disk.title + " " + String(count)
        }.joined(separator: "、")
        let existingDone = importedJobs.filter { $0.status == .done }.count
        notice = parsed.isEmpty ? "没有识别到有效分享链接。" : "识别共 \(parsed.count) 条（\(summary)），新增 \(fresh.count) 条，已有 \(existingDone) 条成功记录。"
        if original != source { original = source }
        refreshPublication()
        do { try persistJobs() } catch { notice = "任务保存失败，请重试。" }
        persistDraft()
    }
    func selectAll(_ selected: Bool) {
        let ids = Set(importedJobs.map(\.id))
        for i in jobs.indices where ids.contains(jobs[i].id) && jobs[i].status != .done && jobs[i].status != .running { jobs[i].selected = selected }
    }
    func importResult(_ result: TransferResult, for job: ShareJob) { update(job.id) { $0.result = result; $0.status = .done; $0.error = nil }; notice = "新分享链接已导入。" }
    func reset(_ job: ShareJob) { update(job.id) { $0.checkpoint = nil; $0.error = nil; $0.status = .ready }; notice = "任务已重置，下次将重新发起转存。" }
    func start(only id: UUID? = nil) {
        guard !running else { return }
        let work = id == nil ? selected : jobs.filter { $0.id == id && $0.status != .done && $0.status != .running }
        guard !work.isEmpty else { notice = "请选择待转存任务；待核对任务请单独继续。"; return }
        running = true; stopRequested = false
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: "CloudFlowTransfer") { [weak self] in
            Task { @MainActor in self?.stopRequested = true; self?.queue?.cancel() }
        }
        queue = Task {
            defer {
                running = false
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid }
            }
            var attempted = 0; var succeeded = 0; var failed = 0; var uncertain = 0
            for item in work {
                if stopRequested || Task.isCancelled { break }
                attempted += 1
                update(item.id) { $0.status = .running; $0.error = nil }
                do {
                    let driver = DirectDrive(item.disk)
                    let result = try await driver.transfer(item) { point in
                        guard let i = self.jobs.firstIndex(where: { $0.id == item.id }) else { throw ServiceError("任务记录已不存在。", uncertain: true) }
                        self.jobs[i].checkpoint = point
                        // Abort before the next request if a checkpoint cannot be made durable.
                        try self.persistJobs()
                    }
                    update(item.id) { $0.status = .done; $0.result = result; $0.error = nil }
                    succeeded += 1
                } catch {
                    let needsCheck = (error as? ServiceError)?.uncertain == true
                    if needsCheck { uncertain += 1 } else { failed += 1 }
                    update(item.id) { $0.status = needsCheck ? .uncertain : .failed; $0.error = error.localizedDescription }
                }
            }
            notice = "本批次处理 \(attempted) 条：成功 \(succeeded)，失败 \(failed)，待核对 \(uncertain)。" + (stopRequested ? "队列已停止。" : "")
            refreshPublication()
            refreshAccounts()
        }
    }
    func refreshPublication() {
        let text = draft.isEmpty ? original : draft
        let result = ShareText.rewriteLinks(text, using: jobs)
        output = result.text
        let pending = ShareText.parse(text).filter { link in
            !jobs.contains { $0.status == .done && ShareText.identity($0.originalURL) == ShareText.identity(link.originalURL) }
        }.count
        copyNotice = "已自动替换 \(result.count) 处分享链接。" + (pending > 0 ? "还有 \(pending) 条未成功，暂保留原链接。" : "")
        persistDraft()
    }
    func loadModels() {
        guard !loadingModels else { return }
        let base = modelBase, key = modelKey; loadingModels = true
        Task {
            defer { loadingModels = false }
            do {
                let result = try await Service.models(base: base, key: key)
                guard base == modelBase && key == modelKey else { return }
                models = result; if !result.contains(modelID) { modelID = result.first ?? "" }
                try saveModelSettings(); modelNotice = "已读取 \(result.count) 个模型。"
            } catch { modelNotice = error.localizedDescription }
        }
    }
    func saveModelSettings() throws {
        guard Vault.write(modelKey, to: "model") else { throw ServiceError("模型密钥保存失败。") }
        UserDefaults.standard.set(modelBase, forKey: "modelBase"); UserDefaults.standard.set(modelID, forKey: "modelID")
    }
    func rewrite() {
        guard !rewriting else { return }
        guard !modelID.isEmpty else { copyNotice = "先在设置中读取或填写模型名称。"; return }
        let input = original, base = modelBase, key = modelKey, model = modelID, style = tone
        rewriting = true
        Task {
            defer { rewriting = false }
            do {
                try saveModelSettings()
                let result = try await Service.rewrite(input, tone: style, model: model, base: base, key: key)
                guard original == input else { copyNotice = "原文已更改，请重新生成改写。"; return }
                draft = result; refreshPublication()
            }
            catch { copyNotice = error.localizedDescription }
        }
    }
}

