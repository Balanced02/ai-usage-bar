import Foundation

/// Which providers to read and how the Claude profiles are configured.
public struct UsageConfig: Sendable {
    public var codexEnabled: Bool
    public var claudeEnabled: Bool
    public var geminiEnabled: Bool
    public var codexHome: URL?
    public var geminiHome: URL?
    public var claudeProfiles: [ClaudeProfile]
    /// Minimum seconds between live Claude endpoint calls (avoids 429s).
    public var claudeMinInterval: TimeInterval
    public var allowKeychain: Bool

    public init(codexEnabled: Bool = true, claudeEnabled: Bool = true, geminiEnabled: Bool = true,
                codexHome: URL? = nil, geminiHome: URL? = nil,
                claudeProfiles: [ClaudeProfile] = [], claudeMinInterval: TimeInterval = 180,
                allowKeychain: Bool = true) {
        self.codexEnabled = codexEnabled
        self.claudeEnabled = claudeEnabled
        self.geminiEnabled = geminiEnabled
        self.codexHome = codexHome
        self.geminiHome = geminiHome
        self.claudeProfiles = claudeProfiles
        self.claudeMinInterval = claudeMinInterval
        self.allowKeychain = allowKeychain
    }

    /// Detects the default `~/.claude` profile plus any `CLAUDE_CONFIG_DIR`
    /// profiles defined by shell aliases/exports (e.g. a `claude-work` alias).
    public static func autoDetect() -> UsageConfig {
        UsageConfig(claudeProfiles: ClaudeProfileDiscovery.discover())
    }
}

/// Aggregates all providers into a single snapshot. Codex and Gemini are read
/// from local files every refresh; Claude's live endpoint is throttled and cached.
public actor UsageService {
    public var config: UsageConfig
    private var claudeCache: [ProviderUsage] = []
    private var lastClaudeFetch: Date?

    public init(config: UsageConfig) {
        self.config = config
    }

    public func update(config: UsageConfig) {
        let profilesChanged = self.config.claudeProfiles != config.claudeProfiles
        self.config = config
        if profilesChanged { claudeCache = [] }
        // Force a Claude refresh on next call if the profile set changed.
        lastClaudeFetch = nil
    }

    public func refresh(now: Date = Date()) async -> [ProviderUsage] {
        var out: [ProviderUsage] = []
        if config.codexEnabled { out.append(CodexReader(codexHome: config.codexHome).read()) }
        if config.claudeEnabled { out.append(contentsOf: await claude(now: now)) }
        if config.geminiEnabled { out.append(GeminiReader(geminiHome: config.geminiHome).read()) }
        return out
    }

    /// Fast, local-only providers (Codex + Gemini) — safe to read every refresh
    /// and never blocks on the network or Keychain.
    public func readLocal() -> (codex: ProviderUsage?, gemini: ProviderUsage?) {
        (config.codexEnabled ? CodexReader(codexHome: config.codexHome).read() : nil,
         config.geminiEnabled ? GeminiReader(geminiHome: config.geminiHome).read() : nil)
    }

    /// Claude cards (throttled live endpoint + Keychain). May block briefly on a
    /// first-run Keychain prompt, so callers run it after publishing local data.
    public func readClaude(now: Date = Date()) async -> [ProviderUsage] {
        guard config.claudeEnabled else { return [] }
        return await claude(now: now)
    }

    /// Offline identity-only placeholder cards, shown instantly while the live
    /// Claude data is still loading.
    public func claudePlaceholders() -> [ProviderUsage] {
        guard config.claudeEnabled else { return [] }
        return config.claudeProfiles.map { ClaudeReader.placeholder(for: $0) }
    }

    private func claude(now: Date) async -> [ProviderUsage] {
        if let last = lastClaudeFetch,
           now.timeIntervalSince(last) < config.claudeMinInterval,
           !claudeCache.isEmpty {
            return claudeCache
        }
        let reader = ClaudeReader(profiles: config.claudeProfiles, allowKeychain: config.allowKeychain)
        let result = await reader.read()
        // Keep any previous window data if a refresh degraded to no-data (endpoint blip).
        claudeCache = result
        lastClaudeFetch = now
        return result
    }
}
