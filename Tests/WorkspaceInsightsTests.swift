import Foundation

@main struct WorkspaceInsightsTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); count += 1
    }
    static func main() {
        let source = "https://pan.quark.cn/s/fixtureQuark\nhttps://pan.xunlei.com/s/fixtureXunlei\nhttps://pan.baidu.com/s/1fixtureBaidu"
        var jobs = ShareText.parse(source)
        jobs[0].status = .done
        jobs[0].result = TransferResult(shareURL: "https://pan.quark.cn/s/ownedQuark", code: "abcd", title: "旅行素材 Travel")
        jobs[1].status = .uncertain; jobs[1].error = "等待核对远程结果"
        jobs[2].status = .failed; jobs[2].error = "登录状态已过期"
        func filtered(_ status: String = "全部", _ disk: Disk? = nil, _ search: String = "") -> [ShareJob] {
            WorkspaceInsights.matching(jobs, status: status, disk: disk, search: search)
        }
        check(filtered().count == 3, "All records preserved")
        check(filtered("成功").map(\.id) == [jobs[0].id], "Only successful records")
        check(filtered("需处理").map(\.id) == [jobs[1].id, jobs[2].id], "Uncertain stays actionable without auto retry")
        check(filtered("全部", .baidu).map(\.id) == [jobs[2].id], "Provider filter")
        check(filtered("成功", .baidu).isEmpty, "Combine status and provider")
        check(filtered("全部", nil, "旅行").count == 1, "Search result title")
        check(filtered("全部", nil, "TRAVEL").count == 1, "Case-insensitive search")
        check(filtered("全部", nil, "ownedQuark").count == 1, "Search owned URL")
        check(filtered("全部", nil, "fixtureXunlei").count == 1, "Search original URL")
        check(filtered("全部", nil, "登录").count == 1, "Search failure reason")
        check(filtered("全部", nil, "迅雷").count == 1, "Search provider name")
        check(filtered("全部", nil, " 旅行  TRAVEL ").count == 1, "Whitespace-separated terms")
        check(filtered("全部", nil, "旅行 百度").isEmpty, "All terms required")
        check(filtered("全部", nil, " \n ").count == 3, "Whitespace-only search")
        let bundle = WorkspaceInsights.successfulLinks(jobs)
        check(bundle == "夸克：https://pan.quark.cn/s/ownedQuark?pwd=abcd", "Bundle contains owned share and current code")
        check(!bundle.contains("fixture"), "Never export failed or uncertain original URLs")
        check(WorkspaceInsights.successfulLinks(jobs + [jobs[0]]) == bundle, "Deduplicate successful exports")
        check(WorkspaceInsights.successfulLinks(filtered("需处理")).isEmpty, "Empty actionable export")
        var invalidDone = jobs[2]; invalidDone.status = .done
        check(WorkspaceInsights.successfulLinks([invalidDone]).isEmpty, "Completed record without result excluded")
        invalidDone.result = TransferResult(shareURL: "", code: "", title: "")
        check(WorkspaceInsights.successfulLinks([invalidDone]).isEmpty, "Empty owned URL excluded")
        let readiness = WorkspaceInsights.publication(source, jobs: jobs)
        check(readiness.ready == 1 && readiness.pending == 2, "Partial publication explicit")
        check(WorkspaceInsights.publication("普通文案", jobs: jobs).pending == 0, "Copy without drive links")
        check(WorkspaceInsights.publication(source, jobs: []).pending == 3, "Unrecognized jobs remain pending")
        check(WorkspaceInsights.publication(jobs[0].originalURL + "?pwd=changed", jobs: jobs).ready == 1, "Code edits preserve source identity")
        check(WorkspaceInsights.publication(source + "\n" + jobs[0].originalURL, jobs: jobs).pending == 2, "Duplicate source links counted once")
        jobs[1].status = .running
        check(filtered("执行中").map(\.id) == [jobs[1].id], "Running filter")
        check(filtered("需处理").map(\.id) == [jobs[2].id], "Running excluded from retry queue")
        print("PASS: \(count) workspace insights checks")
    }
}
