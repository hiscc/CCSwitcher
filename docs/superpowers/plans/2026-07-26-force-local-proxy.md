# CCSwitcher Force-Local-Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every CCSwitcher-owned HTTP(S) request through `127.0.0.1:7890` and fail closed when that local proxy is unavailable.

**Architecture:** Add one `PinnedProxySession` factory that constructs an ephemeral `URLSession` with explicit HTTP and HTTPS proxy entries. Inject that single session into `ClaudeService` and `UpdateChecker`; all existing retries reuse it, and no production request uses `URLSession.shared`.

**Tech Stack:** Swift 6, Foundation `URLSession`, CFNetwork proxy keys, XCTest, XcodeGen, Xcode 16/macOS 14.

---

## File map

- Create `CCSwitcher/Services/PinnedProxySession.swift`: the sole owner of proxy host, port, configuration, and shared session.
- Create `CCSwitcherTests/PinnedProxySessionTests.swift`: configuration and dead-proxy fail-closed tests.
- Modify `CCSwitcher/Services/ClaudeService.swift`: hold the pinned session and use it for all Anthropic/relay traffic.
- Modify `CCSwitcher/Services/UpdateChecker.swift`: hold the pinned session and use it for update checks/downloads.
- Modify `project.yml`: compile the session factory directly into the hostless unit-test target.
- Modify `CHANGELOG.md`: document the fail-closed routing behavior.

### Task 1: Specify and implement the pinned proxy session

**Files:**
- Create: `CCSwitcherTests/PinnedProxySessionTests.swift`
- Create: `CCSwitcher/Services/PinnedProxySession.swift`
- Modify: `project.yml`

- [ ] **Step 1: Write the failing configuration tests**

Create `CCSwitcherTests/PinnedProxySessionTests.swift`:

```swift
import XCTest
import Foundation
import CFNetwork

final class PinnedProxySessionTests: XCTestCase {
    func testConfigurationPinsHTTPToLocalMixedPort() {
        let proxies = PinnedProxySession.makeConfiguration().connectionProxyDictionary

        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPEnable as String] as? Bool, true)
        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPPort as String] as? Int, 7890)
    }

    func testConfigurationPinsHTTPSToLocalMixedPort() {
        let proxies = PinnedProxySession.makeConfiguration().connectionProxyDictionary

        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPSEnable as String] as? Bool, true)
        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPSProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(proxies?[kCFNetworkProxiesHTTPSPort as String] as? Int, 7890)
    }

    func testUnavailableProxyDoesNotFallBackToDirect() async {
        let configuration = PinnedProxySession.makeConfiguration(port: 1)
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await session.data(from: URL(string: "https://example.com/")!)
            XCTFail("Request unexpectedly succeeded without the required local proxy")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }
}
```

- [ ] **Step 2: Regenerate the project and verify RED**

Run:

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: test compilation fails because `PinnedProxySession` does not exist. Confirm port 1 has no listener before relying on the dead-proxy test:

```bash
lsof -nP -iTCP:1 -sTCP:LISTEN
```

Expected: no output.

- [ ] **Step 3: Implement the minimal session factory**

Create `CCSwitcher/Services/PinnedProxySession.swift`:

```swift
import Foundation
import CFNetwork

enum PinnedProxySession {
    static let host = "127.0.0.1"
    static let port = 7890

    static let shared = URLSession(configuration: makeConfiguration())

    static func makeConfiguration(
        host: String = PinnedProxySession.host,
        port: Int = PinnedProxySession.port
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
        return configuration
    }
}
```

Add the factory to the `CCSwitcherTests` source list in `project.yml`, after `FileLogger.swift`:

```yaml
      - path: CCSwitcher/Services/PinnedProxySession.swift
```

- [ ] **Step 4: Verify GREEN**

Run the same `xcodegen generate` and `xcodebuild test` commands. Expected: all tests pass, including the dead-proxy test.

- [ ] **Step 5: Commit the tested factory**

```bash
git add CCSwitcher/Services/PinnedProxySession.swift CCSwitcherTests/PinnedProxySessionTests.swift project.yml CCSwitcher.xcodeproj/project.pbxproj
git commit -m "feat: add fail-closed local proxy session"
```

### Task 2: Route every CCSwitcher request through the pinned session

**Files:**
- Modify: `CCSwitcher/Services/ClaudeService.swift`
- Modify: `CCSwitcher/Services/UpdateChecker.swift`

- [ ] **Step 1: Establish the pre-change routing failure**

Run:

```bash
rg -n 'URLSession\.shared' CCSwitcher --glob '*.swift'
```

Expected: seven matches—five in `ClaudeService.swift` and two in `UpdateChecker.swift`. This is the failing acceptance check.

- [ ] **Step 2: Inject the pinned session into `ClaudeService`**

Replace its singleton/initializer block with:

```swift
final class ClaudeService: @unchecked Sendable {
    static let shared = ClaudeService()

    private let session: URLSession

    private init(session: URLSession = PinnedProxySession.shared) {
        self.session = session
    }
```

Replace every occurrence of:

```swift
URLSession.shared.data(for: request)
```

and the profile request occurrence with the equivalent instance call:

```swift
session.data(for: request)
session.data(for: profileReq)
```

The five affected operations are usage lookup, Token refresh, relay test, OAuth code exchange, and profile lookup.

- [ ] **Step 3: Inject the pinned session into `UpdateChecker`**

Add below its published properties:

```swift
    private let session: URLSession

    init(session: URLSession = PinnedProxySession.shared) {
        self.session = session
    }
```

Replace the update-check request with:

```swift
let (data, response) = try await session.data(for: request)
```

Replace the DMG download with:

```swift
let (tempURL, response) = try await session.download(from: url)
```

- [ ] **Step 4: Verify the routing acceptance check turns GREEN**

Run:

```bash
rg -n 'URLSession\.shared' CCSwitcher --glob '*.swift'
```

Expected: exit status 1 and no output. Then run the full test suite and build:

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: tests and build succeed without Swift concurrency errors.

- [ ] **Step 5: Commit the wiring**

```bash
git add CCSwitcher/Services/ClaudeService.swift CCSwitcher/Services/UpdateChecker.swift CCSwitcher.xcodeproj/project.pbxproj
git commit -m "fix: require local proxy for all app requests"
```

### Task 3: Document and independently verify the security behavior

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the changelog entry**

Under `## Unreleased (current working changes)`, add:

```markdown
### security: 所有应用内 HTTP(S) 请求强制走 127.0.0.1:7890
- 新增统一 `PinnedProxySession`，用量查询、OAuth/Token 刷新、账号资料、中转站测试、GitHub 更新检查和下载全部显式绑定 XPro mixed-port；不再依赖会随代理退出而消失的 macOS 系统代理状态
- 本地 7890 不可用时请求报错或超时，不创建默认 `URLSession` 重试、不回退 DIRECT；新增 HTTP/HTTPS 代理字典和 dead-port 回归测试
```

- [ ] **Step 2: Run final verification**

Run:

```bash
xcodegen generate
xcodebuild test -project CCSwitcher.xcodeproj -scheme CCSwitcher -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
rg -n 'URLSession\.shared' CCSwitcher --glob '*.swift'
rg -n '127\.0\.0\.1|7890|kCFNetworkProxiesHTTP' CCSwitcher/Services/PinnedProxySession.swift CCSwitcherTests/PinnedProxySessionTests.swift
```

Expected: tests/build succeed; the first `rg` has no output; the second shows the fixed proxy and both protocol configurations.

Recheck Claude Code processes without printing credentials: confirm uppercase/lowercase proxy variables resolve to local port 7890 and `NO_PROXY` contains neither Anthropic nor Claude. No dotfile changes are part of this task.

- [ ] **Step 3: Inspect the final diff and commit documentation**

```bash
git diff --check
git diff --stat HEAD~2
git status --short
git add CHANGELOG.md
git commit -m "docs: record fail-closed proxy routing"
```

Expected: no whitespace errors; only this feature's files plus the pre-existing untracked `ISSUES_TODO.md` appear. Do not stage `ISSUES_TODO.md`.
