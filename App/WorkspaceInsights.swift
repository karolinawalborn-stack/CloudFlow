import Foundation

/// Local presentation helpers; never initiate or retry provider requests.
enum WorkspaceInsights {
    static func matching(_ jobs: [ShareJob], status: String, disk: Disk?, search: String) -> [ShareJob] {
        let terms = search.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return jobs.filter { job in
            guard disk == nil || job.disk == disk else { return false }
            switch status {
            case "成功": guard job.status == .done else { return false }
            case "需处理": guard [.ready, .failed, .uncertain].contains(job.status) else { return false }
            case "执行中": guard job.status == .running else { return false }
            default: break
            }
            let content = [job.disk.title, job.originalURL, job.result?.title ?? "", job.result?.shareURL ?? "", job.error ?? ""].joined(separator: " ")
            return terms.allSatisfy { content.localizedStandardContains($0) }
        }
    }

    static func successfulLinks(_ jobs: [ShareJob]) -> String {
        var seen = Set<String>()
        return jobs.compactMap { job -> String? in
            guard job.status == .done, let result = job.result, !result.shareURL.isEmpty,
                  seen.insert(result.shareText).inserted else { return nil }
            return job.disk.title + "：" + result.shareText
        }.joined(separator: "\n")
    }

    static func publication(_ text: String, jobs: [ShareJob]) -> (ready: Int, pending: Int) {
        let links = ShareText.parse(text)
        let ready = Set(jobs.filter { $0.status == .done && $0.result != nil }.map { ShareText.identity($0.originalURL) })
        let count = links.filter { ready.contains(ShareText.identity($0.originalURL)) }.count
        return (count, links.count - count)
    }
}
