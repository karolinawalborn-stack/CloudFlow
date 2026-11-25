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

    var configured: Bool { !cookie.isEmpty || !refreshToken.isEmpty || !accessToken.isEmpty }
    static func read(_ disk: Disk) -> DriveAccount {
        guard let data = Vault.read("drive." + disk.rawValue).data(using: .utf8),
              let account = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return account
    }
    func save(_ disk: Disk) throws {
        let data = try JSONEncoder().encode(self)
        guard Vault.write(String(decoding: data, as: UTF8.self), to: "drive." + disk.rawValue) else {
            throw ServiceError("登录信息未能保存到手机钥匙串。")
        }
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

