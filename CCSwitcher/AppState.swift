import SwiftUI
import AppKit
import Combine

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var activeAccount: Account?
    /// Single source of truth for per-account usage. See `UsageState` enum.
    /// Replaces the trio (`accountUsage` + `cachedUsage` + `accountUsageErrors`) that
    /// used to require manual sync and routinely diverged.
    @Published var usage: [UUID: UsageState] = [:]
    @Published var usageSummary: UsageSummary = .empty
    @Published var recentActivity: [DailyActivity] = []
    @Published var activeSessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var isLoggingIn = false
    /// Non-nil while a native OAuth login waits for the user to paste the code.
    /// Drives the paste-code UI and the "Reopen Page" action.
    @Published var pendingAuthURL: URL?
    @Published var errorMessage: String?
    @Published var lastUsageRefresh: Date?
    @Published var costSummary: CostSummary = .empty
    @Published var activityStats: ActivityStats = .empty

    /// Persisted usage cache (only-grows). Not `@Published` — Views read `usage` instead;
    /// this is internal storage used by `fetchOneAccountUsage` as a fallback source and
    /// for cross-launch warm-start.
    private var cachedUsage: [UUID: CachedUsageEntry] = [:]

    /// Whether auto-switch is enabled (persisted via AppStorage in SettingsView)
    @AppStorage("autoSwitchEnabled") var autoSwitchEnabled = false
    /// Usage threshold (0-100) that triggers auto-switch
    @AppStorage("autoSwitchThreshold") var autoSwitchThreshold = 90

    // MARK: - Services

    private let claudeService = ClaudeService.shared
    private let statsParser = StatsParser.shared
    private let costParser = CostParser.shared
    private let activityParser = ActivityParser.shared
    private let keychain = KeychainService.shared
    private let relaySettings = RelaySettingsService.shared

    private let accountsKey = "com.ccswitcher.accounts"
    private let usageCacheKey = "com.ccswitcher.usageCache"
    private var refreshTimer: Timer?
    var loginTask: Task<Void, Never>?
    private var lastAutoSwitchTime: Date?
    private let autoSwitchCooldown: TimeInterval = 600
    /// Track recently-abandoned accounts with timestamps to prevent multi-account oscillation
    private var recentlyAbandonedAccounts: [UUID: Date] = [:]
    /// How long an abandoned account stays deprioritized
    private let abandonedCooldown: TimeInterval = 1800

    // MARK: - Initialization

    init() {
        log.info("[init] Loading accounts...")
        // Load any persisted UI metadata (lastUsed / subscriptionType). Identity fields
        // (email/orgName/...) on these stale records will be overwritten by the vault.
        loadAccounts()
        // Vault is the source of truth for account identity. Rebuild the list so any
        // additions/removals/identity-changes done outside this AppState lifecycle (e.g.
        // backup imported, oauthAccount updated by a previous switch) are reflected.
        reconcileAccountsWithVault()
        loadUsageCache()
        // Pre-populate `usage` from persisted cache so UI renders immediately on launch
        // (stale until the first refresh completes).
        for (id, entry) in cachedUsage {
            usage[id] = .stale(entry.usage, fetchedAt: entry.fetchedAt, reason: "Cached from last session")
        }

        log.info("[init] Loaded \(self.accounts.count) accounts, \(self.cachedUsage.count) cached, active: \(self.activeAccount?.id.uuidString ?? "none")")
    }

    /// Rebuild `accounts` from the vault (single source of truth for identity).
    /// - Adds any account present in vault but missing locally
    /// - Updates email/orgName/displayName from vault.oauthAccount,
    ///   subscriptionType from the vault token JSON (falls back to the persisted
    ///   value only when an old token JSON lacks the field)
    /// - Removes any local account that has no vault entry (orphan)
    /// - Preserves `lastUsed` (the only field the vault doesn't have)
    private func reconcileAccountsWithVault() {
        let vault = keychain.allBackups()
        let vaultIds: [(UUID, AccountBackup)] = vault.compactMap { (idStr, backup) in
            guard let id = UUID(uuidString: idStr) else { return nil }
            return (id, backup)
        }
        let vaultIdSet = Set(vaultIds.map { $0.0 })

        // 1. Drop orphans (local account with no vault entry)
        let beforeCount = accounts.count
        accounts.removeAll { !vaultIdSet.contains($0.id) }
        if accounts.count != beforeCount {
            log.warning("[reconcile] Dropped \(beforeCount - self.accounts.count) orphan account(s) with no vault backup")
        }

        // 2. Update existing + add missing
        for (id, backup) in vaultIds {
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
            let oauth = backup.oauthAccount
            let email = (oauth["emailAddress"]?.value as? String) ?? ""
            let orgName = oauth["organizationName"]?.value as? String
            let subscriptionType = ClaudeService.extractSubscriptionType(from: backup.token)

            if let idx = accounts.firstIndex(where: { $0.id == id }) {
                // Log any email/org drift between persisted UI metadata and vault
                // (vault wins — but tell the user when their displayed identity changes).
                if !accounts[idx].email.isEmpty && accounts[idx].email != email {
                    log.warning("[reconcile] Email drift for \(id): UI had '\(self.accounts[idx].email)', vault has '\(email)' — using vault")
                }
                accounts[idx].email = email
                accounts[idx].orgName = orgName
                accounts[idx].displayName = orgName ?? email
                if let subscriptionType {
                    accounts[idx].subscriptionType = subscriptionType
                }
            } else {
                let account = Account(
                    id: id,
                    email: email,
                    displayName: orgName ?? email,
                    provider: .claudeCode,
                    orgName: orgName,
                    subscriptionType: subscriptionType,
                    isActive: false,
                    lastUsed: nil
                )
                accounts.append(account)
                log.info("[reconcile] Added account \(email) (id=\(id)) from vault")
            }
        }

        // Restore active flag from existing data (setActiveAccount has source-of-truth
        // logic via OS layer in updateActiveAccount, called later in refresh())
        if let active = activeAccount {
            setActiveAccount(id: active.id)
        }

        saveAccounts()
    }

    // MARK: - Refresh

    /// When true, `refresh()` skips `autoSwitchIfNeeded()` to prevent recursion.
    private var isAutoSwitching = false

    private var isRefreshing = false

    /// Public refresh entry point. Skipped while a login flow is in progress so the
    /// transient state during OAuth doesn't get observed. Login flows should call
    /// `performRefresh()` directly when they need a guaranteed post-login refresh.
    func refresh() async {
        guard !isLoggingIn else {
            log.info("[refresh] Skipping: login in progress")
            return
        }
        await performRefresh()
    }

    /// Actual refresh body. Bypasses the `isLoggingIn` guard so login flows can call it
    /// directly without the brittle "set isLoggingIn=false early so refresh() doesn't skip"
    /// dance — that pattern opens a race window where a concurrent task can observe
    /// isLoggingIn=false mid-flight.
    private func performRefresh() async {
        guard !isRefreshing else {
            log.info("[refresh] Skipping: already refreshing")
            return
        }
        isRefreshing = true
        isLoading = true
        defer { isLoading = false; isRefreshing = false }
        errorMessage = nil

        // Re-derive accounts BEFORE getAuthStatus so updateActiveAccount can find any
        // vault entry added externally (otherwise it'd see "logged-in but unmanaged"
        // and clear active state for an account that's actually in the vault).
        reconcileAccountsWithVault()

        updateActiveAccount(from: claudeService.getAuthStatus())

        // Passive token health check (no CLI calls, keychain reads only)
        diagnoseTokenHealth()

        // Fetch usage limits for all accounts
        await fetchAllAccountUsage()
        lastUsageRefresh = Date()

        // Auto-switch when current account exceeds threshold (skip if called from switchTo during auto-switch)
        if !isAutoSwitching {
            await autoSwitchIfNeeded()
        }

        usageSummary = statsParser.getUsageSummary()
        recentActivity = statsParser.getRecentActivity(days: 7)
        activeSessions = statsParser.getActiveSessions()

        // Heavy JSONL parsing off main thread
        let parser = costParser
        let actParser = activityParser
        let cost = await Task.detached { parser.getCostSummary() }.value
        let activity = await Task.detached { actParser.getTodayStats() }.value
        costSummary = cost
        activityStats = activity

        log.info("[refresh] Usage: weekly=\(self.usageSummary.weeklyMessages) msgs, \(self.activeSessions.count) active sessions, today=$\(String(format: "%.2f", cost.todayCost)) turns=\(activity.conversationTurns)")
    }

    func startAutoRefresh(interval: TimeInterval = 300) {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Account Management

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        clearPendingLogin()
        log.info("[cancelLogin] Login cancelled by user")
    }

    /// Single source of truth for active account state. Reconciles `accounts[i].isActive`
    /// flags with `activeAccount` reference so they can never diverge. All other code
    /// MUST go through this helper instead of mutating `isActive` directly.
    private func setActiveAccount(id: UUID?) {
        for i in accounts.indices {
            accounts[i].isActive = (accounts[i].id == id)
        }
        if let id {
            activeAccount = accounts.first(where: { $0.id == id })
        } else {
            activeAccount = nil
        }
    }

    func addAccount() async {
        log.info("[addAccount] Starting add current account flow...")
        let status = claudeService.getAuthStatus()
        guard status.loggedIn, let email = status.email else {
            errorMessage = "Not logged in to Claude. Use Login New Account instead."
            log.error("[addAccount] Aborted: not logged in")
            return
        }
        log.info("[addAccount] Current auth: logged in, sub=\(status.subscriptionType ?? "nil")")

        if accounts.contains(where: { $0.email == email }) {
            errorMessage = "Account already exists"
            log.warning("[addAccount] Aborted: duplicate account")
            return
        }

        let account = Account(
            email: email,
            displayName: status.orgName ?? email,
            provider: .claudeCode,
            orgName: status.orgName,
            subscriptionType: status.subscriptionType,
            isActive: false
        )
        log.info("[addAccount] Created account model, id=\(account.id)")

        let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString, expectedEmail: email)
        if !captured {
            errorMessage = "Could not capture auth token from keychain"
            log.error("[addAccount] Token capture failed!")
            return
        }

        let isFirst = accounts.isEmpty
        accounts.append(account)
        if isFirst {
            setActiveAccount(id: account.id)
            log.info("[addAccount] First account, setting as active")
        }
        saveAccounts()
        log.info("[addAccount] Account saved. Total accounts: \(self.accounts.count)")
    }

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

    // MARK: - Browser Login (native OAuth — no CLI in the critical path)

    private var pendingOAuth: PendingOAuth?
    private var pendingReauthAccountId: UUID?

    func startLoginNewAccount() {
        startBrowserLogin(reauthFor: nil)
    }

    func startReauthenticate(_ account: Account) {
        startBrowserLogin(reauthFor: account)
    }

    /// Begin a native OAuth browser login: back up the current account, open the
    /// authorize page, then wait for the user to paste the code (`submitAuthCode`).
    private func startBrowserLogin(reauthFor account: Account?) {
        guard !isLoggingIn else {
            log.info("[browserLogin] Already logging in, skipping")
            return
        }
        log.info("[browserLogin] ===== Starting (\(account.map { "reauth \($0.email)" } ?? "new account")) =====")
        errorMessage = nil

        // Back up the current account before the new login overwrites the OS slot
        if let current = activeAccount {
            let backed = claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString, expectedEmail: current.email)
            log.info("[browserLogin] Backup of \(current.email): \(backed)")
        } else {
            log.info("[browserLogin] No active account, skipping backup")
        }

        let pending = claudeService.beginNativeOAuth()
        pendingOAuth = pending
        pendingReauthAccountId = account?.id
        pendingAuthURL = pending.authorizeURL
        isLoggingIn = true
        NSWorkspace.shared.open(pending.authorizeURL)
    }

    func reopenAuthPage() {
        if let url = pendingAuthURL { NSWorkspace.shared.open(url) }
    }

    private func clearPendingLogin() {
        pendingOAuth = nil
        pendingReauthAccountId = nil
        pendingAuthURL = nil
        isLoggingIn = false
    }

    /// Complete the pending browser login with the code pasted from the callback page.
    /// On failure the pending state is kept so the user can fix the paste and retry.
    func submitAuthCode(_ pastedCode: String) async {
        guard let pending = pendingOAuth else {
            log.warning("[browserLogin] submitAuthCode with no pending login")
            return
        }
        log.info("[browserLogin] Submitting authorization code...")
        errorMessage = nil

        do {
            let result = try await claudeService.completeNativeOAuth(pastedCode: pastedCode, pending: pending)
            log.info("[browserLogin] Logged in as \(result.email)")

            if let reauthId = pendingReauthAccountId {
                // Re-auth: the result must match the target account
                guard let index = accounts.firstIndex(where: { $0.id == reauthId }) else {
                    log.error("[browserLogin] Reauth target account vanished")
                    clearPendingLogin()
                    return
                }
                guard result.email == accounts[index].email else {
                    errorMessage = "Logged in as \(result.email), but expected \(accounts[index].email). Sign in with that account, then paste the new code."
                    log.error("[browserLogin] Reauth email mismatch: got \(result.email)")
                    return
                }
                _ = claudeService.captureCurrentCredentials(forAccountId: accounts[index].id.uuidString, expectedEmail: result.email)
                usage.removeValue(forKey: accounts[index].id)
                accounts[index].orgName = result.orgName
                accounts[index].subscriptionType = result.subscriptionType
                setActiveAccount(id: reauthId)
                saveAccounts()
            } else if let existing = accounts.firstIndex(where: { $0.email == result.email }) {
                // Duplicate of an existing account — refresh its credentials
                log.info("[browserLogin] Account already exists, refreshing backup")
                _ = claudeService.captureCurrentCredentials(forAccountId: accounts[existing].id.uuidString, expectedEmail: result.email)
                usage.removeValue(forKey: accounts[existing].id)
                setActiveAccount(id: accounts[existing].id)
                saveAccounts()
            } else {
                // Brand-new account
                let account = Account(
                    email: result.email,
                    displayName: result.orgName ?? result.email,
                    provider: .claudeCode,
                    orgName: result.orgName,
                    subscriptionType: result.subscriptionType,
                    isActive: false
                )
                let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString, expectedEmail: result.email)
                guard captured else {
                    errorMessage = "Could not capture credentials"
                    log.error("[browserLogin] Capture failed!")
                    clearPendingLogin()
                    return
                }
                accounts.append(account)
                setActiveAccount(id: account.id)
                saveAccounts()
                log.info("[browserLogin] New account active. Total: \(self.accounts.count)")
            }

            clearPendingLogin()
            await performRefresh()
            log.info("[browserLogin] ===== Login completed =====")
        } catch is CancellationError {
            log.info("[browserLogin] Cancelled")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[browserLogin] Error: \(error.localizedDescription)")
        }
    }

    func removeAccount(_ account: Account) async {
        log.info("[removeAccount] Removing account \(account.id) (\(account.email))")

        // If removing the active account, first move the OS credential slot to another
        // account so the CLI doesn't keep using the removed account's token. Must happen
        // BEFORE we mutate accounts/activeAccount, otherwise switchTo() short-circuits.
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

        keychain.removeAccountBackup(forAccountId: account.id.uuidString)
        usage.removeValue(forKey: account.id)
        cachedUsage.removeValue(forKey: account.id)
        saveUsageCache()
        accounts.removeAll { $0.id == account.id }
        if activeAccount?.id == account.id {
            // The deleted account was active and switchTo above didn't reconcile
            // (e.g. there were no other accounts). Clear active state through the
            // single source of truth so isActive flags stay consistent.
            setActiveAccount(id: nil)
        }
        saveAccounts()
        log.info("[removeAccount] Done. Remaining accounts: \(self.accounts.count)")
    }

    func switchTo(_ account: Account) async {
        guard !isLoading else {
            log.info("[switchTo] Ignored: a switch/refresh is already in flight")
            return
        }
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

        isLoading = true
        do {
            try await claudeService.switchAccount(from: currentActive, to: account)

            if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[idx].lastUsed = Date()
            }
            setActiveAccount(id: account.id)
            saveAccounts()

            await refresh()
            log.info("[switchTo] ===== Switch completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto Switch

    private func autoSwitchIfNeeded() async {
        guard autoSwitchEnabled else { return }
        guard let current = activeAccount else { return }
        guard accounts.count > 1 else { return }

        // Anti-oscillation cooldown
        if let lastSwitch = lastAutoSwitchTime,
           Date().timeIntervalSince(lastSwitch) < autoSwitchCooldown {
            log.info("[autoSwitch] Cooldown active, skipping")
            return
        }

        let currentUtilization = resolveSessionUtilization(for: current.id) ?? 0
        guard currentUtilization >= Double(autoSwitchThreshold) else { return }

        log.info("[autoSwitch] Current account \(current.email) at \(Int(currentUtilization))% (threshold: \(autoSwitchThreshold)%), looking for alternative...")

        // Prune expired abandoned entries
        let now = Date()
        recentlyAbandonedAccounts = recentlyAbandonedAccounts.filter { now.timeIntervalSince($0.value) < abandonedCooldown }

        let threshold = Double(autoSwitchThreshold)
        let candidates = accounts
            .filter { $0.id != current.id }
            .filter { !(usage[$0.id]?.isExpired ?? false) }
            .compactMap { account -> (Account, Double, TimeInterval)? in
                guard let util = resolveSessionUtilization(for: account.id) else { return nil }
                let resetInterval = resolveWeeklyResetInterval(for: account.id)
                return (account, util, resetInterval)
            }
            .filter { $0.1 < threshold }
            .sorted { a, b in
                if abs(a.1 - b.1) < 10.0 {
                    return a.2 < b.2
                }
                return a.1 < b.1
            }

        // Prefer non-recently-abandoned candidate; fall back to abandoned only if sole option
        let candidate = candidates.first(where: { recentlyAbandonedAccounts[$0.0.id] == nil })
            ?? candidates.first

        guard let (target, targetUtil, _) = candidate else {
            log.info("[autoSwitch] No suitable account found (all above threshold or unavailable)")
            return
        }

        log.info("[autoSwitch] Switching to \(target.email) at \(Int(targetUtil))%, abandoned=\(recentlyAbandonedAccounts.count) accounts")
        recentlyAbandonedAccounts[current.id] = now
        lastAutoSwitchTime = Date()
        isAutoSwitching = true
        defer { isAutoSwitching = false }
        await switchTo(target)
    }

    /// Resolve session utilization: live `usage` state with reset-awareness.
    private func resolveSessionUtilization(for accountId: UUID) -> Double? {
        return usage[accountId]?.effectiveSessionUtilization()
    }

    /// Time until weekly reset (seconds). Returns .infinity if unknown.
    private func resolveWeeklyResetInterval(for accountId: UUID) -> TimeInterval {
        guard let resetDate = usage[accountId]?.usage?.sevenDay?.resetsAtDate else { return .infinity }
        let interval = resetDate.timeIntervalSinceNow
        return interval > 0 ? interval : 0
    }

    // MARK: - Usage

    /// Fetch usage for all accounts and atomically replace the published `usage` dict.
    ///
    /// Each account's full state (success/stale/expired/rate-limited) is one `UsageState`
    /// value, so partial mutation can't leave the published state in a torn condition.
    private func fetchAllAccountUsage() async {
        // Snapshot the account list at the start so reentrant mutations (e.g. removeAccount
        // during an await) can't change the iteration order or stagger decision mid-flight.
        let snapshot = accounts.filter { !$0.isRelay }   // relays have no usage API
        var newUsage: [UUID: UsageState] = [:]
        var newCache = cachedUsage

        for (index, account) in snapshot.enumerated() {
            let state = await fetchOneAccountUsage(account, isFirst: index == 0, currentCache: newCache)
            newUsage[account.id] = state
            // Only `.fresh` rounds advance the persistent cache.
            if case .fresh(let u, let f) = state {
                newCache[account.id] = CachedUsageEntry(usage: u, fetchedAt: f)
            }
        }

        usage = newUsage
        cachedUsage = newCache
        saveUsageCache()
    }

    /// Build the appropriate stale/missing fallback state from the persistent cache.
    private static func fallback(_ accountId: UUID, cache: [UUID: CachedUsageEntry], reason: String) -> UsageState {
        if let cached = cache[accountId] {
            return .stale(cached.usage, fetchedAt: cached.fetchedAt, reason: reason)
        }
        return .expired(message: reason)
    }

    /// Persist a refreshed token to wherever this account's credentials live:
    /// active account → OS keychain slot (so the CLI gets the fresh token too) + vault;
    /// inactive account → vault entry only.
    private func persistRefreshedToken(_ tokenJSON: String, for account: Account) {
        if account.isActive {
            _ = keychain.writeClaudeToken(tokenJSON)
            _ = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString, expectedEmail: account.email)
        } else if let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString) {
            keychain.saveAccountBackup(token: tokenJSON, oauthAccount: backup.oauthAccount, forAccountId: account.id.uuidString)
        }
    }

    private func fetchOneAccountUsage(_ account: Account, isFirst: Bool, currentCache: [UUID: CachedUsageEntry]) async -> UsageState {
        var tokenJSON: String?
        if account.isActive {
            tokenJSON = keychain.readClaudeToken()
        } else {
            tokenJSON = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
        }

        // Pre-check token expiry — refresh proactively instead of eating a guaranteed 401.
        // Applies to the active account too: its refreshed token is written back to the
        // OS keychain slot, so the CLI also benefits instead of carrying a stale token.
        if let tj = tokenJSON, ClaudeService.isTokenExpired(tj) {
            log.info("[fetchUsage] Token expired locally for \(account.email), attempting auto-refresh...")
            if let refreshedJSON = await claudeService.refreshAccessToken(tokenJSON: tj) {
                log.info("[fetchUsage] Token refreshed for \(account.email)")
                persistRefreshedToken(refreshedJSON, for: account)
                tokenJSON = refreshedJSON
            } else {
                log.warning("[fetchUsage] Auto-refresh failed for \(account.email), marking as expired")
                return .expired(message: "Token expired. Click ↻ to re-authenticate.")
            }
        }

        guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
            log.warning("[fetchUsage] No token for \(account.email), skipping")
            return .expired(message: "No credentials. Re-authenticate.")
        }

        // Stagger requests to avoid 429 rate limiting (1.5s between each, except for the first).
        // Use the snapshot-based isFirst flag, NOT live `accounts.first?.id` — reentrant
        // mutations during await could change which account is "first".
        if !isFirst {
            try? await Task.sleep(for: .milliseconds(1500))
        }

        do {
            let result = try await claudeService.getUsageLimits(accessToken: accessToken)
            log.info("[fetchUsage] \(account.email): session=\(result.fiveHour?.utilization ?? -1)%, weekly=\(result.sevenDay?.utilization ?? -1)%")
            return .fresh(result, fetchedAt: Date())
        } catch ClaudeService.UsageError.expired {
            log.warning("[fetchUsage] 401 expired for \(account.email), attempting auto-refresh...")
            let currentTokenJSON = account.isActive ? keychain.readClaudeToken() : tokenJSON
            if let tj = currentTokenJSON,
               let refreshedJSON = await claudeService.refreshAccessToken(tokenJSON: tj) {
                log.info("[fetchUsage] Token refreshed for \(account.email)")
                persistRefreshedToken(refreshedJSON, for: account)
                if let newToken = ClaudeService.extractAccessToken(from: refreshedJSON),
                   let result = try? await claudeService.getUsageLimits(accessToken: newToken) {
                    log.info("[fetchUsage] Recovered \(account.email) via auto-refresh.")
                    return .fresh(result, fetchedAt: Date())
                }
            }
            log.warning("[fetchUsage] Auto-refresh failed for \(account.email)")
            return .expired(message: "Token expired. Click ↻ to re-authenticate.")
        } catch {
            log.error("[fetchUsage] Failed to get usage for \(account.email): \(error.localizedDescription)")
            let is429 = (error as? ClaudeService.UsageError).flatMap {
                if case .network(let msg) = $0 { return msg.contains("429") }
                return false
            } ?? false

            if is429, currentCache[account.id] == nil {
                // No data at all — retry once after delay to build initial cache
                log.info("[fetchUsage] 429 with no cache for \(account.email), retrying after 3s...")
                try? await Task.sleep(for: .seconds(3))
                if let retryUsage = try? await claudeService.getUsageLimits(accessToken: accessToken) {
                    log.info("[fetchUsage] Retry succeeded for \(account.email)")
                    return .fresh(retryUsage, fetchedAt: Date())
                }
            }

            if is429 {
                let cached = currentCache[account.id]
                return .rateLimited(cached: cached?.usage, fetchedAt: cached?.fetchedAt)
            }
            return Self.fallback(account.id, cache: currentCache, reason: error.localizedDescription)
        }
    }

    // MARK: - Diagnostics

    private func diagnoseTokenHealth() {
        guard !accounts.isEmpty else { return }

        log.info("[diagnose] === Health Check ===")
        log.info("[diagnose] Accounts: \(self.accounts.count), active: \(self.activeAccount?.email ?? "none")")

        // Check live oauthAccount identity
        if let liveOAuth = keychain.readOAuthAccount() {
            let liveEmail = (liveOAuth["emailAddress"]?.value as? String) ?? "?"
            log.info("[diagnose] Live oauthAccount: \(liveEmail)")
        } else {
            log.warning("[diagnose] Live oauthAccount: MISSING")
        }

        // Check each account has a backup
        for account in accounts where !account.isRelay {
            if let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString) {
                let backupEmail = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
                log.info("[diagnose] Backup [\(account.email)]: OK (email=\(backupEmail))")
            } else {
                log.warning("[diagnose] Backup [\(account.email)]: MISSING — switch will fail")
            }
        }

        log.info("[diagnose] === End Health Check ===")
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            log.info("[loadAccounts] No saved accounts found")
            return
        }
        accounts = decoded
        activeAccount = accounts.first(where: \.isActive)
        log.info("[loadAccounts] Loaded \(decoded.count) accounts")
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
            log.debug("[saveAccounts] Saved \(self.accounts.count) accounts to UserDefaults")
        }
    }

    private func loadUsageCache() {
        guard let data = UserDefaults.standard.data(forKey: usageCacheKey),
              let decoded = try? JSONDecoder().decode([UUID: CachedUsageEntry].self, from: data) else {
            log.info("[loadUsageCache] No saved usage cache found")
            return
        }
        cachedUsage = decoded
        log.info("[loadUsageCache] Loaded cache for \(decoded.count) accounts")
    }

    private func saveUsageCache() {
        if let data = try? JSONEncoder().encode(cachedUsage) {
            UserDefaults.standard.set(data, forKey: usageCacheKey)
            log.debug("[saveUsageCache] Saved cache for \(self.cachedUsage.count) accounts")
        }
    }

    private func updateActiveAccount(from status: AuthStatus) {
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

        // CLI says no one is logged in (e.g. user ran `claude auth logout` externally).
        // Clear our active state so UI doesn't keep showing a phantom active account.
        guard status.loggedIn, let email = status.email else {
            if activeAccount != nil {
                log.info("[updateActiveAccount] CLI not logged in — clearing active state")
                setActiveAccount(id: nil)
                saveAccounts()
            }
            return
        }

        if let index = accounts.firstIndex(where: { $0.email == email }) {
            accounts[index].orgName = status.orgName
            accounts[index].subscriptionType = status.subscriptionType
            setActiveAccount(id: accounts[index].id)
            saveAccounts()
            log.info("[updateActiveAccount] Matched existing account at index \(index)")
        } else if accounts.isEmpty {
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: false
            )
            accounts.append(account)
            setActiveAccount(id: account.id)
            _ = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString, expectedEmail: email)
            saveAccounts()
            log.info("[updateActiveAccount] Auto-created first account, id=\(account.id)")
        } else {
            // CLI is logged in to an account we don't manage. Don't claim any of our
            // accounts as active — that would lie to the user about which token is in use.
            log.info("[updateActiveAccount] Logged-in account \(email) not in our list — clearing active state")
            setActiveAccount(id: nil)
            saveAccounts()
        }
    }
}
