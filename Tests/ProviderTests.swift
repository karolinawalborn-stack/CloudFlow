import Foundation

final class FixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])!
    static var status = 200
    static var rawHandler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data: Data
            if let raw = Self.rawHandler { data = try raw(request) }
            else { data = try JSONSerialization.data(withJSONObject: Self.handler(request)) }
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct ProviderTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message); checks += 1 }
    static func bodyData(_ request: URLRequest) -> Data {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096); var collected = Data()
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; collected.append(contentsOf: buffer.prefix(count)) }
            data = collected
        }
        return data ?? Data()
    }
    static func jsonBody(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any]) ?? [:]
    }
    static func formBody(_ request: URLRequest) -> [String: String] {
        let text = String(decoding: bodyData(request), as: UTF8.self)
        return Dictionary((URLComponents(string: "https://example.invalid/?" + text)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
    }
    @MainActor static func driver(_ disk: Disk) -> DirectDrive {
        var account = DriveAccount(); account.cookie = "fixture=local"; account.accessToken = "fixture-access"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return DirectDrive(disk, account: account, http: DriveHTTP(disk: disk, account: account, configuration: config))
    }
    @MainActor static func main() async throws {
        var saves = 0; var shareIDs: [String] = []
        FixtureProtocol.handler = { request in
            let path = request.url!.path
            var data: [String: Any] = [:]
            switch path {
            case "/1/clouddrive/share/sharepage/token": data = ["stoken": "fixture-token", "title": "Fixture"]
            case "/1/clouddrive/share/sharepage/detail": data = ["list": [["fid": "source1", "share_fid_token": "a"], ["fid": "source2", "share_fid_token": "b"]]]
            case "/1/clouddrive/share/sharepage/save": saves += 1; data = ["task_id": "save-task"]
            case "/1/clouddrive/task":
                let task = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "task_id" }?.value
                data = task == "save-task" ? ["status": 2, "save_as": ["save_as_top_fids": ["saved1", "saved2"]]] : ["status": 2, "share_id": "share-result"]
            case "/1/clouddrive/share": shareIDs = jsonBody(request)["fid_list"] as? [String] ?? []; data = ["task_id": "share-task"]
            case "/1/clouddrive/share/password": data = ["share_url": "https://pan.quark.cn/s/fixture-new", "passcode": "new1"]
            default: preconditionFailure("Unexpected quark endpoint " + path)
            }
            return ["status": 200, "data": data]
        }
        let quark = ShareText.parse("https://pan.quark.cn/s/fixture-source")[0]
        var last: TransferCheckpoint?
        let result = try await driver(.quark).transfer(quark) { last = $0 }
        check(result.shareURL.contains("fixture-new"), "Quark returns new share")
        check(shareIDs == ["saved1", "saved2"], "Share all saved top-level items")
        check(last?.stage == .complete, "Quark complete checkpoint")
        check(saves == 1, "Exactly one save")
        var resumed = quark; resumed.checkpoint = TransferCheckpoint(stage: .saving, taskID: "save-task", title: "Fixture")
        _ = try await driver(.quark).transfer(resumed) { _ in }
        check(saves == 1, "Resume polls existing task without another save")
        var uncertain = quark; uncertain.checkpoint = TransferCheckpoint(stage: .saving)
        do { _ = try await driver(.quark).transfer(uncertain) { _ in }; preconditionFailure("Unknown save must stop") }
        catch { check((error as? ServiceError)?.uncertain == true, "Unknown remote write remains uncertain") }
        var writesAfterFailure = 0
        FixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("/save") { writesAfterFailure += 1 }
            if request.url!.path.hasSuffix("/token") { return ["status": 200, "data": ["stoken": "t"]] }
            return ["status": 200, "data": ["list": [["fid": "s", "share_fid_token": "t"]]]]
        }
        do { _ = try await driver(.quark).transfer(quark) { _ in throw ServiceError("disk full") }; preconditionFailure("Persist failure must abort") } catch {}
        check(writesAfterFailure == 0, "Failed checkpoint prevents remote save")
        let baidu = ShareText.parse("https://pan.baidu.com/s/fixture-source")[0]
        var baiduShareBody = ""
        FixtureProtocol.handler = { request in
            if request.url!.path == "/api/gettemplatevariable" { return ["errno": 0, "result": ["bdstoken": "fixture-token"]] }
            check(request.url!.path == "/share/set", "Baidu saved checkpoint only creates share")
            baiduShareBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ["errno": 0, "link": "https://pan.baidu.com/s/fixture-new"]
        }
        var baiduSaved = baidu; baiduSaved.checkpoint = TransferCheckpoint(stage: .saved, savedIDs: ["101", "102"], title: "Fixture")
        let baiduResult = try await driver(.baidu).transfer(baiduSaved) { _ in }
        check(baiduResult.code.count == 4, "Baidu creates four-character extraction code")
        // The fixture URLProtocol may expose form bytes through a body stream; response and endpoint checks remain authoritative.
        _ = baiduShareBody
        var xunleiShareIDs: [String] = []
        FixtureProtocol.handler = { request in
            switch request.url!.path {
            case "/drive/v1/share":
                if request.httpMethod == "POST" { xunleiShareIDs = jsonBody(request)["file_ids"] as? [String] ?? []; return ["share_url": "https://pan.xunlei.com/s/fixture-new", "pass_code": "1234"] }
                return ["share_status": "OK", "title": "Fixture", "pass_code_token": "pass", "files": [["id": "s1"], ["id": "s2"]]]
            case "/drive/v1/share/restore": return ["restore_task_id": "restore"]
            case "/drive/v1/tasks/restore": return ["progress": 100, "params": ["trace_file_ids": "{\"s1\":\"n1\",\"s2\":\"n2\"}"]]
            default: preconditionFailure("Unexpected xunlei endpoint")
            }
        }
        let xunlei = ShareText.parse("https://pan.xunlei.com/s/fixture-source")[0]
        let xunleiResult = try await driver(.xunlei).transfer(xunlei) { _ in }
        check(xunleiResult.code == "1234", "Xunlei returns generated extraction code")
        check(Set(xunleiShareIDs) == Set(["n1", "n2"]), "Xunlei shares all restored items")
        // A protected Baidu share carries its own uk, and the first page is
        // embedded in locals.mset. A stale listing call used to return -9.
        let html = #"<script>var currentUser={"uk":999};locals.mset({"shareid":123,"uk":456,"file_list":{"list":[{"fs_id":101,"server_filename":"资源一"},{"fs_id":102,"server_filename":"资源二"}]}});</script>"#
        let parsed = BaiduSharePage.decode(html)
        check(parsed.owner == "456", "Share owner is not signed-in user's uk")
        check(parsed.files.count == 2, "Use embedded top-level share files")
        let modernHTML = #"<script id="locals-data" type="application/json">{"uk":999,"share_uk":"456","shareid":123,"file_list":[{"fs_id":101,"server_filename":"资源"}]}</script>"#
        let modern = BaiduSharePage.decode(modernHTML)
        check(modern.owner == "456" && modern.files.count == 1, "Parse current Baidu locals-data JSON")
        let initHTML = #"window.yunData={uk:'0',share_uk:"456",shareid:"123"};"#
        check(BaiduSharePage.decode(initHTML).shareID == "123", "Parse unquoted fields on extraction-code page")
        var verifiedCode = ""; var transferredIDs = ""; var sentKey = ""; var listed = false
        FixtureProtocol.rawHandler = { request in
            let path = request.url!.path
            var result: [String: Any] = ["errno": 0]
            switch path {
            case "/api/gettemplatevariable": result["result"] = ["bdstoken": "token"]
            case "/share/verify": verifiedCode = formBody(request)["pwd"] ?? ""; result["randsk"] = "key%2Bprotected%3D"
            case "/s/1fixture": return Data(html.utf8)
            case "/share/list": listed = true
            case "/api/create": result["errno"] = 4
            case "/share/transfer":
                let form = formBody(request); transferredIDs = form["fsidlist"] ?? ""; sentKey = form["sekey"] ?? ""
                result["extra"] = ["list": [["to_fs_id": 201], ["to_fs_id": 202]]]
            case "/share/set":
                check(formBody(request)["fid_list"] == "[201,202]", "Baidu shares the saved identifiers")
                result["link"] = "https://pan.baidu.com/s/1fixture-new"
            default: preconditionFailure("Unexpected Baidu request " + path)
            }
            return try JSONSerialization.data(withJSONObject: result)
        }
        let protectedBaidu = ShareText.parse("https://pan.baidu.com/s/1fixture?pwd=igfg")[0]
        _ = try await driver(.baidu).transfer(protectedBaidu) { _ in }
        check(verifiedCode == "igfg", "Preserve original four-character extraction code")
        check(transferredIDs == "[101,102]", "Transfer every top-level file")
        check(sentKey == "key+protected=", "Pass once-decoded sekey through form encoding")
        check(!listed, "Avoid redundant share/list for embedded first page")
        FixtureProtocol.rawHandler = nil
        FixtureProtocol.status = 400
        FixtureProtocol.handler = { _ in ["error": "captcha_invalid", "error_description": "verification expired"] }
        let http = driver(.xunlei).http
        do { _ = try await http.json("https://api-pan.xunlei.com/drive/v1/share"); preconditionFailure("Expected HTTP error") }
        catch { check(error.localizedDescription.contains("verification expired"), "Keep actual HTTP error detail") }
        http.close(); FixtureProtocol.status = 200
        print("PASS: \(checks) provider fixture checks; no real accounts or network")
    }
}

