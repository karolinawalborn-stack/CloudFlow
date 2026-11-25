import Foundation
import SwiftUI
import UIKit

@MainActor final class WorkspaceModel: ObservableObject {
    @Published var source = ""
    @Published var original = ""
    @Published var draft = ""
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
    var completed: Int { jobs.filter { $0.status == .done }.count }
    var selected: [ShareJob] { jobs.filter { $0.selected && $0.status != .done && $0.status != .running } }

    init() {
        if let data = try? Data(contentsOf: Self.jobsURL), var records = try? JSONDecoder().decode([ShareJob].self, from: data) {
            for i in records.indices where records[i].status == .running { records[i].status = .uncertain; records[i].error = "上次执行中断，可继续核对任务。" }
            jobs = records
        }
        if let data = try? Data(contentsOf: Self.draftURL), let state = try? JSONDecoder().decode(DraftState.self, from: data) {
            source = state.source; original = state.original; draft = state.draft; output = state.output
        }
        refreshAccounts()
    }
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
        edit(&jobs[i]); do { try persistJobs() } catch { notice = "任务记录保存失败。" }
    }
    func identify() {
        var seen = Set(jobs.map { ShareText.identity($0.originalURL) })
        let fresh = ShareText.parse(source).filter { seen.insert(ShareText.identity($0.originalURL)).inserted }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.22)) { jobs.insert(contentsOf: fresh, at: 0) }
        notice = fresh.isEmpty ? "没有新增的有效分享链接。" : "已识别 \(fresh.count) 条链接，选好后开始转存。"
        if original.isEmpty { original = source }
        do { try persistJobs() } catch { notice = "任务保存失败，请重试。" }
        persistDraft()
    }
    func selectAll(_ selected: Bool) { for i in jobs.indices where jobs[i].status != .done && jobs[i].status != .running { jobs[i].selected = selected } }
    func importResult(_ result: TransferResult, for job: ShareJob) { update(job.id) { $0.result = result; $0.status = .done; $0.error = nil }; notice = "新分享链接已导入。" }
    func reset(_ job: ShareJob) { update(job.id) { $0.checkpoint = nil; $0.error = nil; $0.status = .ready }; notice = "任务已重置，下次将重新发起转存。" }
    func start(only id: UUID? = nil) {
        guard !running else { return }
        let work = jobs.filter { job in id == nil ? (job.selected && [.ready, .failed].contains(job.status)) : job.id == id && job.status != .done }
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
            for item in work {
                if stopRequested || Task.isCancelled { break }
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
                } catch {
                    update(item.id) { $0.status = (error as? ServiceError)?.uncertain == true ? .uncertain : .failed; $0.error = error.localizedDescription }
                }
            }
            notice = stopRequested ? "队列已停止，已完成的结果已保留。" : "本批次已处理，成功 \(completed) 条。"
            refreshAccounts()
        }
    }
    func replaceLinks() {
        let result = ShareText.rewriteLinks(draft.isEmpty ? original : draft, using: jobs)
        output = result.text; copyNotice = "已替换 \(result.count) 处链接，其他原链接保持原样。"; persistDraft()
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
            do { try saveModelSettings(); draft = try await Service.rewrite(input, tone: style, model: model, base: base, key: key); copyNotice = "改写完成，可编辑后替换链接。"; persistDraft() }
            catch { copyNotice = error.localizedDescription }
        }
    }
}

