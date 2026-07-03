# 中转站账号（Relay）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 CCSwitcher 中新增中转站账号：用户输入 名称 + baseURL + token，即可与官方 OAuth 账号在同一列表中互相切换，切到中转站时 cc 走 `~/.claude/settings.json` env 注入。

**Architecture:** 互斥式切换——OS 层任意时刻只表达一个身份。切到中转站 = 写 settings.json env 两键（`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`）+ 清 keychain token 与 `~/.claude.json` oauthAccount；切回官方 = 反向。vault（keychain 中的 backups store）仍是唯一身份真相源，`AccountBackup` 增加可选 `relay` 字段向后兼容。详见 spec：`docs/superpowers/specs/2026-07-03-relay-accounts-design.md`。

**Tech Stack:** Swift 6 / SwiftUI（macOS 14+）、xcodegen 2.45.4、XCTest（新建 test target，纯逻辑测试、不挂 TEST_HOST、不碰真实 keychain）。

**关键背景（实测已验证，2026-07-03）：**
- xtoken（`https://api.xtokenmirror.com`）原生支持 `POST {base}/v1/messages`，Bearer / x-api-key 均可，`claude-opus-4-8` 可用。
- env 两键存在时 `claude -p` 只走中转站（假 token → 401，不回落 OAuth）。
- `--settings` 的 env 块注入与写 settings.json 等价，已验证生效。
- 用户真实 `~/.claude/settings.json` 含大量 hooks/permissions/plugins 配置——**读-改-写只动两键，解析失败绝不覆盖**。

**全局验证命令：**
```bash
cd /Users/cchis/Desktop/openrouter/CCSwitcher
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -quiet   # 单测
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug build -quiet            # 只编译
```

---

### Task 1: 测试基建（新建 test target + sanity test）

项目目前**没有任何测试 target**。新建纯逻辑测试 target：不依赖 app host（不设 TEST_HOST，避免启动菜单栏 app / 读真实 keychain），直接把被测源文件编入测试模块。

**Files:**
- Modify: `project.yml`
- Create: `CCSwitcherTests/SanityTests.swift`

- [ ] **Step 1: project.yml 增加 test target 与 scheme**

`project.yml` 全文替换为（在原 47 行基础上只新增 `CCSwitcherTests` target 和 `schemes` 块，其余逐字保留）：

```yaml
name: CCSwitcher
options:
  bundleIdPrefix: me.xueshi
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "16.0"
  generateEmptyDirectories: true

settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "14.0"
    ENABLE_HARDENED_RUNTIME: false
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "-"
    DEVELOPMENT_TEAM: ""
    SWIFT_STRICT_CONCURRENCY: targeted

targets:
  CCSwitcher:
    type: application
    platform: macOS
    sources:
      - path: CCSwitcher
    info:
      path: CCSwitcher/Info.plist
      properties:
        LSUIElement: true
        CFBundleDisplayName: $(PRODUCT_NAME)
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        CFBundleURLTypes:
          - CFBundleURLName: me.xueshi.ccswitcher
            CFBundleURLSchemes:
              - ccswitcher
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: me.xueshi.ccswitcher
        CODE_SIGN_ENTITLEMENTS: CCSwitcher/Resources/CCSwitcher.entitlements
        PRODUCT_NAME: CCSwitcher
        MARKETING_VERSION: "1.1.3"
        CURRENT_PROJECT_VERSION: "33"
        COMBINE_HIDPI_IMAGES: true
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"
    entitlements:
      path: CCSwitcher/Resources/CCSwitcher.entitlements

  CCSwitcherTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: CCSwitcherTests
      # 纯逻辑测试：被测文件直接编入测试模块（不 @testable import app、不挂 TEST_HOST）
      - path: CCSwitcher/Services/KeychainService.swift
      - path: CCSwitcher/Services/FileLogger.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: me.xueshi.ccswitcher.tests

schemes:
  CCSwitcher:
    build:
      targets:
        CCSwitcher: all
    test:
      targets:
        - CCSwitcherTests
```

- [ ] **Step 2: 创建 sanity test**

`CCSwitcherTests/SanityTests.swift`：

```swift
import XCTest

final class SanityTests: XCTestCase {
    func testHarnessRuns() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 3: 生成工程并跑测试**

```bash
cd /Users/cchis/Desktop/openrouter/CCSwitcher && xcodegen generate && \
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -quiet
```
Expected: `** TEST SUCCEEDED **`（1 个测试通过）。

- [ ] **Step 4: Commit**

```bash
git add project.yml CCSwitcherTests/SanityTests.swift
git commit -m "test: 新建 CCSwitcherTests 纯逻辑测试 target（无 TEST_HOST，不碰真实 keychain）"
```

---

### Task 2: RelayInfo + AccountBackup.relay（TDD）

vault 条目增加可选 relay 字段。旧条目（无该字段）解码为 nil = 官方账号，零迁移。

**Files:**
- Create: `CCSwitcherTests/AccountBackupTests.swift`
- Modify: `CCSwitcher/Services/KeychainService.swift:6-10`（AccountBackup 定义处）

- [ ] **Step 1: 写失败测试**

`CCSwitcherTests/AccountBackupTests.swift`：

```swift
import XCTest

final class AccountBackupTests: XCTestCase {
    func testDecodeLegacyBackupWithoutRelayField() throws {
        let json = #"{"token":"tok-json","oauthAccount":{"emailAddress":"a@b.c"}}"#
        let backup = try JSONDecoder().decode(AccountBackup.self, from: Data(json.utf8))
        XCTAssertEqual(backup.token, "tok-json")
        XCTAssertNil(backup.relay)
        XCTAssertEqual(backup.oauthAccount["emailAddress"]?.value as? String, "a@b.c")
    }

    func testRelayBackupRoundTrip() throws {
        let original = AccountBackup(
            token: "sk-relay-token",
            oauthAccount: [:],
            relay: RelayInfo(name: "xtoken 0.18", baseURL: "https://api.xtokenmirror.com")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AccountBackup.self, from: data)
        XCTAssertEqual(decoded.token, "sk-relay-token")
        XCTAssertEqual(decoded.relay, RelayInfo(name: "xtoken 0.18", baseURL: "https://api.xtokenmirror.com"))
    }

    func testMixedStoreDecodes() throws {
        let json = #"""
        {"A":{"token":"t1","oauthAccount":{"emailAddress":"a@b.c"}},
         "B":{"token":"sk-x","oauthAccount":{},"relay":{"name":"n","baseURL":"https://r.example"}}}
        """#
        let store = try JSONDecoder().decode([String: AccountBackup].self, from: Data(json.utf8))
        XCTAssertNil(store["A"]?.relay)
        XCTAssertEqual(store["B"]?.relay?.baseURL, "https://r.example")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodegen generate && xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -quiet
```
Expected: **编译失败**——`cannot find 'RelayInfo' in scope` / `AccountBackup` 无 `relay` 成员。

- [ ] **Step 3: 实现**

`CCSwitcher/Services/KeychainService.swift`，把现有：

```swift
/// Per-account backup: keychain token + oauthAccount from ~/.claude.json
struct AccountBackup: Codable {
    let token: String
    let oauthAccount: [String: AnyCodable]
}
```

替换为：

```swift
/// Relay-station identity stored alongside the token in a vault entry.
/// nil on a backup = official OAuth account (legacy entries decode as nil — no migration).
struct RelayInfo: Codable, Equatable {
    let name: String
    let baseURL: String
}

/// Per-account backup: keychain token + oauthAccount from ~/.claude.json.
/// Relay entries reuse `token` for the relay API key and carry empty oauthAccount.
struct AccountBackup: Codable {
    let token: String
    let oauthAccount: [String: AnyCodable]
    var relay: RelayInfo? = nil
}
```

（`var relay: RelayInfo? = nil` 让 memberwise init 带默认值，现有 `AccountBackup(token:oauthAccount:)` 调用点不需改动。）

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 命令。Expected: `** TEST SUCCEEDED **`（4 个测试）。

- [ ] **Step 5: Commit**

```bash
git add CCSwitcherTests/AccountBackupTests.swift CCSwitcher/Services/KeychainService.swift
git commit -m "feat: AccountBackup 增加可选 relay 字段（旧条目解码为 nil，零迁移）"
```

---

### Task 3: RelaySettingsService（settings.json env 读改写，TDD）

新服务独占 `~/.claude/settings.json` 里两个 env 键的读改写。核心安全约束：**其余键原样透传；文件解析失败绝不覆盖**。

**Files:**
- Create: `CCSwitcher/Services/RelaySettingsService.swift`
- Create: `CCSwitcherTests/RelaySettingsServiceTests.swift`
- Modify: `project.yml`（test target sources 增加新文件）

- [ ] **Step 1: 写失败测试**

`CCSwitcherTests/RelaySettingsServiceTests.swift`：

```swift
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
```

- [ ] **Step 2: project.yml test target sources 增加新文件**

`CCSwitcherTests` target 的 sources 加一行（放在 KeychainService.swift 之前）：

```yaml
      - path: CCSwitcher/Services/RelaySettingsService.swift
```

- [ ] **Step 3: 创建空实现文件跑测试确认失败**

先只建含类型骨架的文件会让编译通过但断言失败的路径更曲折——直接写完整实现前，先跑一次确认现状失败即可：

```bash
xcodegen generate && xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -quiet
```
Expected: **编译失败**——`cannot find 'RelaySettingsService' in scope`（文件还不存在时 xcodegen 会报 path 不存在，先创建 Step 4 的文件再跑也可，此时失败形态为断言/编译错误均算确认）。

- [ ] **Step 4: 实现**

`CCSwitcher/Services/RelaySettingsService.swift`：

```swift
import Foundation

private let log = FileLog("RelaySettings")

/// The two env keys that point the Claude CLI at a relay station.
/// Present-together = relay active; absent = official OAuth account active.
struct RelayEnv: Equatable {
    let baseURL: String
    let token: String
}

/// Owns the relay env keys (ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN) inside
/// ~/.claude/settings.json. Strictly read-modify-write: every other key in the
/// file (hooks, permissions, plugins, ...) passes through untouched. A file we
/// can't parse is NEVER overwritten — it holds the user's whole CC setup.
final class RelaySettingsService: Sendable {
    static let shared = RelaySettingsService()

    private static let baseURLKey = "ANTHROPIC_BASE_URL"
    private static let authTokenKey = "ANTHROPIC_AUTH_TOKEN"

    private let settingsPath: String

    init(settingsPath: String = NSHomeDirectory() + "/.claude/settings.json") {
        self.settingsPath = settingsPath
    }

    /// Both keys present and non-empty → RelayEnv. Anything less → nil.
    func readRelayEnv() -> RelayEnv? {
        guard let json = readSettings(),
              let env = json["env"]?.value as? [String: AnyCodable],
              let base = env[Self.baseURLKey]?.value as? String,
              let token = env[Self.authTokenKey]?.value as? String,
              !base.isEmpty, !token.isEmpty else {
            return nil
        }
        return RelayEnv(baseURL: base, token: token)
    }

    func writeRelayEnv(_ relay: RelayEnv) -> Bool {
        mutateEnv { env in
            env[Self.baseURLKey] = AnyCodable(relay.baseURL)
            env[Self.authTokenKey] = AnyCodable(relay.token)
        }
    }

    func clearRelayEnv() -> Bool {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return true }
        return mutateEnv { env in
            env.removeValue(forKey: Self.baseURLKey)
            env.removeValue(forKey: Self.authTokenKey)
        }
    }

    /// Rollback helper: restore a previous snapshot (nil = keys were absent).
    func setRelayEnv(_ relay: RelayEnv?) -> Bool {
        if let relay { return writeRelayEnv(relay) }
        return clearRelayEnv()
    }

    /// Trim whitespace, trailing "/" and a trailing "/v1" (users paste OpenAI-style
    /// bases; the CLI appends /v1/messages itself). Deeper paths are preserved.
    static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/v1") {
            s.removeLast(3)
            while s.hasSuffix("/") { s.removeLast() }
        }
        return s
    }

    // MARK: - Private

    private func readSettings() -> [String: AnyCodable]? {
        guard let data = FileManager.default.contents(atPath: settingsPath) else { return nil }
        return try? JSONDecoder().decode([String: AnyCodable].self, from: data)
    }

    private func mutateEnv(_ mutate: (inout [String: AnyCodable]) -> Void) -> Bool {
        var json: [String: AnyCodable]
        if FileManager.default.fileExists(atPath: settingsPath) {
            guard let parsed = readSettings() else {
                log.error("[mutateEnv] \(settingsPath) exists but is not parseable JSON — refusing to overwrite")
                return false
            }
            json = parsed
        } else {
            json = [:]
        }

        var env = (json["env"]?.value as? [String: AnyCodable]) ?? [:]
        mutate(&env)
        json["env"] = AnyCodable(env)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(json)
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            log.info("[mutateEnv] Wrote \(settingsPath)")
            return true
        } catch {
            log.error("[mutateEnv] Write failed: \(error.localizedDescription)")
            return false
        }
    }
}
```

（写入会经 JSONEncoder 重排键序/缩进——与现有 `writeOAuthAccount` 对 `~/.claude.json` 的行为一致，内容不丢，可接受。）

- [ ] **Step 5: 跑测试确认通过**

```bash
xcodegen generate && xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -quiet
```
Expected: `** TEST SUCCEEDED **`（15 个测试）。

- [ ] **Step 6: Commit**

```bash
git add CCSwitcher/Services/RelaySettingsService.swift CCSwitcherTests/RelaySettingsServiceTests.swift project.yml
git commit -m "feat: RelaySettingsService — settings.json env 两键读改写（保键透传/解析失败拒写）"
```

---

### Task 4: Account.baseURL + AuthStatus.relayEnv + getAuthStatus 短路 + keychain 槽位操作

**Files:**
- Modify: `CCSwitcher/Models/Account.swift`
- Modify: `CCSwitcher/Services/ClaudeService.swift:22-34`（getAuthStatus）
- Modify: `CCSwitcher/Services/KeychainService.swift`（新增 3 个方法）

⚠️ 本 task 的 keychain/claude.json 操作碰真实 OS 槽位，**不写单测**（单测删真 token 属于自毁），以编译 + Task 8 手工 E2E 验证。

- [ ] **Step 1: Account 增加 baseURL/isRelay**

`CCSwitcher/Models/Account.swift` 的 `Account` 改为：

```swift
struct Account: Identifiable, Codable, Hashable {
    let id: UUID
    var email: String
    var displayName: String
    var provider: AIProviderType
    var orgName: String?
    var subscriptionType: String?
    var isActive: Bool
    var lastUsed: Date?
    /// Relay station base URL. nil = official OAuth account.
    var baseURL: String?

    var isRelay: Bool { baseURL != nil }

    var obfuscatedEmail: String {
        return email
    }

    var obfuscatedDisplayName: String {
        return displayName
    }

    init(
        id: UUID = UUID(),
        email: String,
        displayName: String,
        provider: AIProviderType = .claudeCode,
        orgName: String? = nil,
        subscriptionType: String? = nil,
        isActive: Bool = false,
        lastUsed: Date? = nil,
        baseURL: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.provider = provider
        self.orgName = orgName
        self.subscriptionType = subscriptionType
        self.isActive = isActive
        self.lastUsed = lastUsed
        self.baseURL = baseURL
    }
}
```

同文件 `AuthStatus` 改为：

```swift
/// Auth state derived from the OS truth sources (keychain token + ~/.claude.json
/// oauthAccount + settings.json relay env).
struct AuthStatus {
    let loggedIn: Bool
    let email: String?
    let orgName: String?
    let subscriptionType: String?
    /// Relay env present in ~/.claude/settings.json. Non-nil = the CLI routes to
    /// the relay; OAuth slots are cleared on relay switch (mutual exclusion).
    var relayEnv: RelayEnv? = nil
}
```

（可选属性 + 默认值：UserDefaults 里旧 `Account` JSON 无 `baseURL` 键 → 解码为 nil；现有 `AuthStatus(loggedIn:email:orgName:subscriptionType:)` 调用点不需改动。）

- [ ] **Step 2: getAuthStatus 优先读 relay env**

`CCSwitcher/Services/ClaudeService.swift` 的 `getAuthStatus()` 函数体开头插入：

```swift
        // Relay env takes precedence: when both keys are present the CLI routes to
        // the relay (verified 2026-07-03: bogus token → 401, no OAuth fallback).
        if let relay = RelaySettingsService.shared.readRelayEnv() {
            log.info("[getAuthStatus] Relay env active: \(relay.baseURL)")
            return AuthStatus(loggedIn: false, email: nil, orgName: nil, subscriptionType: nil, relayEnv: relay)
        }
```

- [ ] **Step 3: KeychainService 新增槽位操作**

`CCSwitcher/Services/KeychainService.swift`，在 `writeClaudeToken` 之后加：

```swift
    /// Remove the CLI's token item. Returns true when the item is verifiably gone
    /// (delete of an already-absent item also counts as success).
    func deleteClaudeToken() -> Bool {
        _ = runSecurityStatus(args: [
            "delete-generic-password",
            "-s", claudeService,
            "-a", claudeAccount
        ])
        let gone = readClaudeToken() == nil
        log.info("[deleteClaudeToken] gone=\(gone)")
        return gone
    }
```

在 `writeOAuthAccount` 之后加：

```swift
    /// Remove oauthAccount from ~/.claude.json (relay active = no OAuth identity).
    func removeOAuthAccount() -> Bool {
        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              var json = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            log.error("[removeOAuthAccount] Failed to read \(claudeJsonPath)")
            return false
        }
        guard json["oauthAccount"] != nil else { return true }
        json.removeValue(forKey: "oauthAccount")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let newData = try encoder.encode(json)
            try newData.write(to: URL(fileURLWithPath: claudeJsonPath), options: .atomic)
            log.info("[removeOAuthAccount] Removed")
            return true
        } catch {
            log.error("[removeOAuthAccount] Failed: \(error.localizedDescription)")
            return false
        }
    }
```

在 `saveAccountBackup` 之后加：

```swift
    /// Store a relay entry in the vault (token = relay API key, no oauthAccount).
    func saveRelayBackup(token: String, relay: RelayInfo, forAccountId accountId: String) -> Bool {
        log.info("[saveRelayBackup] Saving \(relay.name) (\(relay.baseURL)) for \(accountId)")
        backupLock.lock()
        defer { backupLock.unlock() }
        var store = loadBackupStore()
        store[accountId] = AccountBackup(token: token, oauthAccount: [:], relay: relay)
        return saveBackupStore(store)
    }
```

- [ ] **Step 4: 编译 + 全量测试**

```bash
xcodegen generate && xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -quiet
```
Expected: `** TEST SUCCEEDED **`（既有 15 个测试仍全过；app target 编译通过）。

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Models/Account.swift CCSwitcher/Services/ClaudeService.swift CCSwitcher/Services/KeychainService.swift
git commit -m "feat: Account/AuthStatus 感知 relay + getAuthStatus 优先派生 relay env + keychain 槽位清除操作"
```

---

### Task 5: switchAccount 四象限重写 + testRelayConnection

**Files:**
- Modify: `CCSwitcher/Services/ClaudeService.swift:205-278`（switchAccount 整体替换）
- Modify: `CCSwitcher/Services/ClaudeService.swift:507-537`（ClaudeServiceError 加 case）

- [ ] **Step 1: ClaudeServiceError 增加 relay case**

enum 的 case 列表加：

```swift
    case relayEnvWriteFailed
```

`errorDescription` 的 switch 加：

```swift
        case .relayEnvWriteFailed:
            return "Failed to update relay keys in ~/.claude/settings.json"
```

- [ ] **Step 2: switchAccount 整体替换**

`from` 变为可选（active 为空时也允许切换——中转站语义下「env 键在但不认识」会派生出无 active 状态，必须能从该状态切出去）：

```swift
    func switchAccount(from currentAccount: Account?, to targetAccount: Account) async throws {
        let keychain = KeychainService.shared
        let relaySettings = RelaySettingsService.shared

        log.info("[switchAccount] Switching from \(currentAccount?.id.uuidString ?? "none") to \(targetAccount.id) (relay=\(targetAccount.isRelay))")

        // 1. Back up the current OFFICIAL account. Relay creds live only in the
        //    vault and never drift, so there is nothing to capture when leaving a relay.
        if let current = currentAccount, !current.isRelay {
            if let currentToken = keychain.readClaudeToken(),
               let currentOAuth = keychain.readOAuthAccount() {
                let email = (currentOAuth["emailAddress"]?.value as? String) ?? "?"
                if email == current.email {
                    let saved = keychain.saveAccountBackup(token: currentToken, oauthAccount: currentOAuth, forAccountId: current.id.uuidString)
                    log.info("[switchAccount] Step 1: Backup saved: \(saved)")
                } else {
                    log.warning("[switchAccount] Step 1: oauthAccount email (\(email)) != source (\(current.email)), skipping backup")
                }
            } else {
                log.warning("[switchAccount] Step 1: Could not read current token or oauthAccount")
            }
        }

        // 2. Retrieve target account's backup
        guard let targetBackup = keychain.getAccountBackup(forAccountId: targetAccount.id.uuidString) else {
            log.error("[switchAccount] Step 2: No backup found for target account!")
            throw ClaudeServiceError.noTokenForAccount(targetAccount.id.uuidString)
        }

        // 3. Snapshot ALL THREE slots for rollback (keychain token, oauthAccount, relay env)
        let rollbackToken = keychain.readClaudeToken()
        let rollbackOAuth = keychain.readOAuthAccount()
        let rollbackRelay = relaySettings.readRelayEnv()

        func rollback() {
            log.warning("[switchAccount] Rolling back all slots...")
            if let rollbackToken { _ = keychain.writeClaudeToken(rollbackToken) } else { _ = keychain.deleteClaudeToken() }
            if let rollbackOAuth { _ = keychain.writeOAuthAccount(rollbackOAuth) } else { _ = keychain.removeOAuthAccount() }
            _ = relaySettings.setRelayEnv(rollbackRelay)
        }

        if let relayInfo = targetBackup.relay {
            // 4a. → Relay: env keys in, OAuth slots out (mutual exclusion — the OS
            // layer expresses exactly one identity at any moment).
            let target = RelayEnv(baseURL: relayInfo.baseURL, token: targetBackup.token)
            guard relaySettings.writeRelayEnv(target) else {
                rollback()
                throw ClaudeServiceError.relayEnvWriteFailed
            }
            _ = keychain.deleteClaudeToken()
            _ = keychain.removeOAuthAccount()

            guard relaySettings.readRelayEnv() == target, keychain.readClaudeToken() == nil else {
                rollback()
                throw ClaudeServiceError.switchVerificationFailed
            }
            log.info("[switchAccount] Relay switch verified: \(relayInfo.baseURL)")
        } else {
            // 4b. → Official: OAuth slots in, env keys out
            guard keychain.writeClaudeToken(targetBackup.token) else {
                log.error("[switchAccount] Failed to write token to keychain!")
                rollback()
                throw ClaudeServiceError.keychainWriteFailed
            }
            guard keychain.writeOAuthAccount(targetBackup.oauthAccount) else {
                log.error("[switchAccount] Failed to write oauthAccount!")
                rollback()
                throw ClaudeServiceError.oauthAccountWriteFailed
            }
            guard relaySettings.clearRelayEnv() else {
                log.error("[switchAccount] Failed to clear relay env keys!")
                rollback()
                throw ClaudeServiceError.relayEnvWriteFailed
            }

            // Verify by reading back the OS slots — rollback on any mismatch.
            let status = getAuthStatus()
            guard status.relayEnv == nil, status.loggedIn else {
                log.error("[switchAccount] Not logged in after switch — rolling back!")
                rollback()
                throw ClaudeServiceError.switchVerificationFailed
            }
            guard status.email == targetAccount.email else {
                log.error("[switchAccount] Logged in as \(status.email ?? "nil") instead of \(targetAccount.email) — rolling back!")
                rollback()
                throw ClaudeServiceError.switchWrongAccount(expected: targetAccount.email, actual: status.email ?? "unknown")
            }
            log.info("[switchAccount] Official switch verified — logged in as \(status.email ?? "")")
        }
    }
```

（`AppState.switchTo` 现在传的非可选 `currentActive` 自动适配 `Account?` 参数，编译不破。）

- [ ] **Step 3: 新增 testRelayConnection**

`ClaudeService.swift` 的 `// MARK: - Account Switching` 之前加：

```swift
    // MARK: - Relay Probe

    struct RelayTestResult {
        let ok: Bool
        let message: String
    }

    /// Probe {base}/v1/messages with a 1-token request. Verifies connectivity + auth.
    /// Does NOT verify tool-calling passthrough (which the CLI depends on) — some
    /// relay channels degrade forced tool calls; that only shows up in real use.
    func testRelayConnection(baseURL: String, token: String) async -> RelayTestResult {
        guard let url = URL(string: baseURL + "/v1/messages") else {
            return RelayTestResult(ok: false, message: "Invalid base URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": "claude-opus-4-8",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            log.info("[testRelay] \(baseURL) → HTTP \(code)")
            switch code {
            case 200:
                return RelayTestResult(ok: true, message: "Connected — token accepted")
            case 401, 403:
                return RelayTestResult(ok: false, message: "Token rejected (HTTP \(code))")
            case 404:
                return RelayTestResult(ok: false, message: "No /v1/messages at this base URL (HTTP 404)")
            default:
                return RelayTestResult(ok: false, message: "HTTP \(code): \(snippet)")
            }
        } catch {
            return RelayTestResult(ok: false, message: "Network error: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 4: 编译 + 全量测试**

```bash
xcodegen generate && xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -quiet
```
Expected: `** TEST SUCCEEDED **`。

- [ ] **Step 5: Commit**

```bash
git add CCSwitcher/Services/ClaudeService.swift
git commit -m "feat: switchAccount 支持中转站四象限切换（三槽位快照回滚）+ 中转连通性探测"
```

---

### Task 6: AppState 接线（reconcile / active 派生 / switchTo / 增删 / 用量跳过）

**Files:**
- Modify: `CCSwitcher/AppState.swift`

- [ ] **Step 1: 注入 relaySettings 服务**

`// MARK: - Services` 区块（`private let keychain = KeychainService.shared` 之后）加：

```swift
    private let relaySettings = RelaySettingsService.shared
```

- [ ] **Step 2: reconcileAccountsWithVault 增加 relay 分支**

`for (id, backup) in vaultIds {` 循环体开头（`let oauth = backup.oauthAccount` 之前）插入：

```swift
            if let relay = backup.relay {
                let host = URL(string: relay.baseURL)?.host ?? relay.baseURL
                if let idx = accounts.firstIndex(where: { $0.id == id }) {
                    accounts[idx].email = host
                    accounts[idx].displayName = relay.name
                    accounts[idx].orgName = nil
                    accounts[idx].subscriptionType = nil
                    accounts[idx].baseURL = relay.baseURL
                } else {
                    accounts.append(Account(
                        id: id,
                        email: host,
                        displayName: relay.name,
                        provider: .claudeCode,
                        orgName: nil,
                        subscriptionType: nil,
                        isActive: false,
                        lastUsed: nil,
                        baseURL: relay.baseURL
                    ))
                    log.info("[reconcile] Added relay \(relay.name) (id=\(id)) from vault")
                }
                continue
            }
```

- [ ] **Step 3: updateActiveAccount 优先匹配 relay env**

`updateActiveAccount(from:)` 函数体开头（`guard status.loggedIn` 之前）插入：

```swift
        // Relay env takes precedence: when the keys are present the CLI routes to
        // the relay regardless of the OAuth slots.
        if let relay = status.relayEnv {
            let vault = keychain.allBackups()
            if let match = accounts.first(where: { account in
                guard account.isRelay,
                      let backup = vault[account.id.uuidString],
                      let info = backup.relay else { return false }
                return info.baseURL == relay.baseURL && backup.token == relay.token
            }) {
                setActiveAccount(id: match.id)
                saveAccounts()
                log.info("[updateActiveAccount] Relay env matches \(match.displayName)")
            } else {
                // Same precedent as "logged-in account we don't manage": don't lie.
                log.info("[updateActiveAccount] Relay env present but unmanaged (\(relay.baseURL)) — clearing active state")
                setActiveAccount(id: nil)
                saveAccounts()
            }
            return
        }
```

- [ ] **Step 4: switchTo 放宽 guard + relay 跳过 email/过期检查**

`switchTo(_:)` 从函数头到 `isLoading = true` 之前整体替换为：

```swift
    func switchTo(_ account: Account) async {
        guard activeAccount?.id != account.id else {
            log.info("[switchTo] No switch needed (already active)")
            return
        }
        // May be nil (e.g. unmanaged relay env / external logout) — switching out of
        // a no-active state must still work.
        let currentActive = activeAccount

        log.info("[switchTo] ===== Switching from \(currentActive?.email ?? "none") to \(account.email) =====")

        // Pre-switch: verify target has a backup
        guard let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString) else {
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = account.isRelay
                ? "No stored token for \(account.displayName). Remove and re-add the relay."
                : "No stored credentials for \(account.email). Use re-authenticate to fix."
            return
        }

        if !account.isRelay {
            // Official-only checks: relay tokens are opaque API keys — no email
            // identity to compare, no expiry JSON to parse, nothing to refresh.
            let backupEmail = (backup.oauthAccount["emailAddress"]?.value as? String) ?? ""
            if !backupEmail.isEmpty && backupEmail != account.email {
                log.error("[switchTo] ABORT: backup email (\(backupEmail)) != target (\(account.email)) — corrupted backup, needs re-auth")
                errorMessage = "Stored credentials belong to \(backupEmail), not \(account.email). Sign in again to fix."
                startReauthenticate(account)
                return
            }

            if ClaudeService.isTokenExpired(backup.token) {
                log.warning("[switchTo] Target token expired for \(account.email), attempting auto-refresh...")
                if let refreshedJSON = await claudeService.refreshAccessToken(tokenJSON: backup.token) {
                    log.info("[switchTo] Token refreshed for \(account.email), updating backup and proceeding")
                    keychain.saveAccountBackup(
                        token: refreshedJSON,
                        oauthAccount: backup.oauthAccount,
                        forAccountId: account.id.uuidString
                    )
                } else {
                    log.warning("[switchTo] Auto-refresh failed for \(account.email), falling back to re-auth")
                    errorMessage = "Token expired for \(account.email). Sign in again to continue."
                    startReauthenticate(account)
                    return
                }
            }
        }
```

（`isLoading = true` 起的后半段不变——`try await claudeService.switchAccount(from: currentActive, to: account)` 中 `currentActive` 已是可选，直接匹配新签名。）

- [ ] **Step 5: addRelayAccount + testRelay**

`addAccount()` 之后加：

```swift
    /// Add a relay-station account (baseURL + API token). Returns true on success.
    @discardableResult
    func addRelayAccount(name: String, baseURL: String, token: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = RelaySettingsService.normalizeBaseURL(baseURL)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else { errorMessage = "Relay name is required"; return false }
        guard normalized.hasPrefix("https://") || normalized.hasPrefix("http://") else {
            errorMessage = "Base URL must start with http(s)://"
            return false
        }
        guard !trimmedToken.isEmpty else { errorMessage = "Token is required"; return false }

        // Same base + same token = duplicate. Same base + different token is fine
        // (one station, multiple channels — e.g. xtoken's five claude channels).
        let vault = keychain.allBackups()
        if accounts.contains(where: { acc in
            acc.isRelay && acc.baseURL == normalized && vault[acc.id.uuidString]?.token == trimmedToken
        }) {
            errorMessage = "This relay token is already added"
            return false
        }

        let host = URL(string: normalized)?.host ?? normalized
        let account = Account(
            email: host,
            displayName: trimmedName,
            provider: .claudeCode,
            orgName: nil,
            subscriptionType: nil,
            isActive: false,
            baseURL: normalized
        )
        guard keychain.saveRelayBackup(
            token: trimmedToken,
            relay: RelayInfo(name: trimmedName, baseURL: normalized),
            forAccountId: account.id.uuidString
        ) else {
            errorMessage = "Could not save relay credentials"
            return false
        }
        accounts.append(account)
        saveAccounts()
        errorMessage = nil
        log.info("[addRelay] Added \(trimmedName) (\(normalized)). Total: \(self.accounts.count)")
        return true
    }

    /// Probe a relay before saving. Returns a user-facing result line.
    func testRelay(baseURL: String, token: String) async -> String {
        let normalized = RelaySettingsService.normalizeBaseURL(baseURL)
        let result = await claudeService.testRelayConnection(
            baseURL: normalized,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return (result.ok ? "✓ " : "✗ ") + result.message
    }
```

- [ ] **Step 6: removeAccount 的 relay 收尾**

`removeAccount(_:)` 中现有的 `if account.isActive, let target = ...` 块整体替换为：

```swift
        if account.isActive, let target = accounts.first(where: { $0.id != account.id }) {
            log.info("[removeAccount] Active account being removed; switching OS slot to \(target.email) first")
            await switchTo(target)
            // Verify the OS slot actually moved by reading the matching truth source.
            let moved: Bool
            if target.isRelay {
                moved = relaySettings.readRelayEnv()?.baseURL == target.baseURL
            } else {
                let liveEmail = (keychain.readOAuthAccount()?["emailAddress"]?.value as? String) ?? ""
                moved = liveEmail == target.email
            }
            if !moved {
                log.error("[removeAccount] OS slot did not move to \(target.email); aborting deletion to keep state consistent")
                return
            }
        } else if account.isActive, account.isRelay {
            // Removing the last remaining account while it's an active relay: clear
            // the env keys so the CLI doesn't keep routing to deleted credentials.
            _ = relaySettings.clearRelayEnv()
        }
```

- [ ] **Step 7: 用量抓取跳过 relay**

`fetchAllAccountUsage()` 的快照行：

```swift
        let snapshot = accounts
```
改为：
```swift
        let snapshot = accounts.filter { !$0.isRelay }   // relays have no usage API
```

`diagnoseTokenHealth()` 的循环行：

```swift
        for account in accounts {
```
改为：
```swift
        for account in accounts where !account.isRelay {
```

（auto-switch 无需改动：relay 无 `usage` 条目 → `resolveSessionUtilization` 返回 nil → 候选自动排除；active 是 relay 时 utilization 视为 0，永不触发切出。）

- [ ] **Step 8: 编译 + 全量测试**

```bash
xcodegen generate && xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -quiet
```
Expected: `** TEST SUCCEEDED **`。

- [ ] **Step 9: Commit**

```bash
git add CCSwitcher/AppState.swift
git commit -m "feat: AppState 接线中转站——reconcile/active 派生/切换守卫/增删/用量跳过"
```

---

### Task 7: UI（添加中转站表单 + 列表/用量卡片区分显示）

**Files:**
- Modify: `CCSwitcher/Views/AccountSwitcherView.swift`
- Modify: `CCSwitcher/Views/UsageDashboardView.swift:204-264`

- [ ] **Step 1: AccountSwitcherView 增加状态**

现有 `@State` 之后加：

```swift
    @State private var showingAddRelay = false
    @State private var relayName = ""
    @State private var relayBaseURL = ""
    @State private var relayToken = ""
    @State private var relayTestResult: String?
    @State private var isTestingRelay = false
```

- [ ] **Step 2: accountRow 区分 relay**

图标行：
```swift
            Image(systemName: account.provider.iconName)
```
改为：
```swift
            Image(systemName: account.isRelay ? "network" : account.provider.iconName)
```

caption 行：
```swift
                    Text(account.provider.rawValue)
```
改为：
```swift
                    Text(account.isRelay ? "Relay" : account.provider.rawValue)
```

re-auth 按钮（`arrow.triangle.2.circlepath` 那个 Button 整体）包进条件——relay 无 OAuth 可刷：
```swift
            if !account.isRelay {
                Button {
                    appState.startReauthenticate(account)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Re-authenticate (fix stale token)")
            }
```

- [ ] **Step 3: addAccountButtons 增加 relay 表单分支**

`} else if showingAddConfirm {` 之前插入分支：

```swift
        } else if showingAddRelay {
            relayForm
```

最后的 else 分支（两个按钮的 VStack）末尾、`Add Current Account` 按钮之后加：

```swift
                Button {
                    withAnimation { showingAddRelay = true }
                } label: {
                    Label("Add Relay Station", systemImage: "network")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
```

- [ ] **Step 4: relayForm 实现**

`addAccountButtons` 之后加：

```swift
    private var relayForm: some View {
        VStack(spacing: 8) {
            Text("Add Relay Station")
                .font(.caption.weight(.medium))

            TextField("Name (e.g. xtoken claude0.18)", text: $relayName)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            TextField("Base URL (e.g. https://api.xtokenmirror.com)", text: $relayBaseURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            TextField("Token (sk-...)", text: $relayToken)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            if let result = relayTestResult {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    withAnimation { showingAddRelay = false }
                    clearRelayForm()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    isTestingRelay = true
                    relayTestResult = nil
                    Task {
                        relayTestResult = await appState.testRelay(baseURL: relayBaseURL, token: relayToken)
                        isTestingRelay = false
                    }
                } label: {
                    if isTestingRelay {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Test")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTestingRelay || relayBaseURL.isEmpty || relayToken.isEmpty)

                Button("Save") {
                    if appState.addRelayAccount(name: relayName, baseURL: relayBaseURL, token: relayToken) {
                        withAnimation { showingAddRelay = false }
                        clearRelayForm()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
                .controlSize(.small)
                .disabled(relayName.isEmpty || relayBaseURL.isEmpty || relayToken.isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.cardFillStrong)
                .strokeBorder(.cardBorderBrand, lineWidth: 1)
        )
    }

    private func clearRelayForm() {
        relayName = ""
        relayBaseURL = ""
        relayToken = ""
        relayTestResult = nil
    }
```

- [ ] **Step 5: UsageDashboardView relay 卡片**

`accountUsageCard(account:state:)` 的内容判定链首部插入 relay 分支：

```swift
            accountHeader(account)
            if account.isRelay {
                relayInfoRow
            } else if let usage = state?.usage {
```

（后续 `else if` 链不变。）`accountHeader(_:)` 的 `if let sub = account.subscriptionType` 之后加：

```swift
            if account.isRelay {
                Text("Relay")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.gray.opacity(0.15), in: Capsule())
            }
```

`accountHeader` 之后加：

```swift
    private var relayInfoRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "network")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Relay station — no usage data")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
```

- [ ] **Step 6: 编译 + 全量测试**

```bash
xcodegen generate && xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' -quiet
```
Expected: `** TEST SUCCEEDED **`。

- [ ] **Step 7: Commit**

```bash
git add CCSwitcher/Views/AccountSwitcherView.swift CCSwitcher/Views/UsageDashboardView.swift
git commit -m "feat: UI 支持中转站——添加表单（含测试连接）+ 列表/用量卡片区分显示"
```

---

### Task 8: 文档 + 版本号 + Release 部署 + 手工 E2E

**Files:**
- Modify: `CHANGELOG.md`（Unreleased 区块头部）
- Modify: `FUNCTIONAL_TESTS.md`（追加章节）
- Modify: `project.yml`（版本号）

- [ ] **Step 1: CHANGELOG.md**

`## Unreleased (current working changes)` 之下、现有第一个 `###` 之前插入：

```markdown
### feat: 中转站（Relay）账号——baseURL + token 即可让 cc 走 Anthropic 兼容中转
- 新增账号类型：名称 + baseURL + token 添加中转站，与官方 OAuth 账号同列表互切；「Test」按钮先探测 `{base}/v1/messages` 连通性与 token 有效性（自动剥用户误填的尾缀 `/v1`）
- 互斥式切换：切到中转站 = `~/.claude/settings.json` env 写 `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` 两键 + 清 keychain token 与 `~/.claude.json` oauthAccount；切回官方反向。OS 层任意时刻只表达一个身份，不依赖 cc 未文档化的 env/OAuth 优先级（机制已实测：env 在场时 `claude -p` 假 token 得 401，不回落 OAuth）
- settings.json 严格读-改-写：只动两键、其余键（hooks/permissions/plugins…）原样透传、解析失败拒绝写入；三槽位快照回滚
- vault `AccountBackup` 增加可选 `relay` 字段（旧条目解码为 nil，零迁移）；active 派生优先匹配 relay env，与「外部登录了不认识的账号」同先例处理不认识的 env
- 中转站不取用量（各站 API 非标）、不参与 auto-switch；用量页显示「Relay station — no usage data」
- 新建 `CCSwitcherTests` 纯逻辑测试 target（settings.json 读改写保键、AccountBackup 新旧格式、baseURL 归一化）
```

- [ ] **Step 2: FUNCTIONAL_TESTS.md 追加章节**

文件末尾追加（若章节号与现有内容冲突则顺延编号）：

```markdown
## 12. 中转站账号 (Relay)

- [ ] **TC-12.1** 添加中转站 + 测试连接
  - 前置条件：有可用中转站 baseURL + token（xtoken claude0.18/1.2/1.5 渠道）
  - 测试步骤：Accounts → Add Relay Station → 填名称/baseURL/token → Test → Save
  - 预期结果：Test 显示 `✓ Connected — token accepted`；保存后列表出现该条目（network 图标 + host 副标题 + Relay 标签）；baseURL 误填尾缀 `/v1` 时自动纠正

- [ ] **TC-12.2** 切换到中转站
  - 前置条件：TC-12.1 完成，当前 active 为官方账号
  - 测试步骤：点中转站条目的 Switch → 打开**新终端**跑 `claude -p "reply ok"` → 检查 `~/.claude/settings.json` 与 keychain
  - 预期结果：app 内该条目变 Active；settings.json env 出现两键且其余键（hooks/permissions 等）原样；`security find-generic-password -s "Claude Code-credentials" -w` 报 not found；`~/.claude.json` 无 oauthAccount；新终端 claude 正常出字（走中转站）

- [ ] **TC-12.3** 切回官方账号
  - 前置条件：TC-12.2 完成
  - 测试步骤：点官方账号 Switch → 新终端 `claude -p "reply ok"`
  - 预期结果：env 两键消失、keychain token 与 oauthAccount 恢复、用量数据恢复显示；新终端走官方

- [ ] **TC-12.4** 删除 active 中转站
  - 测试步骤：切到中转站后点其 trash 按钮
  - 预期结果：OS 槽位先切到其它账号（或最后一个账号时清空 env 两键）再删除；不残留指向已删 token 的 env

- [ ] **TC-12.5** 外部 env 不认识时不冒认
  - 测试步骤：手工在 settings.json env 写一对 app 不认识的 BASE_URL/AUTH_TOKEN → app refresh
  - 预期结果：active 显示为空（"No account connected"），不错认成任何已存账号；从该状态点任意账号 Switch 能正常切出
```

- [ ] **Step 3: 版本号**

`project.yml`：`MARKETING_VERSION: "1.1.3"` → `"1.2.0"`，`CURRENT_PROJECT_VERSION: "33"` → `"34"`。

- [ ] **Step 4: Release 构建 + 部署（CLAUDE.md 铁律：md5 双向校验）**

```bash
cd /Users/cchis/Desktop/openrouter/CCSwitcher
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Release build -quiet
BUILT=$(ls -d ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Release/CCSwitcher.app | head -1)
rm -rf /Applications/CCSwitcher.app
cp -R "$BUILT" /Applications/CCSwitcher.app
md5 -q "$BUILT/Contents/MacOS/CCSwitcher"
md5 -q /Applications/CCSwitcher.app/Contents/MacOS/CCSwitcher
```
Expected: 两个 md5 **完全一致**。然后清理：

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Release \
       ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Debug
ls ~/Desktop/*.app 2>/dev/null && rm -rf ~/Desktop/CCSwitcher.app || true
```

- [ ] **Step 5: 手工 E2E（按 FUNCTIONAL_TESTS §12 逐项过，需要用户参与）**

真实凭据：xtoken 配置在 `/Users/cchis/Documents/ship/bottle-api/app/service/api/skai-xtoken.js`（建议用 claude0.18 渠道试）。核心链路 = TC-12.1 → 12.2 → 12.3。

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md FUNCTIONAL_TESTS.md project.yml
git commit -m "docs: 中转站功能 CHANGELOG + 手工测试清单；版本号 1.2.0"
```

---

## Self-Review 备忘（已执行）

- **Spec 覆盖**：数据模型（Task 2/4）、settings.json 读改写（Task 3）、互斥切换+回滚（Task 5）、active 派生/不冒认（Task 6）、用量跳过+auto-switch 排除（Task 6）、UI+测试连接+URL 纠正（Task 3 normalize + Task 7）、手测清单（Task 8）——全部有对应 task。
- **类型一致性**：`RelayEnv{baseURL,token}`（Task 3 定义，4/5/6 使用）、`RelayInfo{name,baseURL}`（Task 2 定义，4/6 使用）、`switchAccount(from: Account?, to:)`（Task 5 定义，Task 6 调用点自动适配）、`RelaySettingsService.normalizeBaseURL`（Task 3 定义，Task 6 调用）已核对。
- **已知取舍**：settings.json/claude.json 写入经 JSONEncoder 会重排键序（与现有 `writeOAuthAccount` 行为一致）；「测试连接」不验证 tool-calling 透传（xtoken claude0.6/1.0 渠道旧基准不透传 forced tool，建议用 0.18/1.2/1.5）。
