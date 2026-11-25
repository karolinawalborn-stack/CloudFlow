import Foundation
import Security

enum Vault {
    static let service = "app.cloudflow.personal"
    static func read(_ name: String) -> String {
        let request = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name,
                       kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary
        var result: CFTypeRef?
        guard SecItemCopyMatching(request, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    @discardableResult static func write(_ value: String, to name: String) -> Bool {
        let request: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name]
        if value.isEmpty {
            let status = SecItemDelete(request as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [CFString: Any] = [kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

struct ServiceError: LocalizedError {
    let message: String
    let uncertain: Bool
    init(_ message: String, uncertain: Bool = false) { self.message = message; self.uncertain = uncertain }
    var errorDescription: String? { message }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct Service {
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    private static func endpoint(_ base: String, path: String) throws -> URL {
        guard var u = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              u.scheme?.lowercased() == "https", let host = u.host, !host.isEmpty,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else {
            throw ServiceError("服务地址需要是 HTTPS，且不能内嵌账号或查询参数。")
        }
        if u.path.hasSuffix("/") { u.path.removeLast() }
        u.path += path
        guard let url = u.url else { throw ServiceError("服务地址无效。") }
        return url
    }

    private static func request<T: Decodable>(_ type: T.Type, base: String, path: String, token: String,
                                               body: Data? = nil, isTransfer: Bool = false) async throws -> T {
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, !secret.contains(where: { $0.isNewline }) else { throw ServiceError("请填写有效的服务密钥。") }
        var request = URLRequest(url: try endpoint(base, path: path), timeoutInterval: isTransfer ? 150 : 45)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ServiceError(isTransfer ? "网络中断，转存结果待核对。" : "连接失败，请检查地址和网络。", uncertain: isTransfer) }
        guard let http = response as? HTTPURLResponse else { throw ServiceError("服务未返回有效响应。", uncertain: isTransfer) }
        guard (200..<300).contains(http.statusCode) else {
            let known = try? JSONDecoder().decode(Failure.self, from: data)
            throw ServiceError(isTransfer ? (known?.error ?? "网盘服务返回 HTTP \(http.statusCode)。") : "模型服务返回 HTTP \(http.statusCode)。",
                               uncertain: isTransfer && (known?.uncertain ?? (http.statusCode >= 500)))
        }
        guard let result = try? JSONDecoder().decode(type, from: data) else { throw ServiceError("服务返回格式不匹配。", uncertain: isTransfer) }
        return result
    }

    static func status(base: String, key: String) async throws -> [Disk: Bool] {
        let health = try await request(Health.self, base: base, path: "/api/v1/status", token: key)
        return Dictionary(uniqueKeysWithValues: Disk.allCases.map { ($0, health.providers[$0.rawValue] ?? false) })
    }

    static func transfer(_ job: ShareJob, base: String, key: String) async throws -> TransferResult {
        let input = TransferInput(id: job.id.uuidString, url: job.originalURL, code: job.code)
        let result = try await request(TransferResult.self, base: base, path: "/api/v1/transfers", token: key,
                                       body: try JSONEncoder().encode(input), isTransfer: true)
        return try verified(result, for: job)
    }

    static func lookup(_ job: ShareJob, base: String, key: String) async throws -> TransferResult {
        let result = try await request(TransferResult.self, base: base, path: "/api/v1/transfers/" + job.id.uuidString,
                                       token: key, isTransfer: true)
        return try verified(result, for: job)
    }

    private static func verified(_ result: TransferResult, for job: ShareJob) throws -> TransferResult {
        guard let url = URLComponents(string: result.shareURL), url.scheme?.lowercased() == "https", url.host?.lowercased() == job.disk.host,
              url.user == nil, url.password == nil, url.port == nil else { throw ServiceError("服务未返回有效的新分享链接。", uncertain: true) }
        return result
    }

    static func models(base: String, key: String) async throws -> [String] {
        let response = try await request(ModelList.self, base: base, path: "/models", token: key)
        return Set(response.data.map(\.id).filter { !$0.isEmpty }).sorted()
    }

    static func rewrite(_ source: String, tone: String, model: String, base: String, key: String) async throws -> String {
        var protected = source
        var tokens: [(String, String)] = []
        var originalLinks = Set<String>()
        let prefix = "CF" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        for job in ShareText.parse(source) where originalLinks.insert(job.originalURL).inserted {
            let marker = "[\(prefix)_\(tokens.count + 1)]"
            protected = protected.replacingOccurrences(of: job.originalURL, with: marker)
            tokens.append((marker, job.originalURL))
        }
        let input = ChatInput(model: model, messages: [
            Message(role: "system", content: "改写为中文推广文案，语气：\(tone)。保留事实和所有 CF 占位符，不增造链接、不编造福利，输出正文。"),
            Message(role: "user", content: protected)
        ])
        let reply = try await request(ChatReply.self, base: base, path: "/chat/completions", token: key,
                                      body: try JSONEncoder().encode(input))
        guard var draft = reply.choices.first?.message.content, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError("模型没有返回可用正文。")
        }
        for (marker, link) in tokens {
            guard draft.contains(marker) else { throw ServiceError("模型遗漏了网盘链接位置，已保留原文。请重试或直接替换链接。") }
            draft = draft.replacingOccurrences(of: marker, with: link)
        }
        return draft
    }

    private struct Failure: Decodable { let error: String; let uncertain: Bool? }
    private struct Health: Decodable { let providers: [String: Bool] }
    private struct TransferInput: Encodable { let id: String; let url: String; let code: String }
    private struct ModelList: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
    private struct Message: Codable { let role: String; let content: String? }
    private struct ChatInput: Encodable { let model: String; let messages: [Message] }
    private struct ChatReply: Decodable { struct Choice: Decodable { let message: Message }; let choices: [Choice] }
}
