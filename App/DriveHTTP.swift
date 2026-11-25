import Foundation

enum DriveJSON {
    static func value(_ object: [String: Any], _ path: String) -> Any? {
        var node: Any = object
        for key in path.split(separator: ".").map(String.init) {
            guard let next = (node as? [String: Any])?[key] else { return nil }
            node = next
        }
        return node
    }
    static func string(_ object: [String: Any], _ path: String) -> String {
        if let string = value(object, path) as? String { return string }
        if let number = value(object, path) as? NSNumber { return number.stringValue }
        return ""
    }
    static func dict(_ object: [String: Any], _ path: String) -> [String: Any] { value(object, path) as? [String: Any] ?? [:] }
    static func rows(_ object: [String: Any], _ path: String) -> [[String: Any]] { value(object, path) as? [[String: Any]] ?? [] }
    static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { item in
            if let string = item as? String { return string }
            return (item as? NSNumber)?.stringValue
        }
    }
    static func encoded(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    static func require(_ object: [String: Any], _ path: String, uncertain: Bool = false) throws -> String {
        let result = string(object, path)
        guard !result.isEmpty else { throw ServiceError("网盘响应缺少 " + path + "，请更新登录或核对网盘记录。", uncertain: uncertain) }
        return result
    }
}

final class DriveHTTP: NSObject, URLSessionTaskDelegate {
    let disk: Disk
    private let configuration = URLSessionConfiguration.ephemeral
    var storage: HTTPCookieStorage { configuration.httpCookieStorage! }
    private lazy var session: URLSession = {
        let config = configuration
        config.httpCookieStorage = storage
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 40
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    init(disk: Disk, account: DriveAccount) {
        self.disk = disk
        super.init()
        for pair in account.cookie.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let cookie = HTTPCookie(properties: [.domain: "." + (disk == .quark ? "quark.cn" : disk == .baidu ? "baidu.com" : "xunlei.com"), .path: "/", .name: parts[0], .value: parts[1], .secure: "TRUE"]) else { continue }
            storage.setCookie(cookie)
        }
    }
    func close() { session.finishTasksAndInvalidate() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, allows(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
    private func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        switch disk {
        case .quark: return ["pan.quark.cn", "drive-pc.quark.cn"].contains(host)
        case .baidu: return host == "pan.baidu.com"
        case .xunlei: return ["pan.xunlei.com", "api-pan.xunlei.com", "xluser-ssl.xunlei.com"].contains(host)
        }
    }
    func raw(_ base: String, query: [String: String] = [:], json: [String: Any]? = nil,
             form: [String: String]? = nil, headers: [String: String] = [:], mutation: Bool = false) async throws -> Data {
        guard var parts = URLComponents(string: base), let initial = parts.url, allows(initial) else { throw ServiceError("网盘请求地址无效。") }
        parts.queryItems = (parts.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw ServiceError("网盘请求地址无效。") }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(disk.homeURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://" + disk.host, forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if let json {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        if let form {
            var body = URLComponents(); body.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpMethod = "POST"
            request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ServiceError(mutation ? "请求中断，结果待核对。请继续核对任务，避免重复转存。" : "网盘连接失败，请检查网络或重新登录。", uncertain: mutation) }
        guard let http = response as? HTTPURLResponse else { throw ServiceError("网盘返回异常响应。", uncertain: mutation) }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError("网盘返回 HTTP \(http.statusCode)。请重新登录，若提示验证请在登录页完成。", uncertain: mutation && http.statusCode >= 500)
        }
        return data
    }
    func json(_ base: String, query: [String: String] = [:], body: [String: Any]? = nil,
              form: [String: String]? = nil, headers: [String: String] = [:], mutation: Bool = false) async throws -> [String: Any] {
        let data = try await raw(base, query: query, json: body, form: form, headers: headers, mutation: mutation)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError("网盘未返回 JSON，可能需要在登录页完成验证。", uncertain: mutation)
        }
        switch disk {
        case .quark:
            if let status = object["status"] as? Int, status != 200 { throw ServiceError("夸克：" + (DriveJSON.string(object, "message").isEmpty ? "请求失败 \(status)" : DriveJSON.string(object, "message"))) }
        case .baidu:
            if let code = object["errno"] as? Int, code != 0, !(base.hasSuffix("/api/create") && [4, -2].contains(code)) { throw ServiceError("百度：" + (DriveJSON.string(object, "errmsg").isEmpty ? "错误码 \(code)，请检查提取码和登录状态。" : DriveJSON.string(object, "errmsg"))) }
        case .xunlei:
            if !DriveJSON.string(object, "error").isEmpty { throw ServiceError("迅雷：" + (DriveJSON.string(object, "error_description").isEmpty ? DriveJSON.string(object, "error") : DriveJSON.string(object, "error_description"))) }
            if let code = object["code"] as? Int, code != 0 { throw ServiceError("迅雷：" + DriveJSON.string(object, "message")) }
        }
        return object
    }
}

