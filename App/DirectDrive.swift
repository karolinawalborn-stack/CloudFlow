import Foundation

@MainActor final class DirectDrive {
    typealias Checkpoint = (TransferCheckpoint) throws -> Void
    let disk: Disk
    var account: DriveAccount
    let http: DriveHTTP
    private let quarkBase = "https://drive-pc.quark.cn/1/clouddrive"
    private let quarkQuery = ["pr": "ucpro", "fr": "pc", "uc_param_str": ""]
    init(_ disk: Disk, account: DriveAccount? = nil, http: DriveHTTP? = nil) {
        self.disk = disk
        let loaded = account ?? DriveAccount.read(disk)
        self.account = loaded
        self.http = http ?? DriveHTTP(disk: disk, account: loaded)
    }
    func validate() async throws {
        defer { http.close() }
        guard account.configured else { throw ServiceError("请先登录" + disk.title + "网盘。") }
        switch disk {
        case .quark:
            let result = try await http.json(quarkBase + "/file/sort", query: quarkQuery.merging(["pdir_fid": "0", "_page": "1", "_size": "1"]) { _, new in new })
            guard result["data"] is [String: Any] else { throw ServiceError("夸克登录状态未生效。") }
        case .baidu: _ = try await baiduToken()
        case .xunlei:
            if account.usesWebsiteSession != true { try await refreshXunlei() }
            _ = try await xunlei("/files", query: ["parent_id": "", "limit": "1"])
        }
        account.verifiedAt = Date(); try account.save(disk)
    }
    func transfer(_ job: ShareJob, checkpoint: @escaping Checkpoint) async throws -> TransferResult {
        guard account.configured else { throw ServiceError("请先登录" + disk.title + "网盘。") }
        defer { http.close() }
        var point = job.checkpoint
        if let prior = point, [.saving, .sharing].contains(prior.stage), prior.taskID.isEmpty {
            throw ServiceError("上次请求未取得任务编号，请先到网盘核对；确认未执行后可重置此任务。", uncertain: true)
        }
        do {
            let result: TransferResult
            switch disk {
            case .quark: result = try await transferQuark(job, point: &point, checkpoint: checkpoint)
            case .baidu: result = try await transferBaidu(job, point: &point, checkpoint: checkpoint)
            case .xunlei: result = try await transferXunlei(job, point: &point, checkpoint: checkpoint)
            }
            guard ShareText.importedShare(result.shareText, for: job) != nil else { throw ServiceError("网盘未返回同平台的新分享链接。", uncertain: true) }
            return result
        } catch {
            let uncertain = (error as? ServiceError)?.uncertain == true || point != nil
            throw ServiceError(error.localizedDescription, uncertain: uncertain)
        }
    }
    private func q(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, mutation: Bool = false) async throws -> [String: Any] {
        let result = try await http.json(quarkBase + path, query: quarkQuery.merging(query) { _, new in new }, body: body, mutation: mutation)
        return DriveJSON.dict(result, "data")
    }
    private func qTask(_ id: String) async throws -> [String: Any] {
        for _ in 0..<60 {
            try Task.checkCancellation()
            let data = try await q("/task", query: ["task_id": id])
            if DriveJSON.string(data, "status") == "2" { return data }
            let message = DriveJSON.string(data, "err_msg")
            if !message.isEmpty { throw ServiceError("夸克：" + message, uncertain: true) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw ServiceError("夸克任务仍在执行，可稍后继续核对。", uncertain: true)
    }
    private func transferQuark(_ job: ShareJob, point: inout TransferCheckpoint?, checkpoint: Checkpoint) async throws -> TransferResult {
        let id = URL(string: job.originalURL)!.lastPathComponent
        if point == nil {
            let tokenData = try await q("/share/sharepage/token", body: ["pwd_id": id, "passcode": job.code])
            var token = try DriveJSON.require(tokenData, "stoken")
            token = token.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            var rows: [[String: Any]] = []; var title = DriveJSON.string(tokenData, "title")
            var page = 1
            while true {
                let detail = try await q("/share/sharepage/detail", query: ["pwd_id": id, "stoken": token, "pdir_fid": "0", "force": "0", "_page": String(page), "_size": "100", "_fetch_total": "1", "_fetch_share": "1", "_sort": "file_type:asc,updated_at:desc"])
                let list = DriveJSON.rows(detail, "list"); rows += list
                if title.isEmpty { title = DriveJSON.string(detail, "share.title") }
                let updated = DriveJSON.string(detail, "share_stoken"); if !updated.isEmpty { token = updated }
                if list.count < 100 { break }; page += 1
                guard page <= 1000 else { throw ServiceError("分享顶层文件超过十万项，请拆分分享。") }
            }
            let ids = rows.map { DriveJSON.string($0, "fid") }, tokens = rows.map { DriveJSON.string($0, "share_fid_token") }
            guard !ids.isEmpty, !ids.contains(""), !tokens.contains("") else { throw ServiceError("夸克分享为空或文件凭据失效。") }
            point = TransferCheckpoint(stage: .saving, title: title); try checkpoint(point!)
            let saved = try await q("/share/sharepage/save", query: ["entry": "update_share"], body: ["fid_list": ids, "fid_token_list": tokens, "to_pdir_fid": account.directory.isEmpty ? "0" : account.directory, "pwd_id": id, "stoken": token, "pdir_fid": "0", "scene": "link"], mutation: true)
            point!.taskID = try DriveJSON.require(saved, "task_id", uncertain: true); try checkpoint(point!)
        }
        if point!.stage == .saving {
            let task = try await qTask(point!.taskID)
            let ids = DriveJSON.strings(DriveJSON.value(task, "save_as.save_as_top_fids"))
            guard !ids.isEmpty else { throw ServiceError("夸克未返回转存后文件编号。", uncertain: true) }
            point!.savedIDs = ids; point!.stage = .saved; point!.taskID = ""; try checkpoint(point!)
        }
        if point!.stage == .saved {
            point!.stage = .sharing; point!.taskID = ""; try checkpoint(point!)
            let shared = try await q("/share", body: ["fid_list": point!.savedIDs, "title": point!.title, "url_type": 1, "expired_type": 1], mutation: true)
            point!.taskID = DriveJSON.string(shared, "task_id"); point!.shareID = DriveJSON.string(shared, "share_id")
            // A synchronous share response is also a valid resume point.
            if !point!.shareID.isEmpty { point!.stage = .complete }
            try checkpoint(point!)
        }
        if point!.stage == .sharing {
            let task = try await qTask(point!.taskID)
            point!.shareID = try DriveJSON.require(task, "share_id", uncertain: true)
            point!.stage = .complete; try checkpoint(point!)
        }
        let result = try await q("/share/password", body: ["share_id": point!.shareID])
        return TransferResult(shareURL: try DriveJSON.require(result, "share_url", uncertain: true), code: DriveJSON.string(result, "passcode"), title: point!.title)
    }
    private func baiduToken() async throws -> String {
        let data = try await http.json("https://pan.baidu.com/api/gettemplatevariable", query: ["clienttype": "0", "app_id": "38824127", "web": "1", "fields": "[\"bdstoken\",\"uk\"]"])
        return try DriveJSON.require(data, "result.bdstoken")
    }
    private func firstMatch(_ pattern: String, in source: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: source) else { return "" }
        return String(source[range])
    }
    private func transferBaidu(_ job: ShareJob, point: inout TransferCheckpoint?, checkpoint: Checkpoint) async throws -> TransferResult {
        let token = try await baiduToken()
        let common = ["bdstoken": token, "channel": "chunlei", "clienttype": "0", "web": "1"]
        if point == nil {
            let id = URL(string: job.originalURL)!.lastPathComponent
            var sekey = ""
            if !job.code.isEmpty {
                let verified = try await http.json("https://pan.baidu.com/share/verify", query: common.merging(["surl": id.hasPrefix("1") ? String(id.dropFirst()) : id]) { _, new in new }, form: ["pwd": job.code, "vcode": "", "vcode_str": ""], headers: ["Referer": job.originalURL])
                let randsk = DriveJSON.string(verified, "randsk")
                sekey = randsk.removingPercentEncoding ?? randsk
                if !sekey.isEmpty {
                    for old in http.storage.cookies(for: Disk.baidu.homeURL) ?? [] where old.name == "BDCLND" { http.storage.deleteCookie(old) }
                    if let cookie = HTTPCookie(properties: [.domain: "pan.baidu.com", .path: "/", .name: "BDCLND", .value: sekey, .secure: "TRUE"]) { http.storage.setCookie(cookie) }
                }
            }
            if sekey.isEmpty { sekey = (http.storage.cookies(for: Disk.baidu.homeURL) ?? []).first { $0.name == "BDCLND" }?.value ?? "" }
            let raw = try await http.raw("https://pan.baidu.com/s/" + id, query: job.code.isEmpty ? [:] : ["pwd": job.code], headers: ["Referer": job.originalURL])
            let html = String(decoding: raw, as: UTF8.self)
            let pageData = BaiduSharePage.decode(html)
            let shareID = pageData.shareID
            let owner = pageData.owner
            guard !shareID.isEmpty, !owner.isEmpty else { throw ServiceError("百度分享页需要验证或已失效，请在网盘登录页打开该分享。") }
            var files = pageData.files; var page = 1
            // The share page already contains the authoritative first page. Fetch the
            // listing only when it is absent or pagination is needed (e.g. >100 files).
            while files.isEmpty || files.count >= 100 {
                if !files.isEmpty && page == 1 { page = 2 }
                let list = try await http.json("https://pan.baidu.com/share/list", query: common.merging(["shareid": shareID, "uk": owner, "shorturl": id.hasPrefix("1") ? String(id.dropFirst()) : id, "sekey": sekey, "root": "1", "page": String(page), "num": "100", "order": "other", "desc": "1", "showempty": "0"]) { _, new in new }, headers: ["Referer": job.originalURL])
                let rows = DriveJSON.rows(list, "list"); files += rows
                if rows.count < 100 { break }; page += 1
                guard page <= 1000 else { throw ServiceError("分享顶层文件超过十万项，请拆分分享。") }
            }
            let ids = files.map { DriveJSON.string($0, "fs_id") }
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { throw ServiceError("百度分享中没有可转存文件。") }
            let folder = account.directory.isEmpty ? "/CloudFlow" : (account.directory.hasPrefix("/") ? account.directory : "/" + account.directory)
            let created = try await http.json("https://pan.baidu.com/api/create", query: ["a": "commit", "bdstoken": token], form: ["path": folder, "isdir": "1", "block_list": "[]"])
            _ = created
            point = TransferCheckpoint(stage: .saving, title: DriveJSON.string(files[0], "server_filename")); try checkpoint(point!)
            let save = try await http.json("https://pan.baidu.com/share/transfer", query: common.merging(["shareid": shareID, "from": owner, "ondup": "newcopy"]) { _, new in new }, form: ["fsidlist": "[" + ids.joined(separator: ",") + "]", "path": folder, "sekey": sekey], headers: ["Referer": job.originalURL], mutation: true)
            let newIDs = DriveJSON.rows(save, "extra.list").map { DriveJSON.string($0, "to_fs_id") }
            guard newIDs.count == ids.count, newIDs.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { throw ServiceError("百度转存请求已提交，但新文件编号不完整，请到网盘核对。", uncertain: true) }
            point!.savedIDs = newIDs; point!.stage = .saved; try checkpoint(point!)
        }
        guard point!.stage == .saved else { throw ServiceError("百度分享请求结果待核对，请到网盘确认后导入新链接。", uncertain: true) }
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let password = String((0..<4).map { _ in alphabet.randomElement()! })
        point!.stage = .sharing; try checkpoint(point!)
        let shared = try await http.json("https://pan.baidu.com/share/set", query: common.merging(["app_id": "250528"]) { _, new in new }, form: ["fid_list": "[" + point!.savedIDs.joined(separator: ",") + "]", "period": "0", "pwd": password, "schannel": "4", "channel_list": "[]", "is_knowledge": "0", "public": "0", "eflag_disable": "true", "linkOrQrcode": "link"], mutation: true)
        return TransferResult(shareURL: try DriveJSON.require(shared, "link", uncertain: true), code: password, title: point!.title)
    }
    private func refreshXunlei() async throws {
        if !account.accessToken.isEmpty {
            let parts = account.accessToken.split(separator: ".")
            if parts.count > 1 {
                var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
                if let data = Data(base64Encoded: payload), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let expiry = claims["exp"] as? Double, expiry <= Date().timeIntervalSince1970 + 60 {
                    account.accessToken = ""
                }
            }
            if !account.accessToken.isEmpty { return }
        }
        guard !account.refreshToken.isEmpty else { throw ServiceError("请在迅雷页面完成登录并保存会话。") }
        let token = try await http.json("https://xluser-ssl.xunlei.com/v1/auth/token", body: ["client_id": account.clientID, "grant_type": "refresh_token", "refresh_token": account.refreshToken])
        account.accessToken = try DriveJSON.require(token, "access_token")
        let refresh = DriveJSON.string(token, "refresh_token"); if !refresh.isEmpty { account.refreshToken = refresh }
        try account.save(.xunlei)
    }
    private func xunlei(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, mutation: Bool = false) async throws -> [String: Any] {
        if account.usesWebsiteSession == true {
            return try await XunleiWebClient.shared.request(path, query: query, body: body, mutation: mutation)
        }
        try await refreshXunlei()
        let headers = ["Authorization": "Bearer " + account.accessToken, "x-captcha-token": account.captchaToken, "x-client-id": account.clientID, "x-device-id": account.deviceID]
        let result = try await http.json("https://api-pan.xunlei.com/drive/v1" + path, query: query, body: body, headers: headers, mutation: mutation)
        return (result["data"] as? [String: Any]) ?? result
    }
    private func transferXunlei(_ job: ShareJob, point: inout TransferCheckpoint?, checkpoint: Checkpoint) async throws -> TransferResult {
        if point == nil {
            let id = URL(string: job.originalURL)!.lastPathComponent
            var files: [[String: Any]] = []; var pageToken = ""; var info: [String: Any] = [:]
            repeat {
                info = try await xunlei("/share", query: ["share_id": id, "pass_code": job.code, "limit": "100", "page_token": pageToken, "pass_code_token": "", "thumbnail_size": "SIZE_SMALL"])
                guard DriveJSON.string(info, "share_status") == "OK" else { throw ServiceError("迅雷：分享不可用，请检查提取码。") }
                files += DriveJSON.rows(info, "files")
                let next = DriveJSON.string(info, "next_page_token")
                guard next.isEmpty || next != pageToken else { throw ServiceError("迅雷分页游标未推进。") }; pageToken = next
            } while !pageToken.isEmpty
            let ids = files.map { DriveJSON.string($0, "id") }
            guard !ids.isEmpty, !ids.contains("") else { throw ServiceError("迅雷分享中没有可转存文件。") }
            point = TransferCheckpoint(stage: .saving, title: DriveJSON.string(info, "title")); try checkpoint(point!)
            let save = try await xunlei("/share/restore", body: ["parent_id": account.directory, "share_id": id, "pass_code_token": DriveJSON.string(info, "pass_code_token"), "ancestor_ids": [], "specify_parent_id": true, "file_ids": ids], mutation: true)
            point!.taskID = try DriveJSON.require(save, "restore_task_id", uncertain: true); try checkpoint(point!)
        }
        if point!.stage == .saving {
            var completed = false
            for _ in 0..<60 {
                try Task.checkCancellation()
                let result = try await xunlei("/tasks/" + point!.taskID)
                if DriveJSON.string(result, "phase") == "PHASE_TYPE_ERROR" { throw ServiceError("迅雷转存任务失败，请核对网盘。", uncertain: true) }
                if DriveJSON.string(result, "progress") == "100" {
                    var mapping = DriveJSON.dict(result, "params.trace_file_ids")
                    if mapping.isEmpty, let data = DriveJSON.string(result, "params.trace_file_ids").data(using: .utf8) { mapping = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
                    let ids = mapping.values.compactMap { $0 as? String }
                    guard !ids.isEmpty, !ids.contains("") else { throw ServiceError("迅雷未返回转存后文件编号。", uncertain: true) }
                    point!.savedIDs = ids; point!.stage = .saved; point!.taskID = ""; try checkpoint(point!); completed = true; break
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard completed else { throw ServiceError("迅雷任务仍在执行，可稍后继续核对。", uncertain: true) }
        }
        guard point!.stage == .saved else { throw ServiceError("迅雷分享结果待核对，请到网盘确认后导入新链接。", uncertain: true) }
        point!.stage = .sharing; try checkpoint(point!)
        let result = try await xunlei("/share", body: ["file_ids": point!.savedIDs, "share_to": "copy", "params": ["subscribe_push": "false", "WithPassCodeInLink": "true"], "title": point!.title.isEmpty ? "云盘资源分享" : point!.title, "restore_limit": "-1", "expiration_days": "-1"], mutation: true)
        return TransferResult(shareURL: try DriveJSON.require(result, "share_url", uncertain: true), code: DriveJSON.string(result, "pass_code"), title: point!.title)
    }
}

