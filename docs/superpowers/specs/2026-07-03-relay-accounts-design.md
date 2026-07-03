# 中转站账号（Relay）设计

日期：2026-07-03 · 状态：已实测机制，待用户确认后出实现计划

## 目的

官方订阅额度有限，用户持有 Anthropic 兼容中转站（如 xtoken）。让中转站与官方 OAuth 账号进入同一个切换器：添加（名称 + baseURL + token）→ 点击切换 → cc 走中转站；再点击切回官方账号。

## 已验证事实（2026-07-03 实测，xtoken `api.xtokenmirror.com`）

1. **注入机制**：`ANTHROPIC_BASE_URL`（改端点）+ `ANTHROPIC_AUTH_TOKEN`（自动加 `Bearer ` 前缀）。GUI app 无法注入 shell env，持久注入点 = `~/.claude/settings.json` 的 `env` 块（官方文档确认对每个新会话生效）。
2. xtoken 原生支持 `POST {base}/v1/messages`，`Authorization: Bearer` 和 `x-api-key` 两种头均可，模型名 `claude-opus-4-8` 直接可用。cc 用的 base 是 **主机根**（`https://api.xtokenmirror.com`，无 `/v1` 尾缀——cc 自己拼 `/v1/messages`）。
3. `claude -p` 实测：env 两键存在时请求**只走中转站**——故意用假 token 得 `401 Invalid API key`，**不回落 keychain OAuth**。
4. `--settings` 文件的 `env` 块注入同样生效（与写 settings.json 等价的通道），返回正常。
5. **未验证**：交互式 TUI 下 `AUTH_TOKEN` 与 OAuth 登录态并存的行为（文档只写 `ANTHROPIC_API_KEY` 会弹一次审批；`AUTH_TOKEN` 未文档化）。下面的方案 B 使这个未知不影响正确性。
6. 不用 `ANTHROPIC_API_KEY`：文档明确它在交互模式要用户审批一次才覆盖订阅。

## 方案：互斥式（B）

OS 层任意时刻只表达一个身份（与项目铁律「底层只有一个真相源」一致）：

- **切到中转站**：备份当前官方账号（现有 switchAccount Step 1）→ 清 keychain token + `~/.claude.json` 的 `oauthAccount` → settings.json `env` 写入 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` 两键（读-改-写，保留其它所有键）→ 回读验证，失败按 snapshot 回滚（snapshot 含 env 两键旧值）。
- **切回官方**：删 env 两键 → 走现有 vault 恢复流程（keychain + oauthAccount 写入 + 回读验证）。
- **中转 → 中转**：只重写 env 两键。
- 官方 token 长期闲置过期：现有 `refreshAccessToken` 在切换时自动续，已有兜底。

**为何选 B 不选叠加式（A，只写 env 不动 OAuth 槽位）**：A 依赖「env 覆盖 OAuth」这一未文档化优先级（-p 模式已实测成立，但交互式未验证、版本升级可能变）；A 让 OS 层同时表达两个身份，active 派生要在 app 里硬编码假设。B 全部基于自己写入/删除的状态，无赌注。

（C：`apiKeyHelper` 脚本方案——多一层 shell 脚本依赖，过度设计，排除。）

## 数据模型

- `AccountBackup` 增加可选字段 `relay: RelayInfo?`（`{ name, baseURL }`）；token 复用现有 `token` 字段存中转站 key。旧条目解码为 `nil` = 官方账号，向后兼容，无迁移。
- `Account` 增加 `baseURL: String?`（nil = 官方）；`isRelay` 由它派生；`provider` 保持 `.claudeCode`（仍是给 cc 用的）。
- vault 仍是唯一身份真相源；`reconcileAccountsWithVault` 增加 relay 分支（displayName = 用户起的名称，副标题 = host）。

## active 派生

`getAuthStatus` 扩展：

1. 先读 settings.json env 两键：命中且与某 relay 条目的 baseURL + token 相等 → 该中转站 active。
2. 有键但与所有 relay 条目不匹配 → 按现有「外部登录了不认识的账号」先例处理，清 active。
3. 无键 → 现有 keychain/oauthAccount email 匹配逻辑不变。

## 用量与自动切换

- v1 中转站**不取用量**（各站 API 非标：new-api/one-api 各自造），UI 显示「中转站 · 无用量数据」；`fetchAllAccountUsage` 跳过 relay。
- auto-switch 候选**排除**中转站（无 utilization 可比较）；「官方全部超阈值时兜底切中转站」留 v2 再议。

## UI

- 菜单增加「添加中转站」：表单 = 名称 / baseURL / token +「测试连接」按钮（`POST {base}/v1/messages`，`max_tokens: 1`；404 时自动尝试剥掉用户误填的尾缀 `/v1` 再探，成功则提示纠正后的 base）。
- 列表：relay 专属图标 + host 副标题；编辑 / 删除与官方账号一致。

## 边界与风险

- settings.json **读-改-写只动两键**，原子写入，绝不整文件重建（该文件含大量 hooks/permissions/plugins 配置，重建即灾难）。复用 `~/.claude.json` 已有的 AnyCodable 读改写模式。
- env 只对**新开的 cc 会话**生效，正在跑的会话不受影响（与现有 OAuth 切换语义一致，无新增坑）。
- 「测试连接」只验证连通 + token 有效，**不验证 tool-calling 透传**；cc 强依赖 tools。旧基准（OpenAI 端点）显示 xtoken 的 claude0.6 / claude1.0 渠道不透传 forced tool，建议优先 claude0.18 / 1.2 / 1.5 渠道的 token。
- 用户此前手工在 settings.json 配过 relay env 的「导入」：v1 不做，active 派生按第 2 条「不认识的账号」处理。

## 测试

- 单元：settings.json 读改写保留无关键；`AccountBackup` 新旧两种 JSON 均可解码。
- 手动（增补 FUNCTIONAL_TESTS.md）：添加中转站 → 测试连接 → 切换 → 新终端 `claude` 实际走中转（`/status` 或对话验证）→ 切回官方 → keychain/oauthAccount 恢复、env 两键消失、原会话不受影响。
