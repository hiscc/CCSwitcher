import Foundation
import CryptoKit

private let log = FileLog("Claude")

/// Manages Claude account credentials through the OS truth sources (keychain token +
/// ~/.claude.json oauthAccount) and Anthropic's OAuth/usage HTTP APIs.
///
/// Deliberately spawns NO Claude CLI processes: the CLI runs on Bun, which is
/// unstable on CPUs without AVX (random early exits), and everything the app
/// needs is available from the files/keychain the CLI itself reads, plus HTTP.
final class ClaudeService: @unchecked Sendable {
    static let shared = ClaudeService()

    private init() {}

    // MARK: - Auth Status

    /// Read auth state directly from the OS truth sources — the same two slots
    /// the CLI's `auth status` reads. Forking the CLI here added a Bun runtime
    /// dependency (and its crash modes) for information the app already owns.
    func getAuthStatus() -> AuthStatus {
        // Relay env takes precedence: when both keys are present the CLI routes to
        // the relay (verified 2026-07-03: bogus token → 401, no OAuth fallback).
        if let relay = RelaySettingsService.shared.readRelayEnv() {
            log.info("[getAuthStatus] Relay env active: \(relay.baseURL)")
            return AuthStatus(loggedIn: false, email: nil, orgName: nil, subscriptionType: nil, relayEnv: relay)
        }
        let keychain = KeychainService.shared
        guard let tokenJSON = keychain.readClaudeToken(),
              let oauthAccount = keychain.readOAuthAccount(),
              let email = oauthAccount["emailAddress"]?.value as? String else {
            log.info("[getAuthStatus] Not logged in (missing token or oauthAccount)")
            return AuthStatus(loggedIn: false, email: nil, orgName: nil, subscriptionType: nil)
        }
        let orgName = oauthAccount["organizationName"]?.value as? String
        let subscriptionType = Self.extractSubscriptionType(from: tokenJSON)
        log.info("[getAuthStatus] loggedIn=true, email=\(email), sub=\(subscriptionType ?? "nil")")
        return AuthStatus(loggedIn: true, email: email, orgName: orgName, subscriptionType: subscriptionType)
    }

    /// Extract subscriptionType from a token JSON (keychain format).
    static func extractSubscriptionType(from tokenJSON: String) -> String? {
        guard let data = tokenJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        return oauth["subscriptionType"] as? String
    }

    // MARK: - Usage API

    enum UsageError: Error {
        case expired
        case network(String)
        case decode(String)
    }

    /// Fetch usage for a specific access token
    func getUsageLimits(accessToken: String) async throws -> UsageAPIResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { throw UsageError.network("invalid url") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        log.debug("[getUsageLimits] REQUEST URL: \(url.absoluteString)")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard httpResponse?.statusCode == 200 else {
            let responseString = String(data: responseData, encoding: .utf8) ?? ""
            log.error("[getUsageLimits] HTTP \(httpResponse?.statusCode ?? 0) Error Response: \(responseString)")
            
            if httpResponse?.statusCode == 401 || responseString.contains("token_expired") {
                throw UsageError.expired
            }
            throw UsageError.network("HTTP \(httpResponse?.statusCode ?? 0)")
        }
        
        do {
            let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: responseData)
            log.info("[getUsageLimits] session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
            return usage
        } catch {
            log.error("[getUsageLimits] Decode Error: \(error.localizedDescription)")
            throw UsageError.decode(error.localizedDescription)
        }
    }

    /// Extract access token string from a token JSON (keychain format)
    static func extractAccessToken(from tokenJSON: String) -> String? {
        guard let data = tokenJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            return nil
        }
        return accessToken
    }

    /// Check if a token JSON's accessToken is expired (or will expire within the grace period).
    static func isTokenExpired(_ tokenJSON: String, graceSeconds: TimeInterval = 300) -> Bool {
        guard let data = tokenJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            log.warning("[isTokenExpired] Failed to parse token JSON — treating as expired")
            return true
        }
        // expiresAt may be Int or Double depending on JSON source
        let expiresAt: Double
        if let d = oauth["expiresAt"] as? Double {
            expiresAt = d
        } else if let i = oauth["expiresAt"] as? Int {
            expiresAt = Double(i)
        } else if let n = oauth["expiresAt"] as? NSNumber {
            expiresAt = n.doubleValue
        } else {
            log.warning("[isTokenExpired] No expiresAt field — treating as expired")
            return true
        }
        let expiryDate = Date(timeIntervalSince1970: expiresAt / 1000.0)
        let remaining = expiryDate.timeIntervalSinceNow
        let isExpired = remaining < graceSeconds
        log.info("[isTokenExpired] Expires at \(expiryDate), remaining=\(Int(remaining))s, expired=\(isExpired)")
        return isExpired
    }

    /// Extract refreshToken from a token JSON.
    static func extractRefreshToken(from tokenJSON: String) -> String? {
        guard let data = tokenJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String else {
            return nil
        }
        return refreshToken
    }

    // MARK: - Token Refresh

    private static let oauthTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Refresh an expired accessToken using the refreshToken via Anthropic's OAuth endpoint.
    /// Returns the updated token JSON string, or nil on failure.
    func refreshAccessToken(tokenJSON: String) async -> String? {
        guard let refreshToken = Self.extractRefreshToken(from: tokenJSON) else {
            log.error("[refreshToken] No refreshToken in token JSON")
            return nil
        }
        log.info("[refreshToken] Refreshing via \(Self.oauthTokenURL.absoluteString)...")

        var request = URLRequest(url: Self.oauthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientId
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                log.error("[refreshToken] No HTTP response")
                return nil
            }
            guard http.statusCode == 200 else {
                let resp = String(data: data, encoding: .utf8) ?? ""
                log.error("[refreshToken] HTTP \(http.statusCode): \(resp.prefix(200))")
                return nil
            }
            guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = result["access_token"] as? String,
                  let expiresIn = result["expires_in"] as? Double else {
                log.error("[refreshToken] Failed to parse response")
                return nil
            }

            // Rebuild token JSON with new values
            guard var tokenDict = try? JSONSerialization.jsonObject(
                        with: tokenJSON.data(using: .utf8)!) as? [String: Any],
                  var oauth = tokenDict["claudeAiOauth"] as? [String: Any] else {
                return nil
            }
            oauth["accessToken"] = newAccessToken
            oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + expiresIn) * 1000.0)
            if let newRefresh = result["refresh_token"] as? String {
                oauth["refreshToken"] = newRefresh
            }
            tokenDict["claudeAiOauth"] = oauth

            guard let newData = try? JSONSerialization.data(withJSONObject: tokenDict),
                  let newJSON = String(data: newData, encoding: .utf8) else {
                return nil
            }
            log.info("[refreshToken] Success! Expires in \(Int(expiresIn/3600))h")
            return newJSON
        } catch {
            log.error("[refreshToken] Network error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Account Switching

    func switchAccount(from currentAccount: Account, to targetAccount: Account) async throws {
        let keychain = KeychainService.shared

        log.info("[switchAccount] Switching from \(currentAccount.id) to \(targetAccount.id)")

        // 1. Back up current account (token + oauthAccount)
        log.info("[switchAccount] Step 1: Backing up current account...")
        if let currentToken = keychain.readClaudeToken(),
           let currentOAuth = keychain.readOAuthAccount() {
            let email = (currentOAuth["emailAddress"]?.value as? String) ?? "?"
            if email == currentAccount.email {
                let saved = keychain.saveAccountBackup(token: currentToken, oauthAccount: currentOAuth, forAccountId: currentAccount.id.uuidString)
                log.info("[switchAccount] Step 1: Backup saved: \(saved)")
            } else {
                log.warning("[switchAccount] Step 1: oauthAccount email (\(email)) != source (\(currentAccount.email)), skipping backup")
            }
        } else {
            log.warning("[switchAccount] Step 1: Could not read current token or oauthAccount")
        }

        // 2. Retrieve target account's backup
        log.info("[switchAccount] Step 2: Reading backup for target account...")
        guard let targetBackup = keychain.getAccountBackup(forAccountId: targetAccount.id.uuidString) else {
            log.error("[switchAccount] Step 2: No backup found for target account!")
            throw ClaudeServiceError.noTokenForAccount(targetAccount.id.uuidString)
        }
        let targetEmail = (targetBackup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
        log.info("[switchAccount] Step 2: Target backup found (email=\(targetEmail))")

        // 3. Snapshot current credentials for rollback, then write target
        log.info("[switchAccount] Step 3: Writing target credentials...")
        let rollbackToken = keychain.readClaudeToken()
        let rollbackOAuth = keychain.readOAuthAccount()

        guard keychain.writeClaudeToken(targetBackup.token) else {
            log.error("[switchAccount] Step 3: Failed to write token to keychain!")
            throw ClaudeServiceError.keychainWriteFailed
        }
        guard keychain.writeOAuthAccount(targetBackup.oauthAccount) else {
            // Rollback: restore original token since oauthAccount write failed
            log.error("[switchAccount] Step 3: Failed to write oauthAccount — rolling back token!")
            if let rollbackToken {
                _ = keychain.writeClaudeToken(rollbackToken)
            }
            if let rollbackOAuth {
                _ = keychain.writeOAuthAccount(rollbackOAuth)
            }
            throw ClaudeServiceError.oauthAccountWriteFailed
        }
        log.info("[switchAccount] Step 3: Both token and oauthAccount written")

        // 4. Verify by reading back the OS slots — rollback on any mismatch.
        // Reading our own writes is the strongest check available: the CLI's
        // `auth status` reads exactly these two sources anyway.
        log.info("[switchAccount] Step 4: Verifying OS slots...")
        let status = getAuthStatus()
        guard status.loggedIn else {
            log.error("[switchAccount] Step 4: Not logged in after switch — rolling back keychain!")
            if let rollbackToken { _ = keychain.writeClaudeToken(rollbackToken) }
            if let rollbackOAuth { _ = keychain.writeOAuthAccount(rollbackOAuth) }
            throw ClaudeServiceError.switchVerificationFailed
        }
        if status.email != targetAccount.email {
            log.error("[switchAccount] Step 4: Logged in as \(status.email ?? "nil") instead of \(targetAccount.email) — rolling back keychain!")
            if let rollbackToken { _ = keychain.writeClaudeToken(rollbackToken) }
            if let rollbackOAuth { _ = keychain.writeOAuthAccount(rollbackOAuth) }
            throw ClaudeServiceError.switchWrongAccount(expected: targetAccount.email, actual: status.email ?? "unknown")
        }
        log.info("[switchAccount] Step 4: Switch verified — logged in as \(status.email ?? "")")

        // (No re-capture step: nothing can mutate the keychain between our Step 3
        // write and here now that verification doesn't fork the CLI — the vault
        // already holds exactly what we just wrote.)
    }

    /// Capture the current Claude auth token + oauthAccount and associate with an account.
    /// When `expectedEmail` is provided, the capture is skipped if the keychain email doesn't match
    /// (prevents saving wrong credentials after a failed switch leaves the keychain dirty).
    func captureCurrentCredentials(forAccountId accountId: String, expectedEmail: String? = nil) -> Bool {
        log.info("[capture] Capturing credentials for account \(accountId) (expected=\(expectedEmail ?? "any"))...")
        let keychain = KeychainService.shared
        guard let token = keychain.readClaudeToken() else {
            log.error("[capture] Failed: no token found in keychain")
            return false
        }
        guard let oauthAccount = keychain.readOAuthAccount() else {
            log.error("[capture] Failed: no oauthAccount found in ~/.claude.json")
            return false
        }
        let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
        if let expected = expectedEmail, email != expected {
            log.error("[capture] ABORT: keychain email (\(email)) != expected (\(expected)) — keychain may be dirty")
            return false
        }
        log.info("[capture] Token + oauthAccount found (email=\(email)), saving backup...")
        let result = keychain.saveAccountBackup(token: token, oauthAccount: oauthAccount, forAccountId: accountId)
        log.info("[capture] Save result: \(result)")
        return result
    }

    // MARK: - Native OAuth Login (no CLI in the critical path)
    //
    // `claude auth login` requires its CLI process to stay alive for the whole
    // browser dance: the hosted callback page hands the authorization code back
    // to the CLI's localhost listener. On machines where Bun is unstable (CPUs
    // without AVX — Bun itself warns "strange crashes may occur") that child can
    // die early, after which login can never complete. So we run the OAuth
    // authorization-code + PKCE flow ourselves and write the exact artifacts the
    // CLI would: the keychain token JSON and oauthAccount in ~/.claude.json.
    // The user pastes the code shown by the hosted callback page into the app.

    private static let oauthAuthorizeBase = "https://claude.com/cai/oauth/authorize"
    private static let oauthRedirectURI = "https://platform.claude.com/oauth/code/callback"
    private static let oauthScope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    private static let oauthProfileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// Generate a PKCE verifier/challenge pair + state and build the authorize URL.
    /// Parameters mirror the CLI's own authorize URL verbatim.
    func beginNativeOAuth() -> PendingOAuth {
        let verifier = Self.base64URL(Self.randomBytes(32))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.base64URL(Self.randomBytes(32))

        var comps = URLComponents(string: Self.oauthAuthorizeBase)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.oauthClientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.oauthRedirectURI),
            URLQueryItem(name: "scope", value: Self.oauthScope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        log.info("[nativeOAuth] Begin login, state=\(state.prefix(8))…")
        return PendingOAuth(codeVerifier: verifier, state: state, authorizeURL: comps.url!)
    }

    /// Exchange the pasted authorization code for tokens, write keychain +
    /// ~/.claude.json, and return the new identity. The code copied from the
    /// hosted callback page has the form "<code>#<state>".
    func completeNativeOAuth(pastedCode raw: String, pending: PendingOAuth) async throws -> NativeLoginResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClaudeServiceError.invalidAuthCode("Code is empty") }

        let code: String
        let state: String
        if let hash = trimmed.firstIndex(of: "#") {
            code = String(trimmed[..<hash])
            state = String(trimmed[trimmed.index(after: hash)...])
            guard state == pending.state else {
                log.error("[nativeOAuth] State mismatch — code is from a different login attempt")
                throw ClaudeServiceError.invalidAuthCode("This code belongs to a different sign-in attempt. Click \"Reopen Page\" and copy the code from the new page.")
            }
        } else {
            code = trimmed
            state = pending.state
        }

        // 1. Exchange code for tokens (same endpoint the token refresh already uses)
        var request = URLRequest(url: Self.oauthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": Self.oauthClientId,
            "redirect_uri": Self.oauthRedirectURI,
            "code_verifier": pending.codeVerifier,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let resp = String(data: data, encoding: .utf8) ?? ""
            log.error("[nativeOAuth] Token exchange HTTP \(status): \(resp.prefix(300))")
            throw ClaudeServiceError.oauthExchangeFailed("HTTP \(status). Check the pasted code and try again.")
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = result["access_token"] as? String,
              let refreshToken = result["refresh_token"] as? String,
              let expiresIn = (result["expires_in"] as? NSNumber)?.doubleValue else {
            log.error("[nativeOAuth] Unexpected token response shape")
            throw ClaudeServiceError.oauthExchangeFailed("Unexpected token response")
        }
        log.info("[nativeOAuth] Token exchange OK (expires in \(Int(expiresIn / 3600))h)")

        // 2. Fetch identity + subscription with the fresh token
        var profileReq = URLRequest(url: Self.oauthProfileURL)
        profileReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        profileReq.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (profData, profResp) = try await URLSession.shared.data(for: profileReq)
        guard (profResp as? HTTPURLResponse)?.statusCode == 200,
              let profile = try JSONSerialization.jsonObject(with: profData) as? [String: Any],
              let account = profile["account"] as? [String: Any],
              let email = account["email"] as? String else {
            let status = (profResp as? HTTPURLResponse)?.statusCode ?? 0
            log.error("[nativeOAuth] Profile fetch failed (HTTP \(status))")
            throw ClaudeServiceError.profileFetchFailed("HTTP \(status)")
        }
        let organization = profile["organization"] as? [String: Any] ?? [:]
        let orgName = organization["name"] as? String

        let subscriptionType: String?
        if (account["has_claude_max"] as? Bool) == true {
            subscriptionType = "max"
        } else if (account["has_claude_pro"] as? Bool) == true {
            subscriptionType = "pro"
        } else if let orgType = organization["organization_type"] as? String {
            subscriptionType = orgType.replacingOccurrences(of: "claude_", with: "")
        } else {
            subscriptionType = nil
        }

        // 3. Build the keychain token JSON (same shape the CLI writes)
        var oauthDict: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresAt": Int((Date().timeIntervalSince1970 + expiresIn) * 1000.0),
            "scopes": (result["scope"] as? String)?.components(separatedBy: " ")
                ?? ["user:inference", "user:mcp_servers", "user:profile", "user:sessions:claude_code", "user:file_upload"],
        ]
        if let subscriptionType { oauthDict["subscriptionType"] = subscriptionType }
        if let tier = organization["rate_limit_tier"] as? String { oauthDict["rateLimitTier"] = tier }
        let tokenData = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauthDict])
        guard let tokenJSON = String(data: tokenData, encoding: .utf8) else {
            throw ClaudeServiceError.oauthExchangeFailed("Token JSON encode failed")
        }

        // 4. Build oauthAccount for ~/.claude.json (field names mirror the CLI's).
        // Nested dicts (e.g. ccOnboardingFlags) are deliberately omitted —
        // AnyCodable can't encode raw [String: Any], and the CLI rewrites the
        // full record on its own next login anyway.
        var oauthAccount: [String: AnyCodable] = [:]
        func put(_ key: String, _ value: Any?) {
            guard let value, !(value is NSNull) else { return }
            oauthAccount[key] = AnyCodable(value)
        }
        put("accountUuid", account["uuid"])
        put("emailAddress", email)
        put("displayName", account["display_name"] ?? account["full_name"])
        put("accountCreatedAt", account["created_at"])
        put("organizationUuid", organization["uuid"])
        put("organizationName", organization["name"])
        put("organizationType", organization["organization_type"])
        put("billingType", organization["billing_type"])
        put("organizationRateLimitTier", organization["rate_limit_tier"])
        put("seatTier", organization["seat_tier"])
        put("hasExtraUsageEnabled", organization["has_extra_usage_enabled"])
        put("subscriptionCreatedAt", organization["subscription_created_at"])
        put("claudeCodeTrialEndsAt", organization["claude_code_trial_ends_at"])
        put("claudeCodeTrialDurationDays", organization["claude_code_trial_duration_days"])

        // 5. Write both OS truth-source slots
        let keychain = KeychainService.shared
        guard keychain.writeClaudeToken(tokenJSON) else {
            throw ClaudeServiceError.keychainWriteFailed
        }
        guard keychain.writeOAuthAccount(oauthAccount) else {
            throw ClaudeServiceError.oauthAccountWriteFailed
        }
        log.info("[nativeOAuth] Login complete: \(email) (\(subscriptionType ?? "?"))")
        return NativeLoginResult(email: email, orgName: orgName, subscriptionType: subscriptionType)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

}

// MARK: - Native OAuth Types

/// In-flight native OAuth login: PKCE verifier + state + the authorize URL opened
/// in the browser. Held by AppState between "open browser" and "paste code".
struct PendingOAuth {
    let codeVerifier: String
    let state: String
    let authorizeURL: URL
}

/// Identity captured by a completed native OAuth login.
struct NativeLoginResult {
    let email: String
    let orgName: String?
    let subscriptionType: String?
}

// MARK: - Errors

enum ClaudeServiceError: LocalizedError {
    case noTokenForAccount(String)
    case keychainWriteFailed
    case oauthAccountWriteFailed
    case switchVerificationFailed
    case switchWrongAccount(expected: String, actual: String)
    case invalidAuthCode(String)
    case oauthExchangeFailed(String)
    case profileFetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noTokenForAccount:
            return "No stored backup for target account"
        case .keychainWriteFailed:
            return "Failed to write token to keychain"
        case .oauthAccountWriteFailed:
            return "Failed to write oauthAccount to ~/.claude.json"
        case .switchVerificationFailed:
            return "Account switch verification failed"
        case .switchWrongAccount(let expected, let actual):
            return "Switch failed: expected \(expected) but got \(actual). Try removing and re-adding the account."
        case .invalidAuthCode(let msg):
            return "Invalid authorization code: \(msg)"
        case .oauthExchangeFailed(let msg):
            return "Sign-in failed: \(msg)"
        case .profileFetchFailed(let msg):
            return "Signed in, but could not fetch account profile (\(msg)). Please try again."
        }
    }
}
