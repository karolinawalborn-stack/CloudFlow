import Foundation
@main struct DomainTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); count += 1 }
    static func main() throws {
        let sample = "资源 📦 https://pan.quark.cn/s/abc123 提取码：QWER\nhttps://pan.xunlei.com/s/xyz456?pwd=9876\nhttps://pan.baidu.com/s/1Baidu123 密码 abcd"
        let jobs = ShareText.parse(sample)
        check(jobs.count == 3, "Recognize three providers")
        check(jobs.map(\.code) == ["QWER", "9876", "abcd"], "Associate codes")
        check(ShareText.parse("https://pan.quark.cn/s/a?pwd=1 https://pan.quark.cn/s/a?pwd=2").count == 1, "Dedupe")
        for url in ["http://pan.quark.cn/s/a", "https://pan.quark.cn.evil.com/s/a", "https://user@pan.baidu.com/s/a", "https://pan.xunlei.com:443/s/a", "https://pan.baidu.com/notshare"] {
            check(ShareText.parse(url).isEmpty, "Reject invalid URL")
        }
        check(ShareText.parse("https://pan.xunlei.com/s/abc?pass_code=code").first?.code == "code", "Support pass_code")
        var done = jobs[0]; done.status = .done
        done.result = TransferResult(shareURL: "https://pan.quark.cn/s/new", code: "NEW1", title: "资源")
        let replaced = ShareText.rewriteLinks(sample, using: [done])
        check(replaced.count == 1, "Only completed links")
        check(replaced.text.contains("/s/new?pwd=NEW1 提取码：NEW1"), "Replace URL and code")
        check(replaced.text.contains(jobs[1].originalURL), "Preserve pending URLs")
        done.result = TransferResult(shareURL: "https://pan.quark.cn/s/new", code: "", title: "")
        check(!ShareText.rewriteLinks(sample, using: [done]).text.contains("QWER"), "Remove stale code")
        check(ShareText.importedShare(done.originalURL + "?pwd=changed", for: done) == nil, "Reject source identifier")
        check(ShareText.importedShare("https://pan.baidu.com/s/new", for: done) == nil, "Reject other provider")
        check(ShareText.importedShare("https://pan.quark.cn/s/new", for: done) != nil, "Accept new share")
        let oldJSON = #"{"id":"00000000-0000-0000-0000-000000000001","originalURL":"https://pan.quark.cn/s/a","disk":"quark","code":"","selected":true,"status":"ready"}"#
        let restored = try JSONDecoder().decode(ShareJob.self, from: Data(oldJSON.utf8))
        check(restored.checkpoint == nil, "Migrate existing records")
        var saved = restored; saved.checkpoint = TransferCheckpoint(stage: .saved, savedIDs: ["new1", "new2"], title: "多文件")
        let roundtrip = try JSONDecoder().decode(ShareJob.self, from: JSONEncoder().encode(saved))
        check(roundtrip.checkpoint?.savedIDs == ["new1", "new2"], "Persist all identifiers")
        let link = TransferResult(shareURL: "https://pan.baidu.com/s/new?pwd=old&x=1", code: "next", title: "").shareText
        check(URLComponents(string: link)?.queryItems?.filter { $0.name == "pwd" }.map(\.value) == ["next"], "No duplicate code")
        print("PASS: \(count) domain regression checks")
    }
}
