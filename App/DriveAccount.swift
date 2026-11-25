import Foundation
import WebKit

struct DriveAccount: Codable {
    var cookie = ""
    var refreshToken = ""
    var accessToken = ""
    var captchaToken = ""
    var clientID = "Xqp0kJBXWhwaTpB6"
    var deviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var directory = ""
    var verifiedAt: Date?
    var scopedCookies: [StoredDriveCookie]?
    var usesWebsiteSession: Bool?

    var configured: Bool { !cookie.isEmpty || !refreshToken.isEmpty || !accessToken.isEmpty }
    static func read(_ disk: Disk) -> DriveAccount {
        guard let data = Vault.read("drive." + disk.rawValue).data(using: .utf8),
              var account = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if disk == .xunlei, account.usesWebsiteSession == nil { account.usesWebsiteSession = true }
        return account
    }
    func save(_ disk: Disk) throws {
        let data = try JSONEncoder().encode(self)
        guard Vault.write(String(decoding: data, as: UTF8.self), to: "drive." + disk.rawValue) else {
            throw ServiceError("登录信息未能保存到手机钥匙串。")
        }
    }
}

struct StoredDriveCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let expires: Date?
    init(_ cookie: HTTPCookie) { name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path; secure = cookie.isSecure; expires = cookie.expiresDate }
    var cookie: HTTPCookie? {
        var fields: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { fields[.secure] = "TRUE" }
        if let expires { fields[.expires] = expires }
        return HTTPCookie(properties: fields)
    }
}

@MainActor enum DriveWebData {
    static func cookies(for disk: Disk) async -> [HTTPCookie] {
        let all: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let suffix: String
        switch disk { case .quark: suffix = "quark.cn"; case .baidu: suffix = "baidu.com"; case .xunlei: suffix = "xunlei.com" }
        return all.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == suffix || domain.hasSuffix("." + suffix)
        }
    }
    static func signOut(_ disk: Disk) async throws {
        if disk == .xunlei { XunleiWebClient.shared.reset() }
        for cookie in await cookies(for: disk) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                WKWebsiteDataStore.default().httpCookieStore.delete(cookie) { continuation.resume() }
            }
        }
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { continuation.resume(returning: $0) }
        }
        let domain = disk == .quark ? "quark.cn" : disk == .baidu ? "baidu.com" : "xunlei.com"
        let owned = records.filter { $0.displayName == domain || $0.displayName.hasSuffix("." + domain) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: owned) { continuation.resume() }
        }
        guard Vault.write("", to: "drive." + disk.rawValue) else { throw ServiceError("钥匙串清理失败，请重试。") }
    }
}

