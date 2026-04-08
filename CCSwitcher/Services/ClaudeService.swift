import Foundation

private let log = FileLog("Claude")

/// Interacts with the Claude CLI to get auth status and manage accounts.
final class ClaudeService: Sendable {
    static let shared = ClaudeService()

    private let claudePath: String

    private init() {
        // Discover nvm-managed node bin paths
        let nvmPaths: [String] = {
            let nvmDir = "\(NSHomeDirectory())/.nvm/versions/node"
            guard let nodes = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) else { return [] }
            return nodes.sorted().reversed().map { "\(nvmDir)/\($0)/bin/claude" }
        }()

        let possiblePaths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude"
        ] + nvmPaths
        self.claudePath = possiblePaths.first { FileManager.default.fileExists(atPath: $0) }
            ?? "claude"
        log.info("Claude binary path: \(self.claudePath)")
    }

    // MARK: - Auth Status

    func getAuthStatus() async throws -> AuthStatus {
        log.info("[getAuthStatus] Fetching auth status...")
        let output = try await runClaude(args: ["auth", "status"])
        guard let data = output.data(using: .utf8) else {
            log.error("[getAuthStatus] Invalid output (not UTF-8)")
            throw ClaudeServiceError.invalidOutput
        }
        let status = try JSONDecoder().decode(AuthStatus.self, from: data)
        log.info("[getAuthStatus] loggedIn=\(status.loggedIn), provider=\(status.apiProvider ?? "nil"), sub=\(status.subscriptionType ?? "nil")")
        return status
    }

    func isClaudeAvailable() async -> Bool {
        do {
            let version = try await runClaude(args: ["--version"])
            log.info("[isClaudeAvailable] YES, version: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
            return true
        } catch {
            log.error("[isClaudeAvailable] NO, error: \(error.localizedDescription)")
            return false
        }
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
        log.debug("[getUsageLimits] REQUEST HEADERS: \(request.allHTTPHeaderFields ?? [:])")

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

        // 4. Verify
        log.info("[switchAccount] Step 4: Verifying with `claude auth status`...")
        let status = try await getAuthStatus()
        guard status.loggedIn else {
            log.error("[switchAccount] Step 4: Not logged in after switch!")
            throw ClaudeServiceError.switchVerificationFailed
        }
        if status.email != targetAccount.email {
            log.error("[switchAccount] Step 4: Logged in as \(status.email ?? "nil") instead of \(targetAccount.email)")
            throw ClaudeServiceError.switchWrongAccount(expected: targetAccount.email, actual: status.email ?? "unknown")
        }
        log.info("[switchAccount] Step 4: Switch verified — logged in as \(status.email ?? "")")

        // 5. Re-capture credentials — the CLI may have internally refreshed the access token
        //    during the auth status check. Update backup so we have the freshest token.
        log.info("[switchAccount] Step 5: Re-capturing credentials after switch...")
        let recaptured = captureCurrentCredentials(forAccountId: targetAccount.id.uuidString)
        log.info("[switchAccount] Step 5: Re-capture result: \(recaptured)")
    }

    /// Capture the current Claude auth token + oauthAccount and associate with an account
    func captureCurrentCredentials(forAccountId accountId: String) -> Bool {
        log.info("[capture] Capturing credentials for account \(accountId)...")
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
        log.info("[capture] Token + oauthAccount found (email=\(email)), saving backup...")
        let result = keychain.saveAccountBackup(token: token, oauthAccount: oauthAccount, forAccountId: accountId)
        log.info("[capture] Save result: \(result)")
        return result
    }

    /// Run `claude auth login` which opens browser for OAuth.
    /// Note: The CLI may exit with non-zero status even when login succeeds
    /// (e.g., when running without a TTY). We verify success via `auth status` instead.
    ///
    /// - Parameter previousEmail: The email currently logged in. Used together with
    ///   token-hash comparison to detect when login completes (even same-account re-login).
    func login(previousEmail: String? = nil) async throws {
        log.info("[login] Starting `claude auth login`... (will open browser, previousEmail=\(previousEmail ?? "nil"))")

        // Snapshot token before login so we can detect same-account re-login via string comparison
        let preLoginToken = KeychainService.shared.readClaudeToken()
        log.debug("[login] Pre-login token length: \(preLoginToken?.count ?? 0)")

        do {
            _ = try await runClaude(args: ["auth", "login"])
            log.info("[login] `claude auth login` process exited normally")
        } catch let error as ClaudeServiceError {
            switch error {
            case .cliError(let output) where output.contains("Opening browser") || output.contains("sign in"):
                log.warning("[login] CLI exited after opening browser (expected): \(output.prefix(100))")
            case .processLaunchFailed:
                throw error
            default:
                log.warning("[login] CLI exited with error (may still succeed): \(error.localizedDescription)")
            }
        }

        // Poll for OAuth completion: check auth status every 2 seconds for up to 120 seconds.
        // Detect login via email change OR token change (handles same-account re-login).
        let maxAttempts = 60
        let interval: Duration = .seconds(2)
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            try await Task.sleep(for: interval)
            do {
                let status = try await getAuthStatus()
                if status.loggedIn, let email = status.email {
                    let currentToken = KeychainService.shared.readClaudeToken()
                    let tokenChanged = currentToken != preLoginToken
                    let emailChanged = previousEmail != nil && email != previousEmail

                    if emailChanged || tokenChanged {
                        log.info("[login] Login detected: email=\(email), emailChanged=\(emailChanged), tokenChanged=\(tokenChanged), after \(attempt * 2)s")
                        return
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.debug("[login] Poll attempt \(attempt) failed: \(error.localizedDescription)")
            }
            if attempt % 15 == 0 {
                log.info("[login] Still waiting for OAuth... (\(attempt * 2)s elapsed)")
            }
        }
        log.warning("[login] OAuth polling timed out after \(maxAttempts * 2)s")
    }

    /// Run `claude auth logout`
    func logout() async throws {
        log.info("[logout] Running `claude auth logout`...")
        _ = try await runClaude(args: ["auth", "logout"])
        log.info("[logout] Logout complete")
    }

    // MARK: - CLI Runner

    private func runClaude(args: [String]) async throws -> String {
        log.debug("[runClaude] Running: claude \(args.joined(separator: " "))")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [claudePath] in
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe

                var env = ProcessInfo.processInfo.environment
                let homeDir = NSHomeDirectory()
                // Include the directory containing the resolved claude binary
                // so that `node` (and other dependencies) are also on PATH
                let claudeBinDir = (claudePath as NSString).deletingLastPathComponent
                let extraPaths = [
                    claudeBinDir,
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "\(homeDir)/.local/bin",
                    "\(homeDir)/.npm-global/bin"
                ]
                let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                env["HOME"] = homeDir
                process.environment = env

                do {
                    try process.run()
                    // Read pipe BEFORE waitUntilExit to avoid deadlock when pipe buffer fills
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        log.debug("[runClaude] Success (exit 0), output length: \(output.count)")
                        continuation.resume(returning: output)
                    } else {
                        log.error("[runClaude] Failed (exit \(process.terminationStatus)), output: \(output.prefix(200))")
                        continuation.resume(throwing: ClaudeServiceError.cliError(output))
                    }
                } catch {
                    log.error("[runClaude] Process launch failed: \(error.localizedDescription)")
                    continuation.resume(throwing: ClaudeServiceError.processLaunchFailed(error))
                }
            }
        }
    }
}

// MARK: - Errors

enum ClaudeServiceError: LocalizedError {
    case invalidOutput
    case cliError(String)
    case processLaunchFailed(Error)
    case noTokenForAccount(String)
    case keychainWriteFailed
    case oauthAccountWriteFailed
    case switchVerificationFailed
    case switchWrongAccount(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidOutput:
            return "Invalid output from Claude CLI"
        case .cliError(let msg):
            return "Claude CLI error: \(msg)"
        case .processLaunchFailed(let error):
            return "Failed to launch Claude: \(error.localizedDescription)"
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
        }
    }
}
