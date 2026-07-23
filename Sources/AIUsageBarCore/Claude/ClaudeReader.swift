import Foundation

/// Produces one `ProviderUsage` per **signed-in Claude account** (from our own OAuth
/// store — never Claude Code's Keychain, so nothing prompts). There is no path
/// auto-discovery: accounts come from `Add account`, and each carries a user config
/// (`ClaudeAccountConfig`: name + optional logs dir).
///
/// Per account:
///   - Identity (email) from the OAuth token; a friendly name from the config.
///   - Live 5H/7D windows from `GET /api/oauth/usage`.
///   - Cost + plan **only when** the account is pointed at a logs folder (there is no
///     cost API — it comes from local `~/.claude` JSONL). Otherwise: live limits only.
public struct ClaudeReader: Sendable {
    /// Per-account user config, keyed by `ClaudeTokenStore.accountKey`.
    public var accountConfigs: [String: ClaudeAccountConfig]
    public var api: ClaudeUsageAPI
    /// Gates live/token access. Off for the CLI probe and unit tests.
    public var allowKeychain: Bool
    /// Injected tokens for tests (used when `allowKeychain` is false).
    public var tokens: [ClaudeOAuthToken]

    public init(accountConfigs: [String: ClaudeAccountConfig] = [:], api: ClaudeUsageAPI = ClaudeUsageAPI(),
                allowKeychain: Bool = true, tokens: [ClaudeOAuthToken] = []) {
        self.accountConfigs = accountConfigs
        self.api = api
        self.allowKeychain = allowKeychain
        self.tokens = tokens
    }

    /// Identity-only cards from the stored accounts, shown instantly while live loads.
    public static func placeholders(configs: [String: ClaudeAccountConfig]) -> [ProviderUsage] {
        ClaudeTokenProvider.shared.accounts().map { token in
            let key = ClaudeTokenStore.accountKey(for: token)
            return ProviderUsage(
                id: "claude:\(key)", kind: .claude,
                displayName: "Claude — \(configs[key]?.name ?? token.accountEmail ?? "Account")",
                accountLabel: token.accountEmail,
                status: .noData, detail: "Loading…", sourcePath: configs[key]?.logsDir)
        }
    }

    public func read() async -> [ProviderUsage] {
        let live = allowKeychain ? await ClaudeTokenProvider.shared.validTokens() : tokens
        var results: [ProviderUsage] = []
        for token in live {
            results.append(await readAccount(token))
        }
        return results
    }

    private func readAccount(_ token: ClaudeOAuthToken) async -> ProviderUsage {
        let key = ClaudeTokenStore.accountKey(for: token)
        let config = accountConfigs[key]
        let logsURL = config?.logsURL
        let name = config?.name ?? token.accountEmail ?? "Account"
        let id = "claude:\(key)"

        // Cost + plan come only from a configured logs folder (no cost API exists).
        let cost: CostSummary? = await {
            guard let logsURL else { return nil }
            return await Task.detached(priority: .utility) {
                ClaudeCostReader.summary(configDir: logsURL)
            }.value
        }()
        let plan = logsURL.flatMap { ClaudeAccountLoader.load(configDir: $0)?.planLabel }

        func base(status: UsageStatus, windows: [UsageWindow] = [], tokens: TokenStats? = nil,
                  detail: String? = nil, updated: Date? = nil) -> ProviderUsage {
            ProviderUsage(id: id, kind: .claude, displayName: "Claude — \(name)",
                          accountLabel: token.accountEmail, planType: plan, windows: windows,
                          tokens: tokens, cost: cost, status: status, detail: detail,
                          lastUpdated: updated, sourcePath: config?.logsDir)
        }

        return await live(token: token, key: key, base: base) { note in
            self.activityFallback(logsURL: logsURL, base: base, note: note)
        }
    }

    /// Shared live-fetch: usage endpoint (cached per account when live), errors → fallback.
    private func live(token: ClaudeOAuthToken, key: String,
                      base: (UsageStatus, [UsageWindow], TokenStats?, String?, Date?) -> ProviderUsage,
                      fallback: (String) -> ProviderUsage) async -> ProviderUsage {
        do {
            let usage = allowKeychain
                ? try await ClaudeTokenProvider.shared.cachedUsage(key: key, accessToken: token.accessToken, api: api)
                : try await api.fetch(accessToken: token.accessToken)
            let windows = usage.windows.sorted { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
            var u = base(windows.isEmpty ? .noData : .ok, windows,
                         nil, windows.isEmpty ? "No active usage windows" : nil, Date())
            if let extra = usage.extra, extra.isEnabled, let credits = extra.usedCredits {
                u.detail = "Extra usage: \(Int(credits)) credits"
            }
            return u
        } catch let ClaudeAPIError.rateLimited(retry) {
            let hint = retry.map { " (retry \(Int($0))s)" } ?? ""
            return fallback("Rate limited\(hint)")
        } catch ClaudeAPIError.unauthorized {
            return fallback("Session expired — reconnect this account")
        } catch {
            return fallback("Endpoint unavailable")
        }
    }

    /// On a live failure, fall back to local activity from the configured logs (if
    /// any); otherwise just surface the note.
    private func activityFallback(logsURL: URL?,
                                  base: (UsageStatus, [UsageWindow], TokenStats?, String?, Date?) -> ProviderUsage,
                                  note: String) -> ProviderUsage {
        if let logsURL, let act = ClaudeJSONLReader.activity(configDir: logsURL) {
            let tokens = TokenStats(totalTokens: act.sevenDayTokens)
            return base(.ok, [], tokens, note + " · " + Self.tokenNote(act), act.lastActivity)
        }
        return base(.notConfigured, [], nil, note, nil)
    }

    private static func tokenNote(_ a: ClaudeTokenActivity) -> String {
        "≈\(compact(a.fiveHourTokens)) in 5h, \(compact(a.sevenDayTokens)) in 7d"
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fk", Double(n) / 1_000)
        default: return String(n)
        }
    }
}
