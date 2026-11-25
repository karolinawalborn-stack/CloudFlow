import Foundation

enum Disk: String, Codable, CaseIterable, Identifiable {
    case quark, xunlei, baidu
    var id: String { rawValue }
    var title: String { switch self { case .quark: return "夸克"; case .xunlei: return "迅雷"; case .baidu: return "百度" } }
    var host: String { switch self { case .quark: return "pan.quark.cn"; case .xunlei: return "pan.xunlei.com"; case .baidu: return "pan.baidu.com" } }
}

struct ShareJob: Codable, Identifiable {
    enum Status: String, Codable { case ready, running, done, failed, uncertain }
    let id: UUID
    let originalURL: String
    let disk: Disk
    var code: String
    var selected = true
    var status = Status.ready
    var result: TransferResult?
    var error: String?
}

struct TransferResult: Codable {
    let shareURL: String
    let code: String
    let title: String

    var shareText: String {
        guard !code.isEmpty, var url = URLComponents(string: shareURL) else { return shareURL }
        let items = url.queryItems ?? []
        url.queryItems = items.filter { $0.name.lowercased() != "pwd" } + [URLQueryItem(name: "pwd", value: code)]
        return url.string ?? shareURL
    }
}

enum ShareText {
    private static let urls = try! NSRegularExpression(pattern: #"https?://[^\s<>"'，。；、！？“”（）【】]+"#, options: .caseInsensitive)
    private static let suffixCode = try! NSRegularExpression(pattern: #"^[\s,，;；:：）)】—-]*(?:提取码|访问码|密码)\s*[:：]?\s*([A-Za-z0-9]{1,12})(?![A-Za-z0-9])"#)
    private static let identifier = try! NSRegularExpression(pattern: #"^/s/[A-Za-z0-9_-]+$"#)

    static func parse(_ text: String) -> [ShareJob] {
        var seen = Set<String>()
        return captures(text).compactMap { item in
            guard let parts = URLComponents(string: item.link), parts.scheme?.lowercased() == "https",
                  let disk = Disk.allCases.first(where: { $0.host == parts.host?.lowercased() }),
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  identifier.firstMatch(in: parts.percentEncodedPath, range: NSRange(parts.percentEncodedPath.startIndex..., in: parts.percentEncodedPath)) != nil,
                  seen.insert(item.link).inserted else { return nil }
            let code = parts.queryItems?.first(where: { $0.name.lowercased() == "pwd" })?.value ?? item.code
            return ShareJob(id: UUID(), originalURL: item.link, disk: disk, code: code)
        }
    }

    static func rewriteLinks(_ text: String, using jobs: [ShareJob]) -> (text: String, count: Int) {
        var mapping: [String: TransferResult] = [:]
        for job in jobs where job.status == .done { if let result = job.result { mapping[job.originalURL] = result } }
        let source = text as NSString
        let output = NSMutableString(string: text)
        var count = 0
        for item in captures(text).reversed() {
            guard let result = mapping[item.link] else { continue }
            if let codeRange = item.codeRange {
                if result.code.isEmpty {
                    let end = NSMaxRange(codeRange)
                    if end <= source.length { output.deleteCharacters(in: NSRange(location: NSMaxRange(item.range), length: end - NSMaxRange(item.range))) }
                } else { output.replaceCharacters(in: codeRange, with: result.code) }
            }
            output.replaceCharacters(in: item.range, with: result.shareText)
            count += 1
        }
        return (String(output), count)
    }

    private struct Capture { let link: String; let range: NSRange; let code: String; let codeRange: NSRange? }

    private static func captures(_ text: String) -> [Capture] {
        let source = text as NSString
        let matches = urls.matches(in: text, range: NSRange(location: 0, length: source.length))
        return matches.enumerated().map { index, match in
            var urlRange = match.range
            while urlRange.length > 0 && ".,;!?)".utf16.contains(source.character(at: NSMaxRange(urlRange) - 1)) { urlRange.length -= 1 }
            let end = NSMaxRange(urlRange)
            let nextURL = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            let search = NSRange(location: end, length: max(0, min(nextURL - end, 80)))
            let codeRange = suffixCode.firstMatch(in: text, options: [.withTransparentBounds], range: search)?.range(at: 1)
            return Capture(link: source.substring(with: urlRange), range: urlRange,
                           code: codeRange.map { source.substring(with: $0) } ?? "", codeRange: codeRange)
        }
    }
}
