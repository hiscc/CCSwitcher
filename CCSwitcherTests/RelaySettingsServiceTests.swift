import XCTest

final class RelaySettingsServiceTests: XCTestCase {
    private var tempPath: String!
    private var svc: RelaySettingsService!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "ccswitcher-tests-\(UUID().uuidString)-settings.json"
        svc = RelaySettingsService(settingsPath: tempPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempPath)
        super.tearDown()
    }

    private func seed(_ json: String) {
        try! Data(json.utf8).write(to: URL(fileURLWithPath: tempPath))
    }

    private func fileJSON() -> [String: Any] {
        let data = FileManager.default.contents(atPath: tempPath)!
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testReadReturnsNilWhenFileMissing() {
        XCTAssertNil(svc.readRelayEnv())
    }

    func testReadReturnsNilWhenOnlyOneKeyPresent() {
        seed(#"{"env":{"ANTHROPIC_BASE_URL":"https://r.example"}}"#)
        XCTAssertNil(svc.readRelayEnv())
    }

    func testWriteThenReadRoundTrip() {
        seed(#"{"env":{"MCP_TIMEOUT":"300000"},"model":"opus"}"#)
        let relay = RelayEnv(baseURL: "https://r.example", token: "sk-abc")
        XCTAssertTrue(svc.writeRelayEnv(relay))
        XCTAssertEqual(svc.readRelayEnv(), relay)
    }

    func testWritePreservesUnrelatedKeys() {
        seed(#"{"env":{"MCP_TIMEOUT":"300000"},"model":"opus","permissions":{"allow":["Bash"]}}"#)
        _ = svc.writeRelayEnv(RelayEnv(baseURL: "https://r.example", token: "sk-abc"))
        let json = fileJSON()
        XCTAssertEqual(json["model"] as? String, "opus")
        let env = json["env"] as! [String: Any]
        XCTAssertEqual(env["MCP_TIMEOUT"] as? String, "300000")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "https://r.example")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "sk-abc")
        let perms = json["permissions"] as! [String: Any]
        XCTAssertEqual((perms["allow"] as? [String])?.first, "Bash")
    }

    func testWriteCreatesFileWhenMissing() {
        XCTAssertTrue(svc.writeRelayEnv(RelayEnv(baseURL: "https://r.example", token: "sk-abc")))
        XCTAssertEqual(svc.readRelayEnv()?.token, "sk-abc")
    }

    func testClearRemovesOnlyOurKeys() {
        seed(#"{"env":{"MCP_TIMEOUT":"300000","ANTHROPIC_BASE_URL":"https://r.example","ANTHROPIC_AUTH_TOKEN":"sk-abc"}}"#)
        XCTAssertTrue(svc.clearRelayEnv())
        XCTAssertNil(svc.readRelayEnv())
        let env = fileJSON()["env"] as! [String: Any]
        XCTAssertEqual(env["MCP_TIMEOUT"] as? String, "300000")
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
    }

    func testClearSucceedsWhenFileMissing() {
        XCTAssertTrue(svc.clearRelayEnv())
    }

    func testCorruptFileIsNotClobbered() {
        seed("this is not json")
        XCTAssertFalse(svc.writeRelayEnv(RelayEnv(baseURL: "https://r.example", token: "sk-abc")))
        let raw = String(data: FileManager.default.contents(atPath: tempPath)!, encoding: .utf8)
        XCTAssertEqual(raw, "this is not json")
    }

    func testSetRelayEnvNilClears() {
        seed(#"{"env":{"ANTHROPIC_BASE_URL":"https://r.example","ANTHROPIC_AUTH_TOKEN":"sk-abc"}}"#)
        XCTAssertTrue(svc.setRelayEnv(nil))
        XCTAssertNil(svc.readRelayEnv())
    }

    func testNormalizeBaseURL() {
        XCTAssertEqual(RelaySettingsService.normalizeBaseURL("https://api.xtokenmirror.com"), "https://api.xtokenmirror.com")
        XCTAssertEqual(RelaySettingsService.normalizeBaseURL("https://api.xtokenmirror.com/"), "https://api.xtokenmirror.com")
        XCTAssertEqual(RelaySettingsService.normalizeBaseURL("https://api.xtokenmirror.com/v1"), "https://api.xtokenmirror.com")
        XCTAssertEqual(RelaySettingsService.normalizeBaseURL("https://api.xtokenmirror.com/v1/"), "https://api.xtokenmirror.com")
        XCTAssertEqual(RelaySettingsService.normalizeBaseURL("  https://x.y/v1 "), "https://x.y")
        // 深路径保留（有的中转在子路径提供 Anthropic 协议）
        XCTAssertEqual(RelaySettingsService.normalizeBaseURL("https://open.bigmodel.cn/api/anthropic"), "https://open.bigmodel.cn/api/anthropic")
    }
}
