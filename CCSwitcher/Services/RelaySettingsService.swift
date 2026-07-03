import Foundation

private let log = FileLog("RelaySettings")

/// The two env keys that point the Claude CLI at a relay station.
/// Present-together = relay active; absent = official OAuth account active.
struct RelayEnv: Equatable {
    let baseURL: String
    let token: String
}

/// Owns the relay env keys (ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN) inside
/// ~/.claude/settings.json. Strictly read-modify-write: every other key in the
/// file (hooks, permissions, plugins, ...) passes through untouched. A file we
/// can't parse is NEVER overwritten — it holds the user's whole CC setup.
final class RelaySettingsService: Sendable {
    static let shared = RelaySettingsService()

    private static let baseURLKey = "ANTHROPIC_BASE_URL"
    private static let authTokenKey = "ANTHROPIC_AUTH_TOKEN"

    private let settingsPath: String

    init(settingsPath: String = NSHomeDirectory() + "/.claude/settings.json") {
        self.settingsPath = settingsPath
    }

    /// Both keys present and non-empty → RelayEnv. Anything less → nil.
    func readRelayEnv() -> RelayEnv? {
        guard let json = readSettings(),
              let env = json["env"]?.value as? [String: AnyCodable],
              let base = env[Self.baseURLKey]?.value as? String,
              let token = env[Self.authTokenKey]?.value as? String,
              !base.isEmpty, !token.isEmpty else {
            return nil
        }
        return RelayEnv(baseURL: base, token: token)
    }

    func writeRelayEnv(_ relay: RelayEnv) -> Bool {
        mutateEnv { env in
            env[Self.baseURLKey] = AnyCodable(relay.baseURL)
            env[Self.authTokenKey] = AnyCodable(relay.token)
        }
    }

    func clearRelayEnv() -> Bool {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return true }
        return mutateEnv { env in
            env.removeValue(forKey: Self.baseURLKey)
            env.removeValue(forKey: Self.authTokenKey)
        }
    }

    /// Rollback helper: restore a previous snapshot (nil = keys were absent).
    func setRelayEnv(_ relay: RelayEnv?) -> Bool {
        if let relay { return writeRelayEnv(relay) }
        return clearRelayEnv()
    }

    /// Trim whitespace, trailing "/" and a trailing "/v1" (users paste OpenAI-style
    /// bases; the CLI appends /v1/messages itself). Deeper paths are preserved.
    static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/v1") {
            s.removeLast(3)
            while s.hasSuffix("/") { s.removeLast() }
        }
        return s
    }

    // MARK: - Private

    private func readSettings() -> [String: AnyCodable]? {
        guard let data = FileManager.default.contents(atPath: settingsPath) else { return nil }
        return try? JSONDecoder().decode([String: AnyCodable].self, from: data)
    }

    private func mutateEnv(_ mutate: (inout [String: AnyCodable]) -> Void) -> Bool {
        var json: [String: AnyCodable]
        if FileManager.default.fileExists(atPath: settingsPath) {
            guard let parsed = readSettings() else {
                log.error("[mutateEnv] \(settingsPath) exists but is not parseable JSON — refusing to overwrite")
                return false
            }
            json = parsed
        } else {
            json = [:]
        }

        var env = (json["env"]?.value as? [String: AnyCodable]) ?? [:]
        mutate(&env)
        json["env"] = AnyCodable(env)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(json)
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            log.info("[mutateEnv] Wrote \(settingsPath)")
            return true
        } catch {
            log.error("[mutateEnv] Write failed: \(error.localizedDescription)")
            return false
        }
    }
}
