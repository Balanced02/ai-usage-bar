import Foundation

/// Produces one `ProviderUsage` per configured Claude profile.
///
/// Strategy per profile:
///   1. Identity (email/plan/tier) from `.claude.json` — always available offline.
///   2. Live windows from `GET /api/oauth/usage` using the profile's Keychain token
///      (mapped by JWT account id, else positionally when counts line up).
///   3. If the endpoint is unavailable, fall back to a token-activity summary from
///      the local JSONL logs — shown as activity, never as a limit %.
public struct ClaudeReader: Sendable {
    public var profiles: [ClaudeProfile]
    public var api: ClaudeUsageAPI
    /// Allows disabling Keychain/network access (e.g. for the CLI probe).
    public var allowKeychain: Bool

    public init(profiles: [ClaudeProfile], api: ClaudeUsageAPI = ClaudeUsageAPI(),
                allowKeychain: Bool = true) {
        self.profiles = profiles
        self.api = api
        self.allowKeychain = allowKeychain
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
        let credentials = allowKeychain ? ClaudeKeychain.allCredentials() : []
        let mapping = await resolveMapping(credentials)

        var results: [ProviderUsage] = []
        for profile in profiles {
            results.append(await readProfile(profile, credential: mapping[profile.id]))
        }
        return results
    }

    private func readProfile(_ profile: ClaudeProfile, credential: ClaudeCredential?) async -> ProviderUsage {
        let account = ClaudeAccountLoader.load(profile)
        let label = account?.emailAddress ?? account?.displayName
        let plan = account?.planLabel
        let id = "claude:\(profile.name.lowercased())"

        func base(status: UsageStatus, windows: [UsageWindow] = [], tokens: TokenStats? = nil,
                  detail: String? = nil, updated: Date? = nil) -> ProviderUsage {
            ProviderUsage(id: id, kind: .claude, displayName: "Claude — \(profile.name)",
                          accountLabel: label, planType: plan, windows: windows, tokens: tokens,
                          status: status, detail: detail, lastUpdated: updated,
                          sourcePath: profile.configDir.path)
        }

        // 1. Live endpoint.
        if let credential, !credential.isExpired {
            do {
                let usage = try await api.fetch(accessToken: credential.accessToken)
                let windows = usage.windows.sorted { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
                var u = base(status: windows.isEmpty ? .noData : .ok, windows: windows,
                             detail: windows.isEmpty ? "No active usage windows" : nil, updated: Date())
                if let extra = usage.extra, extra.isEnabled, let credits = extra.usedCredits {
                    u.detail = "Extra usage: \(Int(credits)) credits"
                }
                return u
            } catch let ClaudeAPIError.rateLimited(retry) {
                let hint = retry.map { " (retry \(Int($0))s)" } ?? ""
                return activityOrError(profile, base: base, note: "Rate limited\(hint) — using local activity")
            } catch ClaudeAPIError.unauthorized {
                return activityOrError(profile, base: base, note: "Token expired — run Claude Code to refresh")
            } catch {
                return activityOrError(profile, base: base, note: "Endpoint unavailable — using local activity")
            }
        }

        // 2. No usable token.
        if credential?.isExpired == true {
            return activityOrError(profile, base: base, note: "Token expired — run Claude Code to refresh")
        }
        let note = allowKeychain ? "Not signed in on this profile" : "Live limits disabled"
        return activityOrError(profile, base: base, note: note)
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

    // MARK: Credential → profile mapping

    /// Binds each Keychain credential to a configured profile by its real account
    /// identity from the profile endpoint (email / org UUID / account UUID matched
    /// against each `.claude.json`). This avoids mislabeling — the Keychain suffix
    /// can't be computed and a token's account isn't guessable from local files.
    private func resolveMapping(_ creds: [ClaudeCredential]) async -> [String: ClaudeCredential] {
        guard !creds.isEmpty else { return [:] }

        var identified: [(cred: ClaudeCredential, id: ClaudeIdentity?)] = []
        for cred in creds where !cred.isExpired {
            let id = try? await api.fetchProfile(accessToken: cred.accessToken)
            identified.append((cred, id))
        }

        var map: [String: ClaudeCredential] = [:]
        var usedServices = Set<String>()
        for profile in profiles {
            let account = ClaudeAccountLoader.load(profile)
            if let hit = identified.first(where: { entry in
                guard !usedServices.contains(entry.cred.service), let id = entry.id else { return false }
                if let a = id.email?.lowercased(), let b = account?.emailAddress?.lowercased(), a == b { return true }
                if let a = id.orgUuid, let b = account?.organizationUuid, a == b { return true }
                if let a = id.accountUuid, let b = account?.accountUuid, a == b { return true }
                return false
            }) {
                map[profile.id] = hit.cred
                usedServices.insert(hit.cred.service)
            }
        }

        // Safe only when there's a single profile — no ambiguity to mislabel.
        if profiles.count == 1, map.isEmpty, let only = identified.first(where: { $0.id != nil })?.cred ?? creds.first {
            map[profiles[0].id] = only
        }
        return map
    }
}
