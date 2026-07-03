import Foundation

// MARK: - Provider Type (extensible for Gemini, Codex, etc.)

enum AIProviderType: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case gemini = "Gemini"
    case codex = "Codex"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .claudeCode: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var configDirectory: String {
        switch self {
        case .claudeCode: return "~/.claude"
        case .gemini: return "~/.gemini"
        case .codex: return "~/.codex"
        }
    }
}

// MARK: - Account Model

struct Account: Identifiable, Codable, Hashable {
    let id: UUID
    var email: String
    var displayName: String
    var provider: AIProviderType
    var orgName: String?
    var subscriptionType: String?
    var isActive: Bool
    var lastUsed: Date?
    /// Relay station base URL. nil = official OAuth account.
    var baseURL: String?

    var isRelay: Bool { baseURL != nil }

    var obfuscatedEmail: String {
        return email
    }

    var obfuscatedDisplayName: String {
        return displayName
    }

    init(
        id: UUID = UUID(),
        email: String,
        displayName: String,
        provider: AIProviderType = .claudeCode,
        orgName: String? = nil,
        subscriptionType: String? = nil,
        isActive: Bool = false,
        lastUsed: Date? = nil,
        baseURL: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.provider = provider
        self.orgName = orgName
        self.subscriptionType = subscriptionType
        self.isActive = isActive
        self.lastUsed = lastUsed
        self.baseURL = baseURL
    }
}

// MARK: - Auth Status

/// Auth state derived from the OS truth sources (keychain token + ~/.claude.json
/// oauthAccount + settings.json relay env).
struct AuthStatus {
    let loggedIn: Bool
    let email: String?
    let orgName: String?
    let subscriptionType: String?
    /// Relay env present in ~/.claude/settings.json. Non-nil = the CLI routes to
    /// the relay; OAuth slots are cleared on relay switch (mutual exclusion).
    var relayEnv: RelayEnv? = nil
}
