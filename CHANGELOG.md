# CCSwitcher Changelog

## Unreleased (current working changes)

### security: 所有应用内 HTTP(S) 请求强制走 127.0.0.1:7890
- 新增统一 `PinnedProxySession`，用量查询、OAuth/Token 刷新、账号资料、中转站测试、GitHub 更新检查和下载全部显式绑定 XPro mixed-port；不再依赖会随代理退出而消失的 macOS 系统代理状态
- 本地 7890 不可用时请求报错或超时，不创建默认 `URLSession` 重试、不回退 DIRECT；新增 HTTP/HTTPS 代理字典和 dead-port 回归测试

### feat: 中转站（Relay）账号——baseURL + token 即可让 cc 走 Anthropic 兼容中转
- 新增账号类型：名称 + baseURL + token 添加中转站，与官方 OAuth 账号同列表互切；「Test」按钮先探测 `{base}/v1/messages` 连通性与 token 有效性（校验 200 响应体为 Anthropic message、自动剥用户误填的尾缀 `/v1`）
- 互斥式切换：切到中转站 = `~/.claude/settings.json` env 写 `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` 两键 + 清 keychain token 与 `~/.claude.json` oauthAccount；切回官方反向。OS 层任意时刻只表达一个身份，不依赖 cc 未文档化的 env/OAuth 优先级（机制已实测：env 在场时 `claude -p` 假 token 得 401，不回落 OAuth）
- settings.json 严格读-改-写：只动两键、其余键（hooks/permissions/plugins…）原样透传（含 Bool/数字/null/嵌套结构保真回归测试）、解析失败或 env 非对象拒绝写入；三槽位快照回滚，回滚失败可见化（switchRollbackFailed）
- vault `AccountBackup` 增加可选 `relay` 字段（旧条目解码为 nil，零迁移）；saveAccountBackup/saveRelayBackup 双向拒绝跨类型覆写；active 派生优先匹配 relay env，不认识的 env 按「外部登录了不认识的账号」先例清 active 不冒认
- 中转站不取用量（各站 API 非标）、不参与 auto-switch；用量页显示「Relay station — no usage data」，全 relay 配置下卡片列表正常渲染
- switchTo 增加重入护栏（isLoading 期间手动切换忽略并提示；auto-switch 内部调用豁免）、active 为空时也可切换（此前 Switch 无效的隐性问题）
- 新建 `CCSwitcherTests` 纯逻辑测试 target（18 个测试：settings.json 读改写保键与保真、AccountBackup 新旧格式、baseURL 归一化边界）

### refactor: subscriptionType 改为从 vault 推导，消除最后一处双源
- `reconcileAccountsWithVault` 此前"保留"UserDefaults 里的 subscriptionType（注释称 vault 没有该字段——已过时：vault 的 token JSON 一直带 subscriptionType）。现在用 `extractSubscriptionType(backup.token)` 推导，vault 成为属主；仅当老 token JSON 缺字段时回退保留旧值
- 至此 UserDefaults 中只剩 `lastUsed` 一个非派生字段，其余全部由 vault/OS 槽位单向推导

### refactor: token 存取链路去冗余（零 fork 后的二次审计）
- **统一过期预检**：`fetchOneAccountUsage` 此前只对非 active 账号做本地过期预检，active 账号的过期 token 必先挨一次 401 才进恢复分支。现在 active/非 active 统一预检 + 主动刷新，省掉每轮保底 401
- **新增 `persistRefreshedToken(_:for:)`**：刷新后的 token 统一持久化——active → 写 OS keychain slot（CLI 直接受益，不再长期携带过期 accessToken）+ vault；非 active → 仅 vault。401 恢复路径的内联重复逻辑同步收编
- **删除 switchAccount Step 5 re-capture**：其存在理由是"CLI 可能在 auth status 验证期间内部刷新 token"——验证已不 fork CLI，Step 3 写入和函数结束之间无任何 keychain 变更可能，re-capture 变成读回自己刚写的数据再存一遍的空转
- **删除 `getAccountToken`**：无调用者的 legacy 函数
- **防误改注释**：`KeychainService` 中"OS slot 走 `security` CLI、vault 走 SecItem API"的不对称是**刻意设计**——keychain ACL 按触碰 item 的二进制授信，app 用 SecItemAdd/Update 重写 CLI 的 item 会导致 CLI 下次读 token 弹权限框。补注释防止未来被"统一"掉

### refactor: 彻底移除 CLI 进程依赖——app 不再 fork 任何 claude 子进程
- 原生 OAuth 落地后全面审查：`getAuthStatus` 仍在 fork `claude auth status`，但其输出只是 keychain token + `~/.claude.json` oauthAccount 的转述——app 本就直接读写这两处（真相源原则）。fork CLI = 为已拥有的信息引入 Bun 崩溃面 + ~600ms 延迟
- `getAuthStatus()` 改为同步直读 OS 真相源（keychain token 存在 + oauthAccount email → loggedIn；orgName 取自 oauthAccount；subscriptionType 取自 token JSON），不再 async/throws，三个调用点（performRefresh / addAccount / switchAccount Step 4 验证）同步简化，错误分支消失
- `switchAccount` Step 4 验证从「fork CLI 确认」改为「回读自己刚写的两个槽位」——CLI 的 auth status 读的就是这两处，fork 它验证不了更多东西
- 整体删除：`runClaude`（含 ProcessRef、双管道异步读取、取消处理）、`logout()`、`isClaudeAvailable()`、`cancelCurrentLogin`/`setLoginProcess`/`currentLoginProcess`、claudePath 发现逻辑（nvm/homebrew 路径扫描）、`@Published claudeAvailable`（无任何 View 消费）及其守卫
- `ClaudeServiceError` 删除 `.invalidOutput`/`.cliError`/`.processLaunchFailed`；`AuthStatus` 去掉 Codable 和 authMethod/apiProvider/orgId（CLI JSON 解码专用，无消费者）
- 架构终态：CCSwitcher = 文件读写（claude.json/vault）+ keychain（security CLI）+ HTTPS（oauth token/profile/usage）。Bun/CLI 的所有崩溃模式与 app 无关

### feat: 登录改为 app 原生 OAuth（PKCE + 粘贴授权码），彻底移除 CLI 子进程依赖
- 根因（结构性）：`claude auth login` 的 OAuth 流程要求 **CLI 子进程活到用户完成浏览器授权**（托管回调页把 code 转发回 CLI 的 localhost 监听端口）。在无 AVX 指令集的 CPU 上 Bun 随机崩溃（其自身启动即警告 strange crashes may occur），实测 app 内 spawn 的子进程 5 秒内 exit 1，code 无人接收 → keychain 永不更新 → 任何新账号都登不进。历史上的 "Login detected" 是 nil-token 比较假阳性
- 方案：app 自己跑完整 OAuth authorization-code + PKCE 流程，**Bun/CLI 彻底移出登录关键路径**：
  - `beginNativeOAuth()`：SecRandomCopyBytes 生成 PKCE verifier/challenge（CryptoKit SHA256）+ state，构造与 CLI 逐字段一致的授权 URL 并开浏览器
  - 用户授权后托管页显示 code（`code#state` 格式），粘贴进 app 新增的输入框
  - `completeNativeOAuth()`：校验 state 防串号 → POST `platform.claude.com/v1/oauth/token`（与 token refresh 同端点）换 token → GET `api.anthropic.com/api/oauth/profile` 拿身份/订阅 → 构造与 CLI 同构的 keychain token JSON（accessToken/refreshToken/expiresAt/scopes/subscriptionType/rateLimitTier）+ `~/.claude.json` oauthAccount → 双写
- AppState：`loginNewAccount`/`reauthenticateAccount`（CLI 轮询版）删除，改为 `startLoginNewAccount`/`startReauthenticate`（开浏览器）+ `submitAuthCode`（粘贴完成）三段式；switchTo 的两处自动 re-auth 降级路径同步迁移
- UI：`AccountSwitcherView` 的"Waiting for browser login..."盲等界面 → 授权码粘贴框 + Cancel / Reopen Page / Complete Login；失败保留 pending 状态可直接重贴重试
- 删除：`login(previousEmail:)` 轮询函数、`loginTimeout` 错误 case；新增 `invalidAuthCode`/`oauthExchangeFailed`/`profileFetchFailed`

### fix: runClaude 分离 stdout/stderr，修复 Bun 警告污染 JSON 导致登录/切换/刷新全失败
- 根因：`runClaude` 把 `process.standardError` 和 `standardOutput` 指向**同一个 Pipe**，stderr 被合并进 stdout。Claude CLI 跑在 Bun 上，在缺少 AVX 指令集的 CPU 上每次启动都向 stderr 打印 `warn: CPU lacks AVX support...`，这两行文本被拼到 `auth status` 的 JSON 前面，`JSONDecoder` 解析失败抛 "isn't in the correct format"
- 后果：`getAuthStatus()` 每次必抛错 → 登录轮询 60 次全失败 → "Login did not complete within 2 minutes"（但 keychain 里 OAuth 其实早已成功）；`switchAccount` Step 4 验证、`performRefresh`、`reauth` 同样被击穿
- 修复：stderr 改用独立 `errPipe`（同样的非阻塞 readabilityHandler 收集），成功时只返回干净 stdout；非 0 退出时才把 stderr 拼进错误信息用于诊断（保留 login 的 "Opening browser" 文本检测）
- 影响面：零行为语义改变，纯粹让输出不再被污染；一次修复同时恢复 login / switch / refresh / reauth

### refactor: 合并三个 usage dict 为 `UsageState` enum（架构第四步）
- 新增 `UsageState` enum（`.fresh` / `.stale` / `.rateLimited` / `.expired` / `.missing`）作为 per-account usage 的单一 model
- 删除 `@Published var accountUsage` / `accountUsageErrors` 两个 dict + `UsageErrorState` struct，合并为 `@Published var usage: [UUID: UsageState]`
- `cachedUsage` 降级为 internal `private var`（不 @Published，仅作 fetch fallback 来源 + 跨启动 warm-start，View 不再直接读它）
- `UsageState` 提供 reset-aware helpers `effectiveSessionUtilization()` / `effectiveWeeklyUtilization()`，取代 `CachedUsageEntry` 上的同名方法
- View 改动：
  - `CCSwitcherApp.menuBarLabel`：双 fallback 链 `accountUsage[id]?.fiveHour?.utilization ?? cachedUsage[id]?.effective...` 简化为 `usage[id]?.effectiveSessionUtilization()`
  - `UsageDashboardView`：`accountUsageCard(account:usage:)` → `accountUsageCard(account:state:)`；errorBanner 接受 String 而非 struct；sortedAccountsByUsage 单源排序
- `fetchOneAccountUsage` 直接返回 `UsageState`，不再用 三元组 `(usage, error, cacheEntry)`；`fetchAllAccountUsage` 在 `.fresh` 时才更新 cachedUsage
- 副作用：UI 层不再有"有 usage 但同时有 error"这种结构性撕裂态——状态在 enum 类型层面 mutually exclusive

### fix: runClaude 加 `withTaskCancellationHandler`（响应 Task 取消）
- 新增 `ProcessRef` class（`@unchecked Sendable`，NSLock 保护）跨 cancel-handler 边界共享 Process 引用
- `runClaude` 包装 `withTaskCancellationHandler { try await withCheckedThrowingContinuation { ... } } onCancel: { processRef.terminate() }`
- 之前只有 `cancelLogin` 路径手动 terminate child process；现在所有 runClaude 调用（getAuthStatus / logout / --version / login）的 Task 取消都会主动 terminate child，不再让 CLI 进程比 Swift Task 活得更久

### refactor: 删除 `repairCorruptedBackups` + 加 reconcile 漂移日志
- `repairCorruptedBackups` 在 vault-derived 架构下变成死代码：reconcile 已经把 `account.email` 改成跟 vault 一样，repair 的 `account.email != backup.oauthAccount.email` 比较永远不会触发。删除函数 + 删除 performRefresh 中的调用 + 删除冗余的第二次 reconcile 调用
- `reconcileAccountsWithVault` 在覆盖 email 字段前 log 漂移："email drift for X: UI had 'A', vault has 'B' — using vault"，让历史污染数据被覆盖时用户视角能从日志看到原因

### refactor: accounts 列表 derive from vault（架构层第三步）
- vault（keychain `me.xueshi.ccswitcher.backups`）正式成为账号身份字段（id/email/orgName）的真相源
- 新增 `KeychainService.allBackups()` 暴露整个 vault；新增 `AppState.reconcileAccountsWithVault()` 用 vault 重建 accounts：删孤儿、更新身份字段、补全 vault 里有但 accounts 里没有的条目
- `init()` 启动时立即 reconcile；`performRefresh()` 在 `getAuthStatus` **之前**和 `repairCorruptedBackups` **之后**各 reconcile 一次（前者让 updateActiveAccount 能匹配新加的 vault 条目，后者清理 repair 删掉的 backup 留下的孤儿）
- UserDefaults `com.ccswitcher.accounts` 现在只为持有 vault 没有的纯 UI 元数据（`lastUsed` / `subscriptionType`），不再是身份真相源
- 副作用：被 `repairCorruptedBackups` 删除 backup 的孤儿账号现在会从 UI 列表自动消失（之前会留下"无法点开"的死条目）

### refactor: usage state 整体 atomic replace（架构层第二步）
- `fetchAllAccountUsage` 不再逐账号 partial mutate `accountUsage` / `accountUsageErrors`，改为构造局部 `newUsage` / `newErrors` / `newCache` 字典，循环结束后整体赋值
- 拆出 `fetchOneAccountUsage(_:currentCache:) -> FetchResult` 纯函数，每个账号的结果（usage / error / cacheEntry）作为 struct 返回，主循环只负责组装
- 删除 `fallbackToCache(for:)` 反模式（其行为是「无 cache 时保留旧 stale 数据」，正是要消灭的源头），所有失败路径统一用 `currentCache[id]?.usage`——有 cache 用 cache，无 cache 写 nil
- 副作用：每轮 fetch 结束时三个 @Published dict 内容必然 = 本轮所有账号的最新结果，不可能再有 stale 残留；error 与 usage 同时更新到一致状态
- 注：三个 dict（`accountUsage` / `cachedUsage` / `accountUsageErrors`）的对外接口未变，View 不需要改；下一步可选合并为 `[UUID: UsageState]` enum，让 View 端读取更简洁

### refactor: active 状态单源（架构层第一步）
- 引入 `AppState.setActiveAccount(id:)` 作为 active 状态唯一写入路径，统一同步 `accounts[i].isActive` 与 `activeAccount` 引用，杜绝两者 diverge
- 替换 `addAccount` / `loginNewAccount` / `switchTo` / `reauthenticate` / `updateActiveAccount` / `removeAccount` 中所有手写的 `for i in accounts.indices { accounts[i].isActive = ... }` + `activeAccount = ...` 双写循环
- 此为「OS 层是唯一真相源、CCSwitcher 只是同步层」原则的渐进改造，下一步将合并 `accountUsage` / `cachedUsage` / `accountUsageErrors` 三 dict 为单一 `UsageState`

### fix: removeAccount switchTo 失败时 abort 删除（防 OS 层 rollback 后不一致）
- `ClaudeService.switchAccount` step 4 验证失败时会主动 rollback keychain 到原账号 token；若 `removeAccount` 在 switchTo 失败后继续清本地数据，会留下「OS 槽位指向已删除账号、本地无对应 backup」的死锁状态
- 现在 switchTo 失败时直接 return，保留账号让用户重试（通过比较 errorMessage 前后判断失败）

### fix: switchAccount step 5 re-capture 缺 expectedEmail 校验
- `ClaudeService.switchAccount:319` 在切换后 re-capture 凭据时未传 `expectedEmail`——这破坏了「keychain email 不匹配则拒绝写入 backup」的身份安全不变量
- 现传入 `targetAccount.email`，与流程里其他 capture 路径保持一致

### refactor: 修复 isLoggingIn 提前清空的 race window
- 旧代码在 `loginNewAccount` 和 `reauthenticateAccount` 末尾「`isLoggingIn = false; await refresh()`」——为了让 `refresh()` 内部 `guard !isLoggingIn` 不跳过，提前清空状态，但这开启了 await 期间其它 task 观察到 `isLoggingIn=false` 的 race window
- 拆 `refresh()` 为外层 guard + 内部 `performRefresh()`；login 流末尾直接调 `performRefresh()` 绕过 guard，不再需要提前清空 `isLoggingIn`，由 `defer` 统一管理

### chore: 清理 CCSwitcherApp 残留 dead state
- 删除随 promo timer 一起遗留的 `@State isDoubleUsageActive` 字段

### fix: removeAccount 移除 active 账号时 OS 槽位未真正切换
- 旧代码先把 `accounts[first].isActive = true` 和 `activeAccount = first` 提前赋值，再调 `switchTo(first)`——`switchTo` 内部 `currentActive.id != account.id` 判断 short-circuit，导致 keychain 里仍是被删账号的 token
- 修复：先 `await switchTo(target)` 切换 OS 槽位，再删 backup / accounts 数组 / 清 active 引用
- 顺手补上 `accountUsage.removeValue(forKey: account.id)`（之前漏清）

### security: 移除 Authorization header 入日志
- `ClaudeService.getUsageLimits` 不再 log `request.allHTTPHeaderFields`——之前会把完整 `Bearer sk-ant-oat01-...` 写到 `~/Library/Logs/CCSwitcher.log`，token 在有效期内可被任何能读该文件的进程冒用

### fix: login() polling 超时不再静默成功
- `login(previousEmail:)` polling 60 次（120s）后改为 `throw ClaudeServiceError.loginTimeout`，不再 warning + return 让调用方误以为登录成功并 capture 旧 credentials
- `loginNewAccount` / `reauthenticateAccount` 现在能正确感知超时并显示错误

### fix: 外部 `claude auth logout` 后 active 状态不响应
- `updateActiveAccount` 在 CLI `status.loggedIn=false` 或登录到非托管账号时，清空 active 状态（`setActiveAccount(id: nil)`）；之前直接 `return` 留下幻影 active 账号 + 过期 cached usage

### fix: fetchAllAccountUsage token 缺失时不再静默 continue
- 之前的 `continue` 路径既不写 error 状态、也不清 stale `accountUsage` 值，UI 看到的是上轮的旧数据但没任何提示；现在显式 fallback 到 cache + 写入 expired error
- 解决「某轮 fetch 失败但 UI 假装成功」的隐式 bug

### chore: 移除过期的 double-usage promo 死代码
- 删除 `CCSwitcherApp.checkDoubleUsage` 及其每分钟 timer——promo 时间硬编码为 2026-03-13 至 2026-03-29，已过期成死代码

### fix: 登录卡死「Waiting for browser login」+ Cancel 不真取消
- `runClaude` 的 pipe 读取从 `readDataToEndOfFile()` 改为 `readabilityHandler` 异步收集 — `claude auth login` 派生的 background helper 子进程会继承 stdout fd 不释放，导致 readDataToEndOfFile 永远等不到 EOF，UI 卡在 Waiting 即使 OAuth 已完成
- `waitUntilExit` 后立即 detach handler 并关闭读端，不再等待孙子进程持有的 pipe 写端关闭
- `cancelLogin` 现在真正调用 `process.terminate()` 杀掉 `claude auth login` 子进程，不再只是 cancel Swift Task（Task cancellation 无法打断阻塞的 syscall，导致重复点登录会堆积僵尸进程）
- `ClaudeService` 新增 `cancelCurrentLogin()` 接口，用 NSLock 保护 currentLoginProcess 引用

### fix: 切换验证失败时回滚 keychain，防止凭据级联污染
- `switchAccount` Step 4 验证失败（未登录或 email 不匹配）时，自动回滚 keychain 到切换前状态，不再留下脏数据
- `switchTo` 在切换前校验 backup email 是否匹配目标账号，发现不匹配时直接触发 re-auth 而非写入错误凭据
- `captureCurrentCredentials` 新增 `expectedEmail` 参数，keychain email 不匹配时拒绝保存，防止备份被污染
- `loginNewAccount` 和 `reauthenticateAccount` 备份当前账号时传入 expectedEmail 校验

### fix: Token refresh on re-login and account switch
- `login()` 不再因 CLI 非零退出码（如 "Opening browser to sign in..."）中断登录流程，仅在 binary 不存在时才抛异常
- `loginNewAccount` 已存在账号重新登录后，正确清除 expired 状态、标记 active、调用 `refresh()` 刷新用量
- `reauthenticateAccount` 成功后立即清除 `accountUsageErrors`
- `switchAccount` 完成后重新捕获 credentials（Step 5），避免 backup 里存的是过期 access token
- 活跃账号 token 过期时，先尝试 `auth status` 触发 CLI 内部刷新，若 token 变化则自动恢复
- Usage Dashboard 过期卡片新增 "Re-auth" 按钮，直接触发重新认证
- `isAutoSwitching` 改用 `defer` 保护，防止异常后永远卡住

### fix: Login 轮询等待 OAuth 完成
- `login()` 改为轮询机制（每 2s 检查 auth status，最多 120s），不再只等 2 秒
- 通过 token 字符串直接比较检测同账号重新登录（不用 hashValue）
- `loginNewAccount()` 传入当前 email 检测账号变更
- `reauthenticateAccount()` 传入目标 email 正确等待 token 刷新
- 新增 Cancel 按钮允许用户取消等待，支持 Task cancellation
- `loginNewAccount()` 增加重入保护

### fix: Token 过期自动检测与预防
- 新增 `isTokenExpired()` 本地检查 accessToken 的 expiresAt 字段（兼容 Int/Double/NSNumber）
- 切换账号时如果目标 token 已过期，自动转为 re-auth 流程（打开浏览器重新登录），而不是用死 token 切换后报 401
- 获取用量时预检查非活跃账号 token 过期，直接标记 "Token expired" 并跳过 API 调用
- 自动切换排除 token 过期的账号

### fix: 全面健壮性审计修复
- **账号切换回滚**：`switchAccount` oauthAccount 写入失败时自动回滚已写入的 token
- **Keychain 并发安全**：backup store 的 load-modify-save 加 NSLock 保护
- **writeClaudeToken 原子化**：去掉多余的 delete 步骤，仅用 `-U` flag 原子更新
- **removeAccount 等待切换**：从 fire-and-forget 改为 await switchTo，避免状态不一致
- **自动切换防振荡**：从追踪 1 个改为追踪多个 recently-abandoned 账号（30 分钟冷却）
- **runClaude 防死锁**：先读 pipe 数据再 waitUntilExit，避免大输出填满缓冲区
- **日志追加模式**：FileLogger 不再每次启动清空日志，改为追加 + 2MB 轮转

---

## v1.1.2 (build 32) — 738899d

### feat: Universal binary
- 构建 arm64 + x86_64 通用二进制，支持 Intel 和 Apple Silicon Mac

## v1.1.1 (build 31) — f52c317

### style: Adaptive color tokens
- 新增自适应颜色 token 支持 light/dark mode
- 统一卡片圆角为 10，加深边框透明度
- Tab bar 改为单个胶囊形态

## v1.1.0 (build 30) — c4e0f28

### feat: Activity dashboard & cost tracking
- 新增今日活动统计面板：对话轮数、编码时长、写入行数、模型使用分布
- 新增 API 等效成本追踪 tab，支持 7/30 天汇总和官方定价
- Tab bar 改为胶囊选中指示器样式
- 品牌色更新为 #d97757

### fix: Popover tooltip
- 修复活动面板中 popover tooltip 高度问题

## v1.0.8 (build 28) — c36b787

### feat: Double Usage promotion
- 新增 Double Usage 促销指示器和 banner

### fix: Refresh & update
- 实现非活跃账号的静默 swap 刷新
- 处理 GitHub API 频率限制和 404 错误
- 将自动刷新定时器与 UI 生命周期解耦

## v1.0.5 — e5db837

### feat: In-app DMG updater
- 实现原生应用内 DMG 下载器，带进度 UI 和自动挂载

## v1.0.3 (build 23) — 560769a

### refactor: XcodeGen migration
- 迁移到 XcodeGen 自动生成 Info.plist，project.yml 作为唯一配置源
- 添加 AGENTS.md / CLAUDE.md 确立项目规范

## v1.0.1 — 3ac1d0d

### feat: Keychain migration
- 账号备份从本地文件迁移到 macOS 安全钥匙串
- 修复 app icon 编译问题

## v1.0.0 — ecdf47d → 0fed55c

### feat: Initial release
- macOS 菜单栏应用，支持 Claude Code 多账号切换
- 真实 API 用量数据展示（替代假数据）
- Token 委托刷新（通过 Claude CLI + security CLI keychain 读取）
- 隐私保护：邮箱和账号名脱敏
- 自动刷新间隔（默认 5 分钟）
- 自定义 macOS app icon
- GitHub Actions CI/CD：签名、公证、DMG 打包、自动发布
- 内置更新检查器（查询 GitHub Releases）
