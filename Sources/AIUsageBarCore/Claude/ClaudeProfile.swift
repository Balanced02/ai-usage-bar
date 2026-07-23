import Foundation

/// A configured Claude Code profile — a friendly name plus its `CLAUDE_CONFIG_DIR`.
///
/// Path rules (verified): when `CLAUDE_CONFIG_DIR` is unset the config dir is
/// `~/.claude` but `.claude.json` lives at `~/.claude.json` (home root). When it
/// is set to X, both live under X: config dir X, `.claude.json` at `X/.claude.json`.
public struct ClaudeProfile: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    /// Absolute path to the config dir (e.g. ~/.claude or ~/.claude-work).
    public var configDir: URL
    /// Whether this is the default profile (no CLAUDE_CONFIG_DIR env var).
    public var isDefault: Bool

    public var id: String { configDir.path }

    public init(name: String, configDir: URL, isDefault: Bool) {
        self.name = name
        self.configDir = configDir
        self.isDefault = isDefault
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Location of `.claude.json` (account identity + config).
    public var dotClaudeJSON: URL {
        isDefault
            ? Self.home.appendingPathComponent(".claude.json")
            : configDir.appendingPathComponent(".claude.json")
    }

    /// Directory holding per-project session JSONL logs.
    public var projectsDir: URL {
        configDir.appendingPathComponent("projects")
    }

    /// The default profile (`~/.claude`), always present if the user runs Claude Code.
    public static func defaultProfile(name: String = "Personal") -> ClaudeProfile {
        ClaudeProfile(name: name, configDir: home.appendingPathComponent(".claude"), isDefault: true)
    }

    /// A profile backed by a custom config dir (e.g. `~/.claude-work`).
    public static func custom(name: String, dir: String) -> ClaudeProfile {
        ClaudeProfile(name: name,
                      configDir: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath),
                      isDefault: false)
    }
}

/// Account identity parsed from a profile's `.claude.json` `oauthAccount` block.
/// This carries *who* the account is and its plan/tier — but never live usage %.
public struct ClaudeAccount: Codable, Sendable, Hashable {
    public var emailAddress: String?
    public var organizationName: String?
    public var organizationType: String?          // e.g. "claude_max"
    public var organizationRateLimitTier: String? // e.g. "default_claude_max_20x"
    public var accountUuid: String?
    public var organizationUuid: String?
    public var displayName: String?

    public init(emailAddress: String? = nil, organizationName: String? = nil,
                organizationType: String? = nil, organizationRateLimitTier: String? = nil,
                accountUuid: String? = nil, organizationUuid: String? = nil,
                displayName: String? = nil) {
        self.emailAddress = emailAddress
        self.organizationName = organizationName
        self.organizationType = organizationType
        self.organizationRateLimitTier = organizationRateLimitTier
        self.accountUuid = accountUuid
        self.organizationUuid = organizationUuid
        self.displayName = displayName
    }

    /// A concise plan label for the UI, derived from organizationType.
    public var planLabel: String? {
        guard let t = organizationType else { return nil }
        return t.replacingOccurrences(of: "claude_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
    }
}

public enum ClaudeAccountLoader {
    /// Reads the `oauthAccount` block from a profile's `.claude.json`.
    public static func load(_ profile: ClaudeProfile) -> ClaudeAccount? {
        load(dotClaudeJSON: profile.dotClaudeJSON)
    }

    /// Reads identity/plan from a Claude **config dir** — used by the account-driven
    /// model when the user points an account at its logs. `.claude.json` lives inside
    /// a custom config dir but at `~/.claude.json` for the default `~/.claude`, so try
    /// both.
    public static func load(configDir: URL) -> ClaudeAccount? {
        if let a = load(dotClaudeJSON: configDir.appendingPathComponent(".claude.json")) { return a }
        // Only the default ~/.claude keeps its .claude.json at the home root — don't
        // apply that fallback to other dirs, or an account whose logs dir lacks a
        // .claude.json would inherit the default account's plan (a cross-account mislabel).
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard configDir.standardizedFileURL == home.appendingPathComponent(".claude").standardizedFileURL
        else { return nil }
        return load(dotClaudeJSON: home.appendingPathComponent(".claude.json"))
    }

    public static func load(dotClaudeJSON url: URL) -> ClaudeAccount? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oa = root["oauthAccount"] as? [String: Any]
        else { return nil }

        func s(_ k: String) -> String? { oa[k] as? String }
        return ClaudeAccount(
            emailAddress: s("emailAddress"),
            organizationName: s("organizationName"),
            organizationType: s("organizationType"),
            organizationRateLimitTier: s("organizationRateLimitTier"),
            accountUuid: s("accountUuid"),
            organizationUuid: s("organizationUuid"),
            displayName: s("displayName")
        )
    }
}
