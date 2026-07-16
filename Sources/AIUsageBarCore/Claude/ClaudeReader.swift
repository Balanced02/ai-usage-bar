import Foundation

/// Produces one `ProviderUsage` per Claude account/profile.
///
/// Token source is our **own** OAuth store (`ClaudeTokenProvider`) — never Claude
/// Code's Keychain item — so nothing prompts for Keychain access. Strategy:
///   1. Identity/cost/local-activity from local files — always available offline.
///   2. Live windows from `GET /api/oauth/usage` using a token we minted, when the
///      account has been added (Settings → Claude → Add account).
///   3. Tokens carry their own account identity, so they map to a configured
///      profile locally (no profile round-trip). A signed-in account with no local
///      profile still gets a live-only card.
public struct ClaudeReader: Sendable {
    public var profiles: [ClaudeProfile]
    public var api: ClaudeUsageAPI
    /// Gates live/token access. Off for the CLI probe and unit tests.
    public var allowKeychain: Bool
    /// Injected tokens for tests (used when `allowKeychain` is false).
    public var tokens: [ClaudeOAuthToken]

    public init(profiles: [ClaudeProfile], api: ClaudeUsageAPI = ClaudeUsageAPI(),
                allowKeychain: Bool = true, tokens: [ClaudeOAuthToken] = []) {
        self.profiles = profiles
        self.api = api
        self.allowKeychain = allowKeychain
        self.tokens = tokens
    }

    /// An identity-only card (no windows) to show instantly while live data loads.
    public static func placeholder(for profile: ClaudeProfile) -> ProviderUsage {
        let account = ClaudeAccountLoader.load(profile)
        return ProviderUsage(
            id: "claude:\(profile.name.lowercased())",
            kind: .claude,
            displayName: "Claude — \(profile.name)",
            accountLabel: account?.emailAddress ?? account?.displayName,
            planType: account?.planLabel,
            status: .noData,
            detail: "Loading…",
            sourcePath: profile.configDir.path
        )
    }

    public func read() async -> [ProviderUsage] {
        let live = allowKeychain ? await ClaudeTokenProvider.shared.validTokens() : tokens

        // Bind each token to the best-matching profile by the identity it carries.
        var tokenForProfile: [String: ClaudeOAuthToken] = [:]
        var usedTokens = Set<Int>()
        for profile in profiles {
            let account = ClaudeAccountLoader.load(profile)
            if let hit = live.enumerated().first(where: { entry in
                !usedTokens.contains(entry.offset) && Self.identityMatches(entry.element, account)
            }) {
                tokenForProfile[profile.id] = hit.element
                usedTokens.insert(hit.offset)
            }
        }
        // Exactly one profile and one token, unmatched: no ambiguity, pair them.
        // (Requires live.count == 1 — with 2+ tokens we'd bind an arbitrary one and
        // drop the others' cards.)
        if profiles.count == 1, live.count == 1, tokenForProfile.isEmpty, let only = live.first {
            tokenForProfile[profiles[0].id] = only
            usedTokens.insert(0)
        }

        var results: [ProviderUsage] = []
        for profile in profiles {
            results.append(await readProfile(profile, token: tokenForProfile[profile.id]))
        }
        // Signed-in accounts with no local profile → live-only cards.
        for entry in live.enumerated() where !usedTokens.contains(entry.offset) {
            results.append(await readAccountOnly(entry.element))
        }
        return results
    }

    static func identityMatches(_ token: ClaudeOAuthToken, _ account: ClaudeAccount?) -> Bool {
        guard let account else { return false }
        // Precise per-account identifiers are definitive: when both sides carry one,
        // it settles the match (== true / != false). A shared organization UUID is
        // only a last resort — two accounts in one org share it, so matching on org
        // alone would bind a token to the wrong same-org profile.
        if let a = token.accountUUID, let b = account.accountUuid { return a == b }
        if let a = token.accountEmail?.lowercased(), let b = account.emailAddress?.lowercased() { return a == b }
        if let a = token.orgUUID, let b = account.organizationUuid { return a == b }
        return false
    }

    private func readProfile(_ profile: ClaudeProfile, token: ClaudeOAuthToken?) async -> ProviderUsage {
        let account = ClaudeAccountLoader.load(profile)
        let label = account?.emailAddress ?? account?.displayName
        let plan = account?.planLabel
        let id = "claude:\(profile.name.lowercased())"

        let cost = await Task.detached(priority: .utility) {
            ClaudeCostReader.summary(for: profile)
        }.value

        func base(status: UsageStatus, windows: [UsageWindow] = [], tokens: TokenStats? = nil,
                  detail: String? = nil, updated: Date? = nil) -> ProviderUsage {
            ProviderUsage(id: id, kind: .claude, displayName: "Claude — \(profile.name)",
                          accountLabel: label, planType: plan, windows: windows, tokens: tokens,
                          cost: cost, status: status, detail: detail, lastUpdated: updated,
                          sourcePath: profile.configDir.path)
        }

        if let token {
            return await live(token: token, base: base) {
                self.activityOrError(profile, base: base, note: $0)
            }
        }
        return activityOrError(profile, base: base, note: "Add a Claude account to see live limits")
    }

    /// A live-only card for a signed-in account that has no local profile/logs.
    private func readAccountOnly(_ token: ClaudeOAuthToken) async -> ProviderUsage {
        let name = token.accountEmail ?? "Account"
        let id = "claude:oauth:\(ClaudeTokenStore.accountKey(for: token))"
        func base(status: UsageStatus, windows: [UsageWindow] = [], tokens: TokenStats? = nil,
                  detail: String? = nil, updated: Date? = nil) -> ProviderUsage {
            ProviderUsage(id: id, kind: .claude, displayName: "Claude — \(name)",
                          accountLabel: token.accountEmail, planType: nil, windows: windows,
                          tokens: tokens, cost: nil, status: status, detail: detail,
                          lastUpdated: updated, sourcePath: nil)
        }
        return await live(token: token, base: base) { base(status: .notConfigured, detail: $0) }
    }

    /// Shared live-fetch: hits the usage endpoint and maps errors to a fallback.
    private func live(token: ClaudeOAuthToken,
                      base: (UsageStatus, [UsageWindow], TokenStats?, String?, Date?) -> ProviderUsage,
                      fallback: (String) -> ProviderUsage) async -> ProviderUsage {
        do {
            let usage = try await api.fetch(accessToken: token.accessToken)
            let windows = usage.windows.sorted { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
            var u = base(windows.isEmpty ? .noData : .ok, windows,
                         nil, windows.isEmpty ? "No active usage windows" : nil, Date())
            if let extra = usage.extra, extra.isEnabled, let credits = extra.usedCredits {
                u.detail = "Extra usage: \(Int(credits)) credits"
            }
            return u
        } catch let ClaudeAPIError.rateLimited(retry) {
            let hint = retry.map { " (retry \(Int($0))s)" } ?? ""
            return fallback("Rate limited\(hint) — using local activity")
        } catch ClaudeAPIError.unauthorized {
            return fallback("Session expired — reconnect this account")
        } catch {
            return fallback("Endpoint unavailable — using local activity")
        }
    }

    /// Fall back to local token activity; if there's none, report the note.
    private func activityOrError(_ profile: ClaudeProfile,
                                 base: (UsageStatus, [UsageWindow], TokenStats?, String?, Date?) -> ProviderUsage,
                                 note: String) -> ProviderUsage {
        if let act = ClaudeJSONLReader.activity(for: profile) {
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
