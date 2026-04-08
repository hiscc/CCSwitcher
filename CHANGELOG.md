# CCSwitcher Changelog

## Unreleased (current working changes)

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
