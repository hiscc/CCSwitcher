# CCSwitcher 技术教训

## 0. 架构原则（铁律 · 任何改动前必读）

**底层只有一个真相源**：

- macOS keychain 的 `Claude Code-credentials`（active 账号 token）
- `~/.claude.json` 的 `oauthAccount` 字段（active 账号身份）

Claude CLI 永远只读这一个槽位。

**CCSwitcher 的本质职责只有一个**：

> 维护一个多账号 token 仓库（vault），把其中一份按需写到 OS 槽位上去。

所有其他"状态"都是**衍生**的，应该实时从 vault + OS 读出来，**不应该独立存储**：

| 衍生数据 | 真相源 | 现状 |
|---------|--------|------|
| `accounts[]` 列表（id/email/orgName/displayName） | vault.entries 的 oauthAccount 快照 | ✅ 已 derive：`reconcileAccountsWithVault()` 每次 init/refresh 用 vault 重建 |
| `activeAccountId` | `~/.claude.json.oauthAccount.email` 与 vault 各 entry 比对 | ✅ 已单源：`setActiveAccount(id:)` 唯一写入路径，`updateActiveAccount` 从 OS 层 derive |
| 用量数据 | API 调用结果 | ⚠️ 部分：`fetchAllAccountUsage` atomic replace（每轮整体替换三个 dict），但仍是三个独立 @Published；可选下一步合并为 `[UUID: UsageState]` enum |
| `lastUsed` / `subscriptionType` | 无 OS 层等价 | ✅ UserDefaults 持久化（vault 之外的纯 UI 元数据） |

**为什么这个原则重要**：每多一处独立存储，就多一种"同步路径"，多一类"diverge bug"。已知病例：

- OAuth SSO 污染（token 主体 ≠ oauthAccount.email）
- removeAccount short-circuit（`Account.isActive` 已变但 keychain 没换）
- `accountUsage` 字典残留 stale 数据（`accountUsageErrors.removeAll()` 但 `accountUsage` 不清）
- 外部 `claude auth logout` 后 `activeAccount` 不响应
- `isLoggingIn` 单字段被复用为多种"禁止 refresh"信号

这些都是同一个病：**多真相源 + 手动同步 + 没有 atomic guarantee**。

**新增功能前必问的问题**：

- 这个数据能不能 derived？能就不要存。
- 必须存的话，写它的路径有几条？> 1 条就要走 actor/lock 串行化。
- 与 OS 真相源（keychain / `~/.claude.json`）的一致性谁负责？什么时候校验？

来源：2026-04-30 与用户调试时用户原话指出"底层就一个密钥，ccs 只是去同步底层密钥而已"，固化为铁律。

---



## 1. 两账号用量数据完全相同（CCSwitcher 显示账号 A 的数据但实际是账号 B 的）

### 症状（用户视角）

CCSwitcher 列表中，两个明明独立的 Claude 账号（不同 emailAddress、不同 organizationUuid）显示**完全相同**的 Session/Weekly/Extra usage 数据，包括金额和 reset 时间。

经 claude.ai 网页 Settings → Usage 验证，**网页上每个账号的真实数据是不同的**——CCSwitcher 显示的是错的。

### 已验证的关键事实（不要再走弯路）

1. ✅ CCSwitcher 客户端代码逻辑是对的：`fetchAllAccountUsage()` 按账号循环、按 backup 取 token、`accountUsage[account.id]` 按 UUID 存。
2. ✅ 日志里两个账号的 fetch 用了**不同 Bearer 字符串**（access token 字符串不同）：
   ```
   25: Bearer lTqIrSJumCO_Qr_moMA-...
   21: Bearer NBFQSVZ1jYuQCfV1_akMU...
   ```
3. ✅ 两个账号的 backup oauthAccount 元数据**完全独立**（不同 organizationUuid、accountUuid）：
   ```
   21: organizationUuid=85d14800-...  accountUuid=af5f5612-...
   25: organizationUuid=761251dd-...  accountUuid=562b209d-...
   ```
4. ✅ Anthropic 网页 Settings → Usage 显示账号 25 是独立账号、独立用量（25% / 0% / $63.23），跟 CCSwitcher 显示的（52% / 29% / $78.31）完全不同。

### 已被证伪的诊断方向（不要再这么猜）

- ❌ "同 org 共享配额" — organizationUuid 不同，证伪。
- ❌ "客户端 token 字典 key 冲突" — UUID 不同，证伪。
- ❌ "fetchUsage 写错 token" — 日志里调用确实用了不同 token，证伪。

### 真正的根因（已确认 ✅）

**OAuth 浏览器 SSO 残留导致 backup 被签错主体。**

- 用户做 `loginNewAccount` 添加新账号 B 时，浏览器里 claude.ai 仍持有账号 A 的 cookie
- Anthropic OAuth 授权用 A 主体签发了新 token（access token 字符串是新的，但 subject = A）
- OAuth response 里夹带的 `oauthAccount` 元数据被错误填成了 B 的 email/UUID
- 结果：`backup_B = { token(主体=A), oauthAccount(身份=B) }` —— 错配
- 所有"按 email 校验"的代码（`expectedEmail`、`repairCorruptedBackups`、organizationUuid 看起来也是 B 的）都通过，但 API 实际按 token 主体返 A 的数据

**修复方式（已用户验证）**：
1. CCSwitcher 中移除被污染的账号（清掉错配的 backup）
2. 浏览器 logout claude.ai（清 SSO cookie）
3. 重新 loginNewAccount，浏览器 OAuth 弹出后用正确账号登录后再授权
4. 之后该账号 usage 立即变成正确独立数据 ✅（2026-04-30 用户实测）

### 验证路径（已验证）

2026-04-30 用户按以下步骤操作，污染消失、用量数据恢复正确：

1. CCSwitcher 中移除被污染账号（清掉错配的 backup）
2. （建议）打开 claude.ai 在浏览器中 logout 当前账号（清掉 SSO cookie）
3. CCSwitcher → 添加新账号 → 浏览器弹出后**先用目标邮箱登录 claude.ai**，再完成 OAuth 授权

### 客户端可做的健壮性增强（可选）

1. **检测重复用量**：当两个账号 `accountUsage` 数据完全一致（同 session/weekly/extra/reset 时间）时，UI 给 warning："这两个账号 OAuth token 可能关联到同一 Anthropic 主体，请重新登录其中一个。"
2. **token 主体校验**：fetch usage 后调 Anthropic 的 user profile / `/v1/me` 端点（如有），对比返回的 email 与 `oauthAccount.emailAddress`，不一致时标记 backup 为"已污染，需重新登录"。

### 验证命令

```bash
# 看每个账号实际用了什么 token + 拿到什么结果（最关键的诊断信息）
grep -E "getUsageLimits.*Bearer|fetchUsage.*session" ~/Library/Logs/CCSwitcher.log | tail -20

# 看 backup 里的非密身份元数据（org/account UUID）— 能识别是否是同主体
security find-generic-password -s "me.xueshi.ccswitcher.backups" -a "all-accounts" -w | \
  python3 -c "import json,sys;d=json.loads(sys.stdin.read());[print(a,'-',b['oauthAccount'].get('emailAddress'),'-',b['oauthAccount'].get('organizationUuid')) for a,b in d.items()]"
```

### 相关代码位置

- `CCSwitcher/Services/ClaudeService.swift:89` `getUsageLimits(accessToken:)`
- `CCSwitcher/AppState.swift:548` `fetchAllAccountUsage()`
- `CCSwitcher/AppState.swift:223` `loginNewAccount()` — 浏览器 OAuth 流程入口

——

来源：2026-04-30 与用户调试。证据：CCSwitcher 日志 03:04 段、`security find-generic-password` 读出的 backup 元数据、claude.ai 网页 Settings/Usage 截图。

## 6. 登录新账号永远超时 —— 三层根因 + 部署假成功(2026-06-11)

### 症状(用户视角)

点 "Login New Account" → 浏览器完成授权 → app 一直 "Waiting for browser login..." → 最终 "Login did not complete within 2 minutes"。反复重试均失败。

### 三层根因(由浅入深,前两层修完仍失败才挖到第三层)

1. **stderr 污染 stdout**:`runClaude` 把 stderr/stdout 指向同一个 Pipe。Bun 在无 AVX 的 CPU 上每次启动都向 stderr 打 `warn: CPU lacks AVX support...`,拼到 `auth status` 的 JSON 前 → `JSONDecoder` 全部解析失败。已修:独立 errPipe。
2. **登录检测假阳性**:`claude auth login` 启动时会先清空 keychain token。旧检测 `currentToken != preLoginToken` 在 token 被清成 nil 时误判"token 变了=登录成功"。日志铁证:`[readClaudeToken] No token found!` 紧跟 `Login detected ... tokenChanged=true`。已修:稳定确认窗口(连续 6 次 OK 才算成功)+ 要求 token 非 nil。
3. **CLI 子进程随机早退,OAuth code 无人接收(结构性,真凶)**:实测 `claude auth login` 的 OAuth 流程是 `redirect_uri=https://platform.claude.com/oauth/code/callback`(托管页),code 由托管页转发回 CLI 监听的 localhost 随机端口(或手动粘贴进 CLI stdin)。**CLI 主进程必须活到用户完成浏览器授权**。app 里该子进程曾 5 秒内 exit 1(手动跑/管道环境跑均存活 10s+,排除 stdin/管道/浏览器因素 → 指向 Bun 无 AVX 随机崩溃)。主进程一死,授权 code 无人接收,keychain 永不更新,轮询必超时。

### 衍生坑

- **僵尸 login 进程**:旧版 app 取消登录不杀子进程,`claude auth login` 僵尸可存活数小时,各占一个 localhost 监听端口(实测见过 2 个活 3.5h)。排查命令:`ps aux | grep "claude auth login"`。
- **部署假成功**:`xcodebuild` 成功 ≠ `/Applications` 里是新版。曾发生 cp 未生效仍跑 Apr 30 旧二进制,调试结论全部失真。**铁律:部署后必须 `md5 -q 构建产物 == md5 -q /Applications/...` 双向校验 + `stat -f %Sm` 看二进制时间。**

### 结构性结论(✅ 已全部实施 2026-06-11)

在无 AVX(Bun 自警告 strange crashes)的机器上,任何"依赖 CLI 子进程"的设计都不可靠。最终架构:**app 零 fork**——
- 登录 = 原生 OAuth:PKCE + 授权 URL(与 CLI 逐字段一致)→ 用户粘贴托管页显示的 `code#state` → POST `platform.claude.com/v1/oauth/token` 换 token → GET `api.anthropic.com/api/oauth/profile`(Bearer + `anthropic-beta: oauth-2025-04-20`)拿身份/订阅 → 双写 keychain + `~/.claude.json`
- `getAuthStatus` = 直读两个 OS 真相源(loggedIn = token 存在 + oauthAccount email 存在;subscriptionType 取自 token JSON)
- switch 验证 = 回读自己写的槽位;`runClaude`/`logout()`/`isClaudeAvailable`/login 进程跟踪全部删除
- 关键 API 事实:profile 端点返回 account{uuid,email,display_name,has_claude_max,has_claude_pro} + organization{uuid,name,organization_type,billing_type,rate_limit_tier,…},足够构建完整 oauthAccount;token 端点同时服务 refresh_token 和 authorization_code 两种 grant

### 验证命令

```bash
# 僵尸 login 进程 + 各自监听端口
ps aux | grep "claude auth login" | grep -v grep
lsof -p <pid> -a -i | grep -i listen

# 手动复现 CLI 行为(会弹授权页,别点授权,测完 kill)
claude auth login </dev/null >/tmp/o 2>/tmp/e & PID=$!; # 观察存活/退出码

# 部署校验
md5 -q ~/Library/Developer/Xcode/DerivedData/CCSwitcher-*/Build/Products/Release/CCSwitcher.app/Contents/MacOS/CCSwitcher
md5 -q /Applications/CCSwitcher.app/Contents/MacOS/CCSwitcher
```

——

来源:2026-06-11 与用户调试登录失败。证据:CCSwitcher.log 05:43–06:57 段、ps/lsof 僵尸进程取证、claude auth login 对照实验(/tmp/loginA.out、/tmp/loginB.out)。
