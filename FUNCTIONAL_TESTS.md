# CCSwitcher 功能测试清单

> 生成日期：2026-04-09
> 适用版本：基于当前 main 分支代码
> 测试方式：手动测试，逐项勾选

---

## 1. 应用生命周期 (CCSwitcherApp)

### 1.1 启动与菜单栏

- [ ] **TC-1.1.1** 应用启动显示菜单栏图标
  - 前置条件：无
  - 测试步骤：双击启动 CCSwitcher.app
  - 预期结果：菜单栏出现 `brain.head.profile` 图标，无 Dock 图标（LSUIElement）

- [ ] **TC-1.1.2** Keepalive 隐藏窗口不可见
  - 前置条件：应用已启动
  - 测试步骤：检查窗口列表（Cmd+Tab 或 Mission Control）
  - 预期结果：不存在可见的 CCSwitcherKeepalive 窗口

- [ ] **TC-1.1.3** 启动时静默检查更新
  - 前置条件：网络正常
  - 测试步骤：启动应用，查看日志
  - 预期结果：日志显示 UpdateChecker 调用 `manual: false`，无弹窗（除非有新版本）

- [ ] **TC-1.1.4** 启动时立即刷新用量
  - 前置条件：至少有一个账号
  - 测试步骤：启动应用，观察 Dashboard
  - 预期结果：用量数据在几秒内加载完成

### 1.2 自动刷新定时器

- [ ] **TC-1.2.1** 默认 5 分钟自动刷新
  - 前置条件：默认设置
  - 测试步骤：等待 5 分钟，观察日志中的 `[refresh]` 条目
  - 预期结果：每 5 分钟触发一次 refresh

- [ ] **TC-1.2.2** 修改刷新间隔后立即生效
  - 前置条件：打开设置
  - 测试步骤：将刷新间隔改为 15 秒，等待 20 秒
  - 预期结果：15 秒后触发刷新

- [ ] **TC-1.2.3** 刷新过程中不重复触发
  - 前置条件：刷新间隔设为最短
  - 测试步骤：连续快速触发刷新
  - 预期结果：日志显示 `Skipping: already refreshing`，不会并发执行

- [ ] **TC-1.2.4** 登录过程中跳过刷新
  - 前置条件：正在执行登录流程
  - 测试步骤：等待自动刷新触发
  - 预期结果：日志显示 `Skipping: login in progress`

### 1.3 菜单栏图标与用量显示

- [ ] **TC-1.3.1** 普通状态显示空心图标
  - 前置条件：非 Double Usage 时段
  - 测试步骤：观察菜单栏
  - 预期结果：显示 `brain.head.profile`（空心）

- [ ] **TC-1.3.2** Double Usage 激活时显示填充图标
  - 前置条件：ET 时区 14:00-08:00 或周末，且在促销日期范围内（2026/3/13-3/28）
  - 测试步骤：在上述时段运行应用
  - 预期结果：显示 `brain.head.profile.fill`（填充）

- [ ] **TC-1.3.3** 开启菜单栏用量百分比显示
  - 前置条件：至少有一个账号且有用量数据
  - 测试步骤：Settings → 开启 "Show Usage in Menu Bar"
  - 预期结果：菜单栏图标旁显示当前 session 用量百分比数字

- [ ] **TC-1.3.4** 关闭菜单栏用量百分比显示
  - 前置条件：已开启用量显示
  - 测试步骤：Settings → 关闭 "Show Usage in Menu Bar"
  - 预期结果：菜单栏仅显示图标，无数字

- [ ] **TC-1.3.5** 无活跃账号时不显示百分比
  - 前置条件：开启用量显示但无账号
  - 测试步骤：删除所有账号
  - 预期结果：菜单栏仅显示图标

- [ ] **TC-1.3.6** 有缓存但无实时数据时显示缓存值
  - 前置条件：有缓存数据，网络断开
  - 测试步骤：重启应用
  - 预期结果：菜单栏显示缓存的 `effectiveSessionUtilization()` 值

### 1.4 Double Usage 促销检测

- [ ] **TC-1.4.1** 促销日期范围之外不激活
  - 前置条件：系统日期不在 2026/3/13 ~ 2026/3/28
  - 测试步骤：启动应用
  - 预期结果：`isDoubleUsageActive = false`

- [ ] **TC-1.4.2** 促销期内 ET 工作日白天不激活
  - 前置条件：促销期内，ET 时区 08:00-14:00 工作日
  - 测试步骤：检查图标状态
  - 预期结果：`isDoubleUsageActive = false`

- [ ] **TC-1.4.3** 促销期内 ET 工作日晚间激活
  - 前置条件：促销期内，ET 时区 14:00+
  - 测试步骤：检查图标状态
  - 预期结果：`isDoubleUsageActive = true`

- [ ] **TC-1.4.4** 促销期内周末全天激活
  - 前置条件：促销期内，ET 时区周六或周日
  - 测试步骤：任意时间检查
  - 预期结果：`isDoubleUsageActive = true`

- [ ] **TC-1.4.5** 每分钟自动检测状态变化
  - 前置条件：促销期内
  - 测试步骤：在 ET 14:00 前后观察
  - 预期结果：图标状态在整点自动切换

---

## 2. 账号管理 (AppState + AccountSwitcherView)

### 2.1 添加当前账号

- [ ] **TC-2.1.1** 正常添加当前已登录账号
  - 前置条件：Claude CLI 已安装且已登录
  - 测试步骤：点击 "Add Current Account"
  - 预期结果：账号出现在列表中，显示邮箱和组织名

- [ ] **TC-2.1.2** Claude CLI 未安装时添加失败
  - 前置条件：Claude CLI 不在 PATH 中
  - 测试步骤：点击 "Add Current Account"
  - 预期结果：显示错误 "Claude CLI not found"

- [ ] **TC-2.1.3** 未登录状态添加失败
  - 前置条件：Claude CLI 已安装但未登录
  - 测试步骤：点击 "Add Current Account"
  - 预期结果：显示错误 "Not logged in to Claude"

- [ ] **TC-2.1.4** 重复添加同一账号
  - 前置条件：账号 A 已在列表中
  - 测试步骤：当前登录 A，点击 "Add Current Account"
  - 预期结果：显示错误 "Account already exists"

- [ ] **TC-2.1.5** 第一个账号自动设为活跃
  - 前置条件：无任何账号
  - 测试步骤：添加第一个账号
  - 预期结果：该账号自动标记为 Active

- [ ] **TC-2.1.6** Token 捕获失败
  - 前置条件：keychain 中无 Claude Code token
  - 测试步骤：尝试添加账号
  - 预期结果：显示错误 "Could not capture auth token from keychain"

### 2.2 登录新账号

- [ ] **TC-2.2.1** 正常登录新账号
  - 前置条件：Claude CLI 可用
  - 测试步骤：点击 "Login New Account"，在浏览器完成 OAuth
  - 预期结果：新账号添加到列表并标记为 Active

- [ ] **TC-2.2.2** 登录前备份当前活跃账号
  - 前置条件：有活跃账号 A
  - 测试步骤：登录新账号 B
  - 预期结果：A 的凭据已备份，日志显示 Step 1 backup result: true

- [ ] **TC-2.2.3** 登录已存在的账号（刷新凭据）
  - 前置条件：账号 A 已在列表中
  - 测试步骤：登录流程中使用账号 A 的邮箱
  - 预期结果：A 的备份被刷新，错误状态被清除，不会创建重复条目

- [ ] **TC-2.2.4** 登录超时（120秒无完成）
  - 前置条件：启动登录后不在浏览器中完成
  - 测试步骤：等待 120 秒
  - 预期结果：日志显示 polling timed out

- [ ] **TC-2.2.5** 取消登录
  - 前置条件：登录等待中
  - 测试步骤：点击 "Cancel" 按钮
  - 预期结果：loginTask 被取消，isLoggingIn 恢复 false

- [ ] **TC-2.2.6** 登录重入保护
  - 前置条件：正在登录中
  - 测试步骤：再次点击 "Login New Account"
  - 预期结果：被忽略，日志显示 "Already logging in, skipping"

- [ ] **TC-2.2.7** 登录后立即刷新用量
  - 前置条件：登录成功
  - 测试步骤：观察 Dashboard
  - 预期结果：新账号用量数据立即显示

- [ ] **TC-2.2.8** CLI 非零退出码容错
  - 前置条件：CLI 在无 TTY 环境下运行
  - 测试步骤：登录流程开始
  - 预期结果：CLI 退出错误被容忍，继续轮询 auth status

### 2.3 切换账号

- [ ] **TC-2.3.1** 正常切换到非活跃账号
  - 前置条件：有 A（活跃）和 B 两个账号
  - 测试步骤：点击 B 的卡片或切换按钮
  - 预期结果：B 变为 Active，keychain 和 ~/.claude.json 更新为 B 的凭据

- [ ] **TC-2.3.2** 切换前备份当前账号
  - 前置条件：A 为活跃
  - 测试步骤：切换到 B
  - 预期结果：日志 Step 1 显示 A 的 token + oauthAccount 备份成功

- [ ] **TC-2.3.3** 切换前验证目标备份 email 匹配
  - 前置条件：B 的备份 email 与 B.email 不匹配（损坏状态）
  - 测试步骤：尝试切换到 B
  - 预期结果：触发 re-auth 流程而非正常切换

- [ ] **TC-2.3.4** 目标 token 过期 → 自动刷新成功
  - 前置条件：B 的 accessToken 已过期但 refreshToken 有效
  - 测试步骤：切换到 B
  - 预期结果：自动刷新 token，更新备份，正常完成切换

- [ ] **TC-2.3.5** 目标 token 过期 → 自动刷新失败 → re-auth
  - 前置条件：B 的 accessToken 和 refreshToken 均无效
  - 测试步骤：切换到 B
  - 预期结果：显示 "Token expired"，自动进入 re-auth 流程

- [ ] **TC-2.3.6** 切换后 auth status 验证
  - 前置条件：切换流程进行中
  - 测试步骤：观察日志 Step 4
  - 预期结果：验证 `claude auth status` 返回已登录且 email 匹配

- [ ] **TC-2.3.7** 切换验证失败 → 回滚 keychain
  - 前置条件：`claude auth status` 返回非登录状态
  - 测试步骤：模拟验证失败场景
  - 预期结果：keychain 的 token 和 oauthAccount 恢复为原始值

- [ ] **TC-2.3.8** 切换后 email 不匹配 → 回滚
  - 前置条件：auth status 返回的 email 与目标不同
  - 测试步骤：模拟 email 不匹配
  - 预期结果：回滚 keychain，报错 `switchWrongAccount`

- [ ] **TC-2.3.9** 切换成功后重新捕获凭据（Step 5）
  - 前置条件：切换成功
  - 测试步骤：检查日志 Step 5
  - 预期结果：目标账号的备份被更新（CLI 可能已刷新 token）

- [ ] **TC-2.3.10** oauthAccount 写入失败 → 回滚 token
  - 前置条件：~/.claude.json 写入失败
  - 测试步骤：模拟写入失败
  - 预期结果：token 被回滚到原始值

- [ ] **TC-2.3.11** 切换到同一账号（无操作）
  - 前置条件：A 为活跃
  - 测试步骤：尝试切换到 A
  - 预期结果：日志显示 "No switch needed"，无操作

- [ ] **TC-2.3.12** 无备份的目标账号
  - 前置条件：B 的备份不存在
  - 测试步骤：尝试切换到 B
  - 预期结果：显示错误 "No stored credentials for B"

### 2.4 删除账号

- [ ] **TC-2.4.1** 删除非活跃账号
  - 前置条件：有 A（活跃）和 B
  - 测试步骤：删除 B
  - 预期结果：B 从列表移除，备份和缓存清理

- [ ] **TC-2.4.2** 删除活跃账号后自动切换
  - 前置条件：有 A（活跃）和 B
  - 测试步骤：删除 A
  - 预期结果：B 自动变为活跃，keychain 写入 B 的凭据

- [ ] **TC-2.4.3** 删除唯一账号
  - 前置条件：只有一个账号
  - 测试步骤：删除该账号
  - 预期结果：列表为空，activeAccount = nil

- [ ] **TC-2.4.4** 删除时清理 accountUsageErrors
  - 前置条件：B 有 expired 错误状态
  - 测试步骤：删除 B
  - 预期结果：`accountUsageErrors[B.id]` 被移除

### 2.5 重新认证

- [ ] **TC-2.5.1** 正常重新认证
  - 前置条件：账号 A 的 token 已过期
  - 测试步骤：点击 "Re-authenticate"，在浏览器完成 OAuth
  - 预期结果：A 的凭据更新，expired 状态清除

- [ ] **TC-2.5.2** 重新认证时 email 不匹配
  - 前置条件：账号 A 需要 re-auth
  - 测试步骤：浏览器登录了不同邮箱 B
  - 预期结果：错误提示 "Logged in as B, but expected A"

- [ ] **TC-2.5.3** 重新认证前备份其他活跃账号
  - 前置条件：B 为活跃，A 需要 re-auth
  - 测试步骤：对 A 执行 re-auth
  - 预期结果：B 的凭据先被备份

- [ ] **TC-2.5.4** 重新认证后更新 account metadata
  - 前置条件：完成 re-auth
  - 测试步骤：检查账号信息
  - 预期结果：orgName、subscriptionType 更新为最新值

---

## 3. 自动切换 (autoSwitchIfNeeded)

### 3.1 基本触发

- [ ] **TC-3.1.1** 自动切换关闭时不触发
  - 前置条件：autoSwitchEnabled = false
  - 测试步骤：当前用量达 100%
  - 预期结果：不触发自动切换

- [ ] **TC-3.1.2** 只有一个账号时不触发
  - 前置条件：autoSwitchEnabled = true，只有 1 个账号
  - 测试步骤：用量达阈值
  - 预期结果：不触发自动切换

- [ ] **TC-3.1.3** 用量未达阈值不触发
  - 前置条件：阈值 90%，当前用量 85%
  - 测试步骤：等待自动刷新
  - 预期结果：不触发切换

- [ ] **TC-3.1.4** 用量达阈值时触发切换
  - 前置条件：阈值 90%，当前用量 92%，有可用候选
  - 测试步骤：等待自动刷新
  - 预期结果：自动切换到用量最低的账号

### 3.2 候选排序与选择

- [ ] **TC-3.2.1** 按用量排序选择最低
  - 前置条件：B 用量 20%，C 用量 50%
  - 测试步骤：触发自动切换
  - 预期结果：切换到 B

- [ ] **TC-3.2.2** 用量差异 <10% 时按 weekly reset 时间排序
  - 前置条件：B 用量 22%（reset 2 天后），C 用量 25%（reset 1 天后）
  - 测试步骤：触发自动切换
  - 预期结果：切换到 C（reset 更近）

- [ ] **TC-3.2.3** 排除 token 过期的账号
  - 前置条件：B 用量 10% 但 token 过期
  - 测试步骤：触发自动切换
  - 预期结果：跳过 B，选择其他候选

- [ ] **TC-3.2.4** 所有候选均超阈值
  - 前置条件：所有非活跃账号用量 > 阈值
  - 测试步骤：触发自动切换
  - 预期结果：日志 "No suitable account found"，不切换

### 3.3 防振荡机制

- [ ] **TC-3.3.1** 10 分钟冷却期内不重复切换
  - 前置条件：刚完成一次自动切换
  - 测试步骤：5 分钟后新账号也达阈值
  - 预期结果：日志 "Cooldown active, skipping"

- [ ] **TC-3.3.2** 冷却期过后可再次切换
  - 前置条件：上次自动切换已过 10 分钟
  - 测试步骤：用量再次达阈值
  - 预期结果：正常触发自动切换

- [ ] **TC-3.3.3** recently-abandoned 账号被降低优先级
  - 前置条件：A→B 自动切换后，B 也达阈值
  - 测试步骤：B 触发自动切换，有 A 和 C 可选
  - 预期结果：优先选择 C（A 是 recently-abandoned）

- [ ] **TC-3.3.4** abandoned 冷却 30 分钟后恢复优先级
  - 前置条件：A 被 abandon 已超 30 分钟
  - 测试步骤：触发自动切换
  - 预期结果：A 正常参与候选排序

- [ ] **TC-3.3.5** 仅有 recently-abandoned 候选时仍可选择
  - 前置条件：唯一候选是 recently-abandoned 的 A
  - 测试步骤：触发自动切换
  - 预期结果：切换到 A（降级但非排除）

### 3.4 递归保护

- [ ] **TC-3.4.1** isAutoSwitching 防止 refresh 递归触发 autoSwitch
  - 前置条件：自动切换进行中（switchTo → refresh）
  - 测试步骤：观察内部 refresh 调用
  - 预期结果：refresh 中跳过 autoSwitchIfNeeded（isAutoSwitching = true）

---

## 4. 用量获取 (fetchAllAccountUsage)

### 4.1 正常获取

- [ ] **TC-4.1.1** 活跃账号从 keychain 读取 token
  - 前置条件：有活跃账号
  - 测试步骤：触发 refresh
  - 预期结果：使用 `readClaudeToken()` 获取 token

- [ ] **TC-4.1.2** 非活跃账号从备份读取 token
  - 前置条件：有非活跃账号 B
  - 测试步骤：触发 refresh
  - 预期结果：使用 `getAccountBackup()` 获取 B 的 token

- [ ] **TC-4.1.3** 成功获取用量数据
  - 前置条件：token 有效
  - 测试步骤：触发 refresh
  - 预期结果：`accountUsage[id]` 包含 fiveHour 和 sevenDay 数据

- [ ] **TC-4.1.4** 请求间隔 1.5 秒防 429
  - 前置条件：有 3 个账号
  - 测试步骤：触发 refresh，观察日志时间戳
  - 预期结果：每个请求间隔约 1.5 秒

### 4.2 Token 过期处理

- [ ] **TC-4.2.1** 非活跃账号 token 过期 → 本地刷新成功
  - 前置条件：B 的 token 过期，refreshToken 有效
  - 测试步骤：触发 refresh
  - 预期结果：token 刷新后正常获取用量

- [ ] **TC-4.2.2** 非活跃账号 token 过期 → 刷新失败
  - 前置条件：B 的 token 和 refreshToken 均无效
  - 测试步骤：触发 refresh
  - 预期结果：标记为 expired，使用缓存数据

- [ ] **TC-4.2.3** 401 expired 响应 → 自动刷新重试
  - 前置条件：API 返回 401
  - 测试步骤：触发 refresh
  - 预期结果：尝试刷新 token 并重试请求

- [ ] **TC-4.2.4** 401 → 刷新 → 重试成功
  - 前置条件：refreshToken 有效
  - 测试步骤：观察日志
  - 预期结果：日志 "Recovered via auto-refresh"

- [ ] **TC-4.2.5** 401 → 刷新 → 重试失败
  - 前置条件：refreshToken 无效
  - 测试步骤：观察日志
  - 预期结果：fallback 到缓存，标记 expired

- [ ] **TC-4.2.6** 活跃账号 401 后刷新并写回 keychain
  - 前置条件：活跃账号 API 返回 401
  - 测试步骤：观察日志
  - 预期结果：刷新后调用 `writeClaudeToken` 和 `captureCurrentCredentials`

### 4.3 Rate Limit 处理

- [ ] **TC-4.3.1** 429 有缓存 → 保留缓存数据
  - 前置条件：已有缓存数据，API 返回 429
  - 测试步骤：触发 refresh
  - 预期结果：`accountUsage` 保留缓存值，标记 isRateLimited

- [ ] **TC-4.3.2** 429 无缓存 → 3 秒后重试一次
  - 前置条件：无缓存，API 返回 429
  - 测试步骤：触发 refresh
  - 预期结果：等待 3 秒后重试，成功则缓存

- [ ] **TC-4.3.3** 429 无缓存 → 重试也失败
  - 前置条件：持续 429
  - 测试步骤：触发 refresh
  - 预期结果：标记 isRateLimited，accountUsage 为 nil

### 4.4 缓存机制

- [ ] **TC-4.4.1** 成功获取后写入缓存
  - 前置条件：获取用量成功
  - 测试步骤：检查 `cachedUsage`
  - 预期结果：包含最新 usage 和 fetchedAt

- [ ] **TC-4.4.2** 缓存保存到 UserDefaults
  - 前置条件：获取用量成功
  - 测试步骤：重启应用
  - 预期结果：缓存数据从 UserDefaults 恢复

- [ ] **TC-4.4.3** 初始化时从缓存预填充 UI
  - 前置条件：有缓存数据
  - 测试步骤：重启应用
  - 预期结果：Dashboard 立即显示缓存数据（含 stale 的）

- [ ] **TC-4.4.4** 5 小时窗口过期后 utilization 视为 0%
  - 前置条件：缓存的 fiveHour.resetsAt 已过期
  - 测试步骤：检查 `effectiveSessionUtilization()`
  - 预期结果：返回 0.0

- [ ] **TC-4.4.5** weekly 重置后缓存标记为 stale
  - 前置条件：缓存的 sevenDay.resetsAt 已过期
  - 测试步骤：检查 `isStale`
  - 预期结果：返回 true

- [ ] **TC-4.4.6** 缓存超 2 小时标记为 stale
  - 前置条件：fetchedAt 在 2 小时前
  - 测试步骤：检查 `isStale`
  - 预期结果：返回 true

### 4.5 无 Token 情况

- [ ] **TC-4.5.1** 账号无 token 时跳过
  - 前置条件：某账号 keychain 中无 token 且无备份
  - 测试步骤：触发 refresh
  - 预期结果：日志 "No token for xxx, skipping"

---

## 5. Token 管理 (ClaudeService + KeychainService)

### 5.1 Keychain 读写

- [ ] **TC-5.1.1** 正常读取 Claude token
  - 前置条件：keychain 中有 Claude Code-credentials
  - 测试步骤：调用 `readClaudeToken()`
  - 预期结果：返回清理过的 token 字符串

- [ ] **TC-5.1.2** keychain 无 token 时返回 nil
  - 前置条件：keychain 中无对应条目
  - 测试步骤：调用 `readClaudeToken()`
  - 预期结果：返回 nil

- [ ] **TC-5.1.3** 写入 token（-U 原子更新）
  - 前置条件：无
  - 测试步骤：调用 `writeClaudeToken()`
  - 预期结果：keychain 中对应条目更新，返回 true

- [ ] **TC-5.1.4** token 尾部换行被清理
  - 前置条件：security CLI 输出带换行
  - 测试步骤：读取 token
  - 预期结果：返回 trimmed 字符串

### 5.2 ~/.claude.json oauthAccount

- [ ] **TC-5.2.1** 正常读取 oauthAccount
  - 前置条件：~/.claude.json 包含 oauthAccount 字段
  - 测试步骤：调用 `readOAuthAccount()`
  - 预期结果：返回包含 emailAddress 的字典

- [ ] **TC-5.2.2** ~/.claude.json 不存在
  - 前置条件：文件不存在
  - 测试步骤：调用 `readOAuthAccount()`
  - 预期结果：返回 nil

- [ ] **TC-5.2.3** 正常写入 oauthAccount
  - 前置条件：~/.claude.json 存在
  - 测试步骤：调用 `writeOAuthAccount()`
  - 预期结果：文件更新，格式为 prettyPrinted + sortedKeys

- [ ] **TC-5.2.4** 写入时保留 ~/.claude.json 其他字段
  - 前置条件：文件含有 oauthAccount 外的其他字段
  - 测试步骤：写入 oauthAccount
  - 预期结果：其他字段不丢失

### 5.3 备份存储（App Keychain）

- [ ] **TC-5.3.1** 保存账号备份
  - 前置条件：无
  - 测试步骤：调用 `saveAccountBackup()`
  - 预期结果：备份存入 app keychain (SecItem)

- [ ] **TC-5.3.2** 读取账号备份
  - 前置条件：已保存备份
  - 测试步骤：调用 `getAccountBackup()`
  - 预期结果：返回 AccountBackup 包含 token 和 oauthAccount

- [ ] **TC-5.3.3** 删除账号备份
  - 前置条件：已保存备份
  - 测试步骤：调用 `removeAccountBackup()`
  - 预期结果：备份被移除，再次读取返回 nil

- [ ] **TC-5.3.4** NSLock 保护并发访问
  - 前置条件：并发调用 save 和 load
  - 测试步骤：多线程操作备份
  - 预期结果：无数据竞争或损坏

- [ ] **TC-5.3.5** 从 backups.json 迁移到 keychain
  - 前置条件：~/.ccswitcher/backups.json 存在，keychain 中无数据
  - 测试步骤：初始化 KeychainService
  - 预期结果：数据迁移到 keychain，旧文件被删除

- [ ] **TC-5.3.6** 旧 tokens.json 清理
  - 前置条件：~/.ccswitcher/tokens.json 存在
  - 测试步骤：初始化 KeychainService
  - 预期结果：tokens.json 被删除（无法迁移，缺少 oauthAccount）

### 5.4 Token 过期检测

- [ ] **TC-5.4.1** token 未过期
  - 前置条件：expiresAt 在 10 分钟后
  - 测试步骤：调用 `isTokenExpired()`
  - 预期结果：返回 false

- [ ] **TC-5.4.2** token 即将过期（grace period 内）
  - 前置条件：expiresAt 在 200 秒后（<300秒 grace）
  - 测试步骤：调用 `isTokenExpired()`
  - 预期结果：返回 true

- [ ] **TC-5.4.3** token 已过期
  - 前置条件：expiresAt 已过
  - 测试步骤：调用 `isTokenExpired()`
  - 预期结果：返回 true

- [ ] **TC-5.4.4** 无 expiresAt 字段
  - 前置条件：token JSON 中无 expiresAt
  - 测试步骤：调用 `isTokenExpired()`
  - 预期结果：返回 true（保守策略）

- [ ] **TC-5.4.5** expiresAt 为 Int 类型
  - 前置条件：JSON 中 expiresAt 为整数
  - 测试步骤：调用 `isTokenExpired()`
  - 预期结果：正常解析，不崩溃

- [ ] **TC-5.4.6** expiresAt 为 Double 类型
  - 前置条件：JSON 中 expiresAt 为浮点数
  - 测试步骤：调用 `isTokenExpired()`
  - 预期结果：正常解析

- [ ] **TC-5.4.7** 无法解析 token JSON
  - 前置条件：token 不是有效 JSON
  - 测试步骤：调用 `isTokenExpired()`
  - 预期结果：返回 true

### 5.5 OAuth Token 刷新

- [ ] **TC-5.5.1** 正常刷新成功
  - 前置条件：refreshToken 有效
  - 测试步骤：调用 `refreshAccessToken()`
  - 预期结果：返回更新后的 token JSON，新 accessToken 和 expiresAt

- [ ] **TC-5.5.2** 无 refreshToken
  - 前置条件：token JSON 中无 refreshToken
  - 测试步骤：调用 `refreshAccessToken()`
  - 预期结果：返回 nil

- [ ] **TC-5.5.3** OAuth 服务器返回错误
  - 前置条件：refreshToken 无效
  - 测试步骤：调用 `refreshAccessToken()`
  - 预期结果：返回 nil，日志记录 HTTP 状态码

- [ ] **TC-5.5.4** 刷新后更新 refreshToken（如果服务器返回新的）
  - 前置条件：服务器返回新 refresh_token
  - 测试步骤：检查返回的 token JSON
  - 预期结果：新 refreshToken 被写入

- [ ] **TC-5.5.5** 网络错误
  - 前置条件：断网
  - 测试步骤：调用 `refreshAccessToken()`
  - 预期结果：返回 nil

### 5.6 凭据捕获

- [ ] **TC-5.6.1** 正常捕获（无 expectedEmail 校验）
  - 前置条件：keychain 有 token，~/.claude.json 有 oauthAccount
  - 测试步骤：调用 `captureCurrentCredentials()`
  - 预期结果：返回 true，备份保存成功

- [ ] **TC-5.6.2** expectedEmail 匹配
  - 前置条件：oauthAccount email = expectedEmail
  - 测试步骤：调用 `captureCurrentCredentials(expectedEmail:)`
  - 预期结果：返回 true

- [ ] **TC-5.6.3** expectedEmail 不匹配
  - 前置条件：oauthAccount email ≠ expectedEmail
  - 测试步骤：调用 `captureCurrentCredentials(expectedEmail:)`
  - 预期结果：返回 false，日志 "ABORT: keychain email != expected"

- [ ] **TC-5.6.4** keychain 无 token
  - 前置条件：keychain 为空
  - 测试步骤：调用 `captureCurrentCredentials()`
  - 预期结果：返回 false

- [ ] **TC-5.6.5** ~/.claude.json 无 oauthAccount
  - 前置条件：文件中无 oauthAccount 字段
  - 测试步骤：调用 `captureCurrentCredentials()`
  - 预期结果：返回 false

---

## 6. 健康诊断 (diagnoseTokenHealth + repairCorruptedBackups)

### 6.1 被动健康检查

- [ ] **TC-6.1.1** 检查所有账号的备份存在性
  - 前置条件：有 3 个账号
  - 测试步骤：触发 refresh，查看日志
  - 预期结果：每个账号输出 "Backup: OK" 或 "Backup: MISSING"

- [ ] **TC-6.1.2** 检查 live oauthAccount identity
  - 前置条件：有活跃账号
  - 测试步骤：查看诊断日志
  - 预期结果：输出当前 oauthAccount 的 email

- [ ] **TC-6.1.3** 无账号时跳过诊断
  - 前置条件：accounts 为空
  - 测试步骤：触发 refresh
  - 预期结果：不输出诊断日志

### 6.2 损坏备份修复

- [ ] **TC-6.2.1** 活跃账号备份 email 不匹配 → 重新捕获
  - 前置条件：活跃账号 A 的备份存储了 B 的 email
  - 测试步骤：触发 refresh
  - 预期结果：为 A 重新捕获凭据

- [ ] **TC-6.2.2** 非活跃账号备份 email 不匹配 → 删除备份
  - 前置条件：非活跃账号 B 的备份存储了错误 email
  - 测试步骤：触发 refresh
  - 预期结果：B 的备份被删除

- [ ] **TC-6.2.3** 备份 email 为空时不视为损坏
  - 前置条件：备份 oauthAccount 中无 emailAddress
  - 测试步骤：触发 refresh
  - 预期结果：不触发修复（empty string != account.email 判断中 `!backupEmail.isEmpty` 为 false）

---

## 7. Usage Dashboard (UsageDashboardView)

### 7.1 用量进度条

- [ ] **TC-7.1.1** Session (5h) 进度条正确显示
  - 前置条件：有用量数据
  - 测试步骤：查看 Dashboard
  - 预期结果：进度条宽度与 utilization 百分比匹配

- [ ] **TC-7.1.2** Weekly (7d) 进度条正确显示
  - 前置条件：有用量数据
  - 测试步骤：查看 Dashboard
  - 预期结果：进度条宽度与 weekly utilization 匹配

- [ ] **TC-7.1.3** 颜色编码 <60% 绿色
  - 前置条件：utilization < 60%
  - 测试步骤：观察进度条颜色
  - 预期结果：绿色

- [ ] **TC-7.1.4** 颜色编码 60%-90% 橙色
  - 前置条件：utilization 在 60%-90%
  - 测试步骤：观察进度条颜色
  - 预期结果：橙色

- [ ] **TC-7.1.5** 颜色编码 >90% 红色
  - 前置条件：utilization > 90%
  - 测试步骤：观察进度条颜色
  - 预期结果：红色

### 7.2 重置时间

- [ ] **TC-7.2.1** 显示北京时间格式 MM/dd HH:mm
  - 前置条件：有 resetsAt 数据
  - 测试步骤：查看重置时间
  - 预期结果：格式为 "04/09 14:30" 类似

- [ ] **TC-7.2.2** 倒计时格式正确
  - 前置条件：重置时间在未来
  - 测试步骤：查看重置时间
  - 预期结果：显示 "X hr Y min" 格式

- [ ] **TC-7.2.3** 已过重置时间显示 "now"
  - 前置条件：resetsAt 已过
  - 测试步骤：查看重置时间
  - 预期结果：显示 "now"

### 7.3 Extra Usage 显示

- [ ] **TC-7.3.1** Extra Usage 开启状态
  - 前置条件：extraUsage.isEnabled = true
  - 测试步骤：查看 Dashboard
  - 预期结果：显示 "On"、已用/额度信息

- [ ] **TC-7.3.2** Extra Usage 关闭状态
  - 前置条件：extraUsage.isEnabled = false
  - 测试步骤：查看 Dashboard
  - 预期结果：显示 "Off"

### 7.4 交互

- [ ] **TC-7.4.1** 点击非活跃账号卡片切换
  - 前置条件：有多个账号
  - 测试步骤：点击非活跃账号的卡片
  - 预期结果：触发 switchTo 切换到该账号

- [ ] **TC-7.4.2** Token 过期横幅显示
  - 前置条件：账号有 isExpired 错误
  - 测试步骤：查看 Dashboard
  - 预期结果：显示过期提示 + Re-auth 按钮

- [ ] **TC-7.4.3** Rate Limited 状态显示
  - 前置条件：账号有 isRateLimited 状态
  - 测试步骤：查看 Dashboard
  - 预期结果：显示 Rate Limited 提示

### 7.5 今日活动统计

- [ ] **TC-7.5.1** API 等效成本 banner
  - 前置条件：有今日成本数据
  - 测试步骤：查看 Dashboard
  - 预期结果：显示 "$X.XX API equivalent cost today"

- [ ] **TC-7.5.2** 对话轮数显示
  - 前置条件：有 activityStats
  - 测试步骤：查看统计区域
  - 预期结果：显示今日对话轮数

- [ ] **TC-7.5.3** 编码时长显示
  - 前置条件：有 activityStats
  - 测试步骤：查看统计区域
  - 预期结果：显示 "Xh Ym" 或 "Xm" 格式

- [ ] **TC-7.5.4** 代码行数显示
  - 前置条件：有 linesWritten 数据
  - 测试步骤：查看统计区域
  - 预期结果：显示今日修改行数

- [ ] **TC-7.5.5** 模型使用分布
  - 前置条件：有 modelUsage 数据
  - 测试步骤：查看模型分布
  - 预期结果：显示 Opus/Sonnet/Haiku 各自使用次数

### 7.6 排序与状态

- [ ] **TC-7.6.1** 账号按用量排序（最低在前）
  - 前置条件：有多个账号
  - 测试步骤：查看 Dashboard
  - 预期结果：用量低的账号排在上面

- [ ] **TC-7.6.2** 最后更新时间显示
  - 前置条件：已完成刷新
  - 测试步骤：查看底部
  - 预期结果：显示 "Last updated: HH:mm:ss" 格式

- [ ] **TC-7.6.3** Loading 状态
  - 前置条件：正在刷新中
  - 测试步骤：观察 Dashboard
  - 预期结果：显示 loading 指示器

- [ ] **TC-7.6.4** Empty 状态（无账号）
  - 前置条件：无任何账号
  - 测试步骤：查看 Dashboard
  - 预期结果：显示空状态提示

---

## 8. 成本详情 (CostDetailView)

### 8.1 今日成本

- [ ] **TC-8.1.1** 今日总成本显示
  - 前置条件：有今日 JSONL 数据
  - 测试步骤：打开 Cost Detail
  - 预期结果：显示今日总成本 $X.XX

- [ ] **TC-8.1.2** 模型分拆显示
  - 前置条件：今日使用了多个模型
  - 测试步骤：查看成本详情
  - 预期结果：每个模型（Opus/Sonnet/Haiku）单独显示成本

- [ ] **TC-8.1.3** Session 数和 Token 数显示
  - 前置条件：有 session 数据
  - 测试步骤：查看成本详情
  - 预期结果：显示 input/output/cache token 数量

### 8.2 历史汇总

- [ ] **TC-8.2.1** 7 天汇总
  - 前置条件：有 7 天数据
  - 测试步骤：查看 7-day 汇总
  - 预期结果：显示 7 天总成本

- [ ] **TC-8.2.2** 30 天汇总
  - 前置条件：有 30 天数据
  - 测试步骤：查看 30-day 汇总
  - 预期结果：显示 30 天总成本

- [ ] **TC-8.2.3** 每日成本条形图
  - 前置条件：有多天数据
  - 测试步骤：查看历史图表
  - 预期结果：每天一个条形，高度与成本成比例

- [ ] **TC-8.2.4** 条形图模型标注
  - 前置条件：有模型分拆数据
  - 测试步骤：查看图表
  - 预期结果：不同模型用不同颜色标注

### 8.3 定价表

- [ ] **TC-8.3.1** 定价表内容正确
  - 前置条件：无
  - 测试步骤：查看定价表
  - 预期结果：Opus/Sonnet/Haiku 的 input/output/cache 价格正确

- [ ] **TC-8.3.2** 官方定价链接可点击
  - 前置条件：无
  - 测试步骤：点击链接
  - 预期结果：打开 Anthropic 官方定价页面

### 8.4 模型价格计算

- [ ] **TC-8.4.1** Opus 4.6 定价正确
  - 前置条件：无
  - 测试步骤：检查 Opus 4.6 的 input=$5/M, output=$25/M
  - 预期结果：成本计算正确

- [ ] **TC-8.4.2** 前缀匹配模型名
  - 前置条件：模型名为 "claude-sonnet-4-6-20260101"
  - 测试步骤：查找定价
  - 预期结果：匹配到 claude-sonnet-4-6 的定价

- [ ] **TC-8.4.3** 未知模型返回 nil
  - 前置条件：模型名为 "gpt-5"
  - 测试步骤：查找定价
  - 预期结果：返回 nil，成本为 $0

---

## 9. 设置 (SettingsView)

### 9.1 自动刷新间隔

- [ ] **TC-9.1.1** 修改刷新间隔
  - 前置条件：打开设置
  - 测试步骤：拖动滑块修改间隔
  - 预期结果：值保存到 AppStorage，定时器重置

- [ ] **TC-9.1.2** 最小间隔 15 秒
  - 前置条件：打开设置
  - 测试步骤：将滑块拖到最小
  - 预期结果：间隔为 15 秒

- [ ] **TC-9.1.3** 最大间隔 10 分钟
  - 前置条件：打开设置
  - 测试步骤：将滑块拖到最大
  - 预期结果：间隔为 600 秒

### 9.2 自动切换配置

- [ ] **TC-9.2.1** 开关自动切换
  - 前置条件：打开设置
  - 测试步骤：切换 Auto Switch 开关
  - 预期结果：值保存到 AppStorage

- [ ] **TC-9.2.2** 修改切换阈值
  - 前置条件：自动切换已开启
  - 测试步骤：修改阈值
  - 预期结果：阈值保存，范围 10%-100%，步进 5%

### 9.3 其他设置

- [ ] **TC-9.3.1** 开机自启动
  - 前置条件：打开设置
  - 测试步骤：开启 "Launch at Login"
  - 预期结果：通过 SMAppService 注册启动项

- [ ] **TC-9.3.2** 关闭开机自启动
  - 前置条件：已开启自启动
  - 测试步骤：关闭开关
  - 预期结果：取消注册启动项

- [ ] **TC-9.3.3** About 页面显示版本信息
  - 前置条件：打开设置
  - 测试步骤：查看 About 区域
  - 预期结果：显示当前版本号和 build 号

- [ ] **TC-9.3.4** 手动检查更新按钮
  - 前置条件：打开设置
  - 测试步骤：点击 "Check for Updates"
  - 预期结果：触发手动更新检查，有结果则弹窗

---

## 10. 更新检查 (UpdateChecker)

### 10.1 版本检查

- [ ] **TC-10.1.1** 有新版本可用
  - 前置条件：GitHub Release 版本 > 当前版本
  - 测试步骤：手动检查更新
  - 预期结果：弹出更新提示，显示新版本号

- [ ] **TC-10.1.2** 已是最新版本
  - 前置条件：GitHub Release 版本 = 当前版本
  - 测试步骤：手动检查更新
  - 预期结果：弹窗 "Up to date"

- [ ] **TC-10.1.3** 静默检查无新版本不弹窗
  - 前置条件：已是最新版本
  - 测试步骤：应用启动时自动检查
  - 预期结果：无弹窗

- [ ] **TC-10.1.4** 语义版本比较正确
  - 前置条件：当前 1.2.3，最新 1.3.0
  - 测试步骤：比较版本
  - 预期结果：isNewer 返回 true

- [ ] **TC-10.1.5** 版本号位数不同的比较
  - 前置条件：当前 1.2，最新 1.2.1
  - 测试步骤：比较版本
  - 预期结果：isNewer 返回 true

### 10.2 错误处理

- [ ] **TC-10.2.1** GitHub API rate limit (403)
  - 前置条件：超过 API 限流
  - 测试步骤：手动检查更新
  - 预期结果：弹窗 "Rate Limit Exceeded"

- [ ] **TC-10.2.2** GitHub API rate limit (429)
  - 前置条件：超过 API 限流
  - 测试步骤：手动检查更新
  - 预期结果：弹窗 "Rate Limit Exceeded"

- [ ] **TC-10.2.3** 仓库无 Release (404)
  - 前置条件：GitHub 无任何 Release
  - 测试步骤：手动检查更新
  - 预期结果：弹窗 "No releases found on GitHub"

- [ ] **TC-10.2.4** 网络错误
  - 前置条件：断网
  - 测试步骤：手动检查更新
  - 预期结果：弹窗显示网络错误信息

- [ ] **TC-10.2.5** 静默检查失败不弹窗
  - 前置条件：断网 + 自动检查
  - 测试步骤：应用启动
  - 预期结果：无弹窗，静默失败

- [ ] **TC-10.2.6** 正在检查时不重复发起
  - 前置条件：正在检查中
  - 测试步骤：再次点击检查
  - 预期结果：被忽略（guard !isChecking）

### 10.3 下载与安装

- [ ] **TC-10.3.1** DMG 下载并打开
  - 前置条件：Release 包含 .dmg 附件
  - 测试步骤：点击 "Download & Install"
  - 预期结果：显示下载进度面板，下载完成后自动挂载 DMG

- [ ] **TC-10.3.2** 下载进度面板浮动显示
  - 前置条件：开始下载
  - 测试步骤：观察 UI
  - 预期结果：浮动面板显示 spinning indicator

- [ ] **TC-10.3.3** 无 DMG 时显示 "View Release"
  - 前置条件：Release 无 .dmg 附件
  - 测试步骤：更新提示弹窗
  - 预期结果：按钮文本为 "View Release"，点击打开浏览器

- [ ] **TC-10.3.4** 下载失败提示
  - 前置条件：下载中断
  - 测试步骤：等待下载
  - 预期结果：弹窗 "Download Failed"

- [ ] **TC-10.3.5** 下载完成后提示退出
  - 前置条件：下载成功
  - 测试步骤：查看弹窗
  - 预期结果：显示 "Quit CCSwitcher" 和 "Later" 按钮

- [ ] **TC-10.3.6** 已有旧下载文件时覆盖
  - 前置条件：Downloads 中已有 CCSwitcher_Update.dmg
  - 测试步骤：再次下载
  - 预期结果：旧文件被删除，新文件替换

---

## 11. Claude CLI 集成 (ClaudeService)

### 11.1 二进制发现

- [ ] **TC-11.1.1** /usr/local/bin/claude
  - 前置条件：claude 安装在 /usr/local/bin
  - 测试步骤：初始化 ClaudeService
  - 预期结果：claudePath = "/usr/local/bin/claude"

- [ ] **TC-11.1.2** Homebrew 路径 /opt/homebrew/bin/claude
  - 前置条件：通过 homebrew 安装
  - 测试步骤：初始化 ClaudeService
  - 预期结果：claudePath = "/opt/homebrew/bin/claude"

- [ ] **TC-11.1.3** nvm 管理的路径
  - 前置条件：通过 nvm 安装的 npm 全局包
  - 测试步骤：初始化 ClaudeService
  - 预期结果：找到 ~/.nvm/versions/node/<version>/bin/claude

- [ ] **TC-11.1.4** .npm-global 路径
  - 前置条件：npm prefix 设为 ~/.npm-global
  - 测试步骤：初始化 ClaudeService
  - 预期结果：找到 ~/.npm-global/bin/claude

- [ ] **TC-11.1.5** 所有路径都不存在时回退到 "claude"
  - 前置条件：所有已知路径都没有 claude
  - 测试步骤：初始化 ClaudeService
  - 预期结果：claudePath = "claude"（依赖 PATH）

### 11.2 PATH 注入

- [ ] **TC-11.2.1** claude 二进制所在目录加入 PATH
  - 前置条件：claude 在 ~/.nvm 下
  - 测试步骤：运行 CLI 命令
  - 预期结果：env PATH 包含 claude 所在目录

- [ ] **TC-11.2.2** 常见路径都注入 PATH
  - 前置条件：无
  - 测试步骤：检查 runClaude 的 env
  - 预期结果：PATH 包含 /opt/homebrew/bin、/usr/local/bin、~/.local/bin、~/.npm-global/bin

### 11.3 CLI 命令

- [ ] **TC-11.3.1** auth status 正常解析
  - 前置条件：Claude 已登录
  - 测试步骤：调用 `getAuthStatus()`
  - 预期结果：返回 AuthStatus，loggedIn=true，包含 email

- [ ] **TC-11.3.2** auth status JSON 解析失败
  - 前置条件：CLI 输出非 JSON
  - 测试步骤：调用 `getAuthStatus()`
  - 预期结果：抛出 invalidOutput 错误

- [ ] **TC-11.3.3** isClaudeAvailable 正确检测
  - 前置条件：claude 在 PATH 中
  - 测试步骤：调用 `isClaudeAvailable()`
  - 预期结果：返回 true

- [ ] **TC-11.3.4** isClaudeAvailable CLI 不存在
  - 前置条件：claude 不存在
  - 测试步骤：调用 `isClaudeAvailable()`
  - 预期结果：返回 false

### 11.4 防死锁

- [ ] **TC-11.4.1** 先读 pipe 再 waitUntilExit
  - 前置条件：CLI 输出大量数据
  - 测试步骤：运行 CLI 命令
  - 预期结果：不会因 pipe buffer 满而死锁

### 11.5 Login 轮询

- [ ] **TC-11.5.1** 检测 email 变更
  - 前置条件：当前登录 A，浏览器登录 B
  - 测试步骤：login() 轮询
  - 预期结果：检测到 email 从 A 变为 B，login 完成

- [ ] **TC-11.5.2** 检测 token 变更（同账号 re-login）
  - 前置条件：当前登录 A，浏览器重新登录 A
  - 测试步骤：login() 轮询
  - 预期结果：检测到 token 变化，login 完成

- [ ] **TC-11.5.3** 轮询间隔 2 秒
  - 前置条件：login 进行中
  - 测试步骤：观察日志时间戳
  - 预期结果：每 2 秒一次 poll

- [ ] **TC-11.5.4** 最长 120 秒超时
  - 前置条件：不完成 OAuth
  - 测试步骤：等待
  - 预期结果：60 次尝试后超时

- [ ] **TC-11.5.5** Task 取消支持
  - 前置条件：login 轮询中
  - 测试步骤：取消 Task
  - 预期结果：抛出 CancellationError，立即退出

---

## 12. 日志系统 (FileLogger)

### 12.1 基本功能

- [ ] **TC-12.1.1** 日志文件位置
  - 前置条件：应用运行
  - 测试步骤：检查 ~/Library/Logs/CCSwitcher.log
  - 预期结果：文件存在且包含日志

- [ ] **TC-12.1.2** 4 级日志输出
  - 前置条件：应用运行
  - 测试步骤：查看日志内容
  - 预期结果：包含 [INFO]、[WARN]、[ERROR]、[DEBUG] 标记

- [ ] **TC-12.1.3** ISO8601 时间戳带小数秒
  - 前置条件：有日志
  - 测试步骤：检查时间戳格式
  - 预期结果：格式如 "2026-04-09T12:34:56.789Z"

- [ ] **TC-12.1.4** Category 标签
  - 前置条件：有日志
  - 测试步骤：检查日志格式
  - 预期结果：包含 [AppState]、[Claude]、[Keychain] 等 category

### 12.2 日志轮转

- [ ] **TC-12.2.1** 超过 2MB 时轮转
  - 前置条件：日志文件 > 2MB
  - 测试步骤：重启应用
  - 预期结果：旧日志重命名为 CCSwitcher.log.old，新日志从空开始

- [ ] **TC-12.2.2** 保留一个旧日志文件
  - 前置条件：已有 .log.old
  - 测试步骤：再次轮转
  - 预期结果：旧 .old 被删除，新 .old 替换

### 12.3 写入模式

- [ ] **TC-12.3.1** 追加模式写入
  - 前置条件：日志文件已有内容
  - 测试步骤：写入新日志
  - 预期结果：新内容追加到末尾，不覆盖

- [ ] **TC-12.3.2** 文件不存在时自动创建
  - 前置条件：删除日志文件
  - 测试步骤：写入日志
  - 预期结果：自动创建新文件

- [ ] **TC-12.3.3** 异步写入不阻塞主线程
  - 前置条件：无
  - 测试步骤：高频写日志
  - 预期结果：UI 不卡顿（DispatchQueue 异步）

- [ ] **TC-12.3.4** 启动时写入 launch header
  - 前置条件：重启应用
  - 测试步骤：查看日志
  - 预期结果：包含 "====== CCSwitcher launched <timestamp> ======"

---

## 13. 促销系统 (MainMenuView + CCSwitcherApp)

### 13.1 Double Usage Banner

- [ ] **TC-13.1.1** 促销期内显示 banner
  - 前置条件：在 2026/3/13 ~ 2026/3/28 之间
  - 测试步骤：打开菜单
  - 预期结果：显示 Double Usage 促销 banner

- [ ] **TC-13.1.2** 促销期外不显示 banner
  - 前置条件：不在促销日期范围
  - 测试步骤：打开菜单
  - 预期结果：无促销 banner

- [ ] **TC-13.1.3** 本地时区转换显示
  - 前置条件：用户时区非 ET
  - 测试步骤：查看 banner
  - 预期结果：显示用户本地时区的激活时段

### 13.2 图标状态

- [ ] **TC-13.2.1** 促销激活时图标变化
  - 前置条件：Double Usage 激活
  - 测试步骤：观察菜单栏
  - 预期结果：图标从空心变为填充

- [ ] **TC-13.2.2** 促销非激活时恢复普通图标
  - 前置条件：Double Usage 非激活
  - 测试步骤：观察菜单栏
  - 预期结果：图标为空心

---

## 14. 数据模型与解析

### 14.1 Account 模型

- [ ] **TC-14.1.1** Account 序列化/反序列化
  - 前置条件：创建 Account 对象
  - 测试步骤：编码为 JSON 再解码
  - 预期结果：所有字段保持一致

- [ ] **TC-14.1.2** AIProviderType 枚举
  - 前置条件：无
  - 测试步骤：检查所有 case
  - 预期结果：claudeCode、gemini、codex 各有正确 iconName 和 configDirectory

### 14.2 UsageData 模型

- [ ] **TC-14.2.1** UsageAPIResponse 解码
  - 前置条件：API 返回 JSON
  - 测试步骤：解码 JSON
  - 预期结果：fiveHour、sevenDay、extraUsage 正确解析

- [ ] **TC-14.2.2** resetsAt ISO8601 解析
  - 前置条件：resetsAt 为 ISO8601 字符串
  - 测试步骤：调用 resetsAtDate
  - 预期结果：正确解析为 Date

- [ ] **TC-14.2.3** resetsAt 无小数秒的 ISO8601
  - 前置条件：resetsAt 不含 fractionalSeconds
  - 测试步骤：调用 resetsAtDate
  - 预期结果：回退格式解析成功

### 14.3 AnyCodable

- [ ] **TC-14.3.1** 支持 Bool、Int、Double、String 编解码
  - 前置条件：无
  - 测试步骤：编解码各类型
  - 预期结果：值保持不变

- [ ] **TC-14.3.2** 支持嵌套 Array 和 Dictionary
  - 前置条件：复杂 JSON 结构
  - 测试步骤：编解码
  - 预期结果：嵌套结构正确

- [ ] **TC-14.3.3** NSNull 处理
  - 前置条件：JSON 中有 null 值
  - 测试步骤：解码
  - 预期结果：value 为 NSNull

### 14.4 CachedUsageEntry

- [ ] **TC-14.4.1** effectiveSessionUtilization 窗口未过期
  - 前置条件：fiveHour.resetsAt 在未来
  - 测试步骤：调用方法
  - 预期结果：返回原始 utilization 值

- [ ] **TC-14.4.2** effectiveSessionUtilization 窗口已过期
  - 前置条件：fiveHour.resetsAt 已过
  - 测试步骤：调用方法
  - 预期结果：返回 0.0

- [ ] **TC-14.4.3** effectiveWeeklyUtilization 窗口已过期
  - 前置条件：sevenDay.resetsAt 已过
  - 测试步骤：调用方法
  - 预期结果：返回 0.0

---

## 15. 持久化

### 15.1 UserDefaults

- [ ] **TC-15.1.1** 账号列表持久化
  - 前置条件：有账号
  - 测试步骤：重启应用
  - 预期结果：账号列表恢复

- [ ] **TC-15.1.2** 用量缓存持久化
  - 前置条件：有缓存数据
  - 测试步骤：重启应用
  - 预期结果：缓存数据恢复

- [ ] **TC-15.1.3** AppStorage 设置持久化
  - 前置条件：修改了刷新间隔、自动切换等
  - 测试步骤：重启应用
  - 预期结果：所有设置保持

### 15.2 自动创建首个账号

- [ ] **TC-15.2.1** 无账号但 CLI 已登录时自动创建
  - 前置条件：accounts 为空，CLI 有登录状态
  - 测试步骤：启动应用
  - 预期结果：自动创建账号并捕获凭据

- [ ] **TC-15.2.2** 已有账号时不自动创建
  - 前置条件：accounts 非空
  - 测试步骤：启动应用
  - 预期结果：不创建新账号

---

## 统计

| 模块 | 测试用例数 |
|------|-----------|
| 1. 应用生命周期 | 16 |
| 2. 账号管理 | 27 |
| 3. 自动切换 | 11 |
| 4. 用量获取 | 17 |
| 5. Token 管理 | 22 |
| 6. 健康诊断 | 6 |
| 7. Usage Dashboard | 16 |
| 8. 成本详情 | 10 |
| 9. 设置 | 8 |
| 10. 更新检查 | 16 |
| 11. Claude CLI 集成 | 13 |
| 12. 日志系统 | 8 |
| 13. 促销系统 | 4 |
| 14. 数据模型与解析 | 10 |
| 15. 持久化 | 5 |
| 16. 中转站账号 (Relay) | 5 |
| **总计** | **194** |

---

## 16. 中转站账号 (Relay)

- [ ] **TC-16.1** 添加中转站 + 测试连接
  - 前置条件：有可用中转站 baseURL + token（xtoken claude0.18/1.2/1.5 渠道）
  - 测试步骤：Accounts → Add Relay Station → 填名称/baseURL/token → Test → Save
  - 预期结果：Test 显示 `✓ Connected — token accepted`；保存后列表出现该条目（network 图标 + host 副标题 + Relay 标签）；baseURL 误填尾缀 `/v1` 时自动纠正；编辑字段后旧测试结果自动清除

- [ ] **TC-16.2** 切换到中转站
  - 前置条件：TC-16.1 完成，当前 active 为官方账号
  - 测试步骤：点中转站条目的 Switch → 打开**新终端**跑 `claude -p "reply ok"` → 检查 `~/.claude/settings.json` 与 keychain
  - 预期结果：app 内该条目变 Active；settings.json env 出现两键且其余键（hooks/permissions 等）原样；`security find-generic-password -s "Claude Code-credentials" -w` 报 not found；`~/.claude.json` 无 oauthAccount；新终端 claude 正常出字（走中转站）

- [ ] **TC-16.3** 切回官方账号
  - 前置条件：TC-16.2 完成
  - 测试步骤：点官方账号 Switch → 新终端 `claude -p "reply ok"`
  - 预期结果：env 两键消失、keychain token 与 oauthAccount 恢复、用量数据恢复显示；新终端走官方

- [ ] **TC-16.4** 删除 active 中转站
  - 测试步骤：切到中转站后点其 trash 按钮
  - 预期结果：OS 槽位先切到其它账号（或最后一个账号时清空 env 两键）再删除；不残留指向已删 token 的 env

- [ ] **TC-16.5** 外部 env 不认识时不冒认
  - 测试步骤：手工在 settings.json env 写一对 app 不认识的 BASE_URL/AUTH_TOKEN → app refresh
  - 预期结果：active 显示为空（"No account connected"），不错认成任何已存账号；从该状态点任意账号 Switch 能正常切出
