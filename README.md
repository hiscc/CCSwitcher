# CCSwitcher

[English](#english) | [中文](#中文)

---

<a id="english"></a>

A macOS menu bar app for securely switching between multiple Claude Code accounts.

## The Problem

Claude Code Pro subscriptions come with usage caps — a 5-hour session limit and a 7-day weekly limit. Heavy users hit these walls regularly.

The official CLI offers no multi-account support. Switching means running `claude auth login` repeatedly, and OAuth tokens expire every 1–2 hours. Managing multiple accounts manually is painful.

Existing tools (CCS, claude-swap, cc-account-switcher, etc.) solve this by **copying credential files** between disk locations. This works, but has real drawbacks:

| | File-copy tools | CCSwitcher |
|---|---|---|
| **Storage** | Plain-text JSON on disk | macOS Keychain (encrypted) |
| **Atomicity** | Multi-file sync, can corrupt on crash | OS-level atomic operations |
| **Token refresh** | Manual re-login when expired | Delegated to CLI, fully automatic |
| **Access control** | Any process can read credential files | System-level keychain permissions |

## How CCSwitcher Works

CCSwitcher stores all credentials in the **macOS Keychain** and delegates token lifecycle to the official Claude CLI.

- **One-click switching**: Pick an account from the menu bar, done.
- **Usage monitoring**: Real-time session and weekly quota for every account.
- **Auto-switch**: When the active account hits a configurable threshold (default 90%), automatically switch to the least-used account.
- **Silent token refresh**: When a token expires, CCSwitcher runs `claude auth status` in the background — the CLI refreshes the token internally and writes it back to the Keychain. Zero interaction required.

## Demo

https://github.com/XueshiQiao/CCSwitcher/raw/main/assets/CCSwitcher-screen-high-quality-1.1.0.mp4

## Features

- Multi-account management with one-click switching
- Real-time usage dashboard (session / weekly limits)
- Auto-switch on configurable usage threshold
- Zero-interaction token refresh
- Privacy masking for emails and account names
- Activity stats and cost tracking
- Native SwiftUI menu bar experience
- Universal binary (Apple Silicon + Intel)
- In-app updates via GitHub Releases

## Quick Start

### Install

Download the latest `.dmg` from [GitHub Releases](https://github.com/hiscc/CCSwitcher/releases), open it, and drag CCSwitcher to `/Applications`.

> ⚠️ This build is unsigned. On first launch, right-click → Open, or go to **System Settings → Privacy & Security → Open Anyway**.

### Add Your First Account

1. Click the CCSwitcher icon in the menu bar
2. Click **"Add Account"**
3. Your browser opens for OAuth — sign in with your Claude account
4. Done. The account appears in the menu bar dropdown.

### Switch Accounts

Click any account in the dropdown. CCSwitcher backs up the current credentials, restores the target account's credentials from Keychain, and verifies the switch — all in under a second.

### Enable Auto-Switch

Open **Settings → Auto-Switch**, toggle it on, and set your threshold (e.g., 90%). When the active account's usage exceeds this level, CCSwitcher automatically switches to the account with the most remaining quota.

<details>
<summary><strong>Architecture Details</strong></summary>

### Minimalist Login Flow

CCSwitcher uses native `Process` + `Pipe()` to run `claude auth login` in the background. The CLI detects the non-interactive environment and launches the system browser for OAuth automatically. No pseudoterminal (PTY) complexity needed.

### Delegated Token Refresh

Inspired by [CodexBar](https://github.com/lucas-clemente/codexbar). When the Usage API returns `HTTP 401`, CCSwitcher runs `claude auth status` silently. The official CLI wakes up, realizes the token is expired, negotiates a fresh one, and writes it back to the Keychain. CCSwitcher re-reads and retries — fully automatic.

### Keychain Reader via Security CLI

Reading from the Keychain via `Security.framework` (`SecItemCopyMatching`) from a background menu bar app triggers blocking system prompts. Instead, CCSwitcher calls `/usr/bin/security find-generic-password` — a system binary that the user can "Always Allow" once, permanently silencing future prompts.

### Settings Window Workaround

Pure menu bar apps (`LSUIElement = true`) can't present SwiftUI `Settings` windows due to a macOS bug. CCSwitcher creates a hidden 1×1 pixel off-screen window to trick SwiftUI into believing an active scene exists, enabling the native Settings window. Adapted from [CodexBar](https://github.com/lucas-clemente/codexbar).

</details>

## Credits

- [CodexBar](https://github.com/lucas-clemente/codexbar) — Delegated token refresh pattern, keychain reader strategy, and settings window workaround.

## License

MIT

---

<a id="中文"></a>

# CCSwitcher

[English](#english) | [中文](#中文)

一款 macOS 菜单栏应用，安全切换多个 Claude Code 账号。

## 要解决的问题

Claude Code Pro 订阅有用量上限 — 5 小时会话限制 + 7 天周限额。重度用户经常撞墙。

官方 CLI 不支持多账号。切换意味着反复执行 `claude auth login`，而且 OAuth token 每 1-2 小时就过期，手动管理多个账号非常痛苦。

现有工具（CCS、claude-swap、cc-account-switcher 等）通过**拷贝凭证文件**来切换账号。能用，但有明显缺陷：

| | 文件拷贝方案 | CCSwitcher |
|---|---|---|
| **存储方式** | 明文 JSON 存磁盘 | macOS 钥匙串加密存储 |
| **原子性** | 多文件同步，崩溃可能损坏 | 系统级原子操作 |
| **Token 刷新** | 过期后需手动重新登录 | 委托 CLI 自动静默刷新 |
| **访问控制** | 任何进程都能读取凭证文件 | 系统级钥匙串权限管控 |

## CCSwitcher 如何工作

CCSwitcher 将所有凭证存储在 **macOS 钥匙串**中，并将 token 生命周期管理委托给官方 Claude CLI。

- **一键切换**：菜单栏点击即切，无需终端操作。
- **用量监控**：实时显示每个账号的会话和周限额。
- **自动切换**：当前账号用量达到阈值（默认 90%）时，自动切换到最空闲的账号。
- **静默刷新**：token 过期时，CCSwitcher 在后台运行 `claude auth status`，CLI 自动续期并写回钥匙串，全程零人工干预。

## 演示

https://github.com/XueshiQiao/CCSwitcher/raw/main/assets/CCSwitcher-screen-high-quality-1.1.0.mp4

## 功能特性

- 多账号管理，一键切换
- 实时用量仪表盘（会话 / 周限额）
- 可配置阈值的自动切换
- 零交互 token 刷新
- 隐私脱敏（邮箱、账号名自动遮挡）
- 活动统计与成本追踪
- 原生 SwiftUI 菜单栏体验
- 通用二进制（Apple Silicon + Intel）
- 内置更新检查（GitHub Releases）

## 快速开始

### 安装

从 [GitHub Releases](https://github.com/hiscc/CCSwitcher/releases) 下载最新 `.dmg`，打开后将 CCSwitcher 拖入 `/Applications`。

> ⚠️ 当前构建未签名。首次打开请右键 → 打开，或前往**系统设置 → 隐私与安全性 → 仍要打开**。

### 添加第一个账号

1. 点击菜单栏中的 CCSwitcher 图标
2. 点击**「添加账号」**
3. 浏览器自动打开 OAuth 登录页 — 登录你的 Claude 账号
4. 完成。账号出现在菜单栏下拉列表中。

### 切换账号

在下拉列表中点击目标账号。CCSwitcher 自动备份当前凭证、从钥匙串恢复目标账号凭证、验证切换结果 — 整个过程不到一秒。

### 启用自动切换

打开**设置 → 自动切换**，开启开关并设置阈值（如 90%）。当活跃账号用量超过此比例，CCSwitcher 自动切换到剩余额度最多的账号。

<details>
<summary><strong>架构细节</strong></summary>

### 极简登录流程

CCSwitcher 使用原生 `Process` + `Pipe()` 在后台运行 `claude auth login`。CLI 检测到非交互环境后自动启动系统浏览器完成 OAuth，无需复杂的伪终端（PTY）。

### 委托式 Token 刷新

灵感来自 [CodexBar](https://github.com/lucas-clemente/codexbar)。当用量 API 返回 `HTTP 401` 时，CCSwitcher 静默运行 `claude auth status`，官方 CLI 发现 token 过期后自动协商新 token 并写回钥匙串，CCSwitcher 重新读取后自动重试 — 全程自动。

### 通过 Security CLI 读取钥匙串

从后台菜单栏应用通过 `Security.framework`（`SecItemCopyMatching`）读取钥匙串会触发系统弹窗。CCSwitcher 改为调用 `/usr/bin/security find-generic-password` — 用户只需在首次允许时点击「始终允许」，后续所有后台轮询完全静默。

### 设置窗口变通方案

纯菜单栏应用（`LSUIElement = true`）由于 macOS bug 无法弹出 SwiftUI `Settings` 窗口。CCSwitcher 创建一个隐藏的 1×1 像素屏幕外窗口，欺骗 SwiftUI 认为存在活跃场景，从而正常打开原生设置窗口。方案来自 [CodexBar](https://github.com/lucas-clemente/codexbar)。

</details>

## 致谢

- [CodexBar](https://github.com/lucas-clemente/codexbar) — 委托式 token 刷新、钥匙串读取策略、设置窗口变通方案。

## 许可证

MIT
