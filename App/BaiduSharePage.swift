import Foundation

struct BaiduSharePage {
    let shareID: String
    let owner: String
    let files: [[String: Any]]
    static func decode(_ html: String) -> Self {
        func capture(_ pattern: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(match.range(at: 1), in: html) else { return "" }
            return String(html[range])
        }
        func scalar(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
        // Parse complete JSON values from known page-data assignments, rather than
        // accidentally matching the signed-in user's uk or nested child files.
        for anchor in ["locals.mset", "yunData.setData", "window.yunData", "var yunData", "let yunData", "const yunData"] {
            guard let start = html.range(of: anchor)?.upperBound, let objectStart = html[start...].firstIndex(of: "{"),
                  let raw = balanced(html, at: objectStart), let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let shareID = scalar(object["shareid"] ?? object["share_id"])
            let owner = scalar(object["share_uk"] ?? object["uk"])
            let list = (object["file_list"] as? [String: Any])?["list"] ?? object["file_list"] ?? object["fileList"] ?? object["list"]
            if !shareID.isEmpty, !owner.isEmpty { return Self(shareID: shareID, owner: owner, files: list as? [[String: Any]] ?? []) }
        }
        let shareID = capture(#""(?:shareid|share_id)"\s*:\s*"?(\d+)"#)
        var owner = capture(#""share_uk"\s*:\s*"?(\d+)"#)
        if owner.isEmpty { owner = capture(#""uk"\s*:\s*"?(\d+)"#) }
        var files: [[String: Any]] = []
        if let regex = try? NSRegularExpression(pattern: #""(?:file_list|fileList|list)"\s*:\s*(\[)"#) {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html), let raw = balanced(html, at: range.lowerBound), let data = raw.data(using: .utf8), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.allSatisfy({ $0["fs_id"] != nil }) else { continue }
                files = rows; break
            }
        }
        return Self(shareID: shareID, owner: owner, files: files)
    }
    private static func balanced(_ text: String, at start: String.Index) -> String? {
        var depth = 0; var quoted = false; var escaped = false
        for index in text.indices where index >= start {
            let char = text[index]
            if quoted {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { quoted = false }
                continue
            }
            if char == "\"" { quoted = true }
            else if char == "{" || char == "[" { depth += 1 }
            else if char == "}" || char == "]" { depth -= 1; if depth == 0 { return String(text[start...index]) } }
        }
        return nil
    }
}

