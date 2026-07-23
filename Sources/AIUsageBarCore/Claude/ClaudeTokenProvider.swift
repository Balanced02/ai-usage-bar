import Foundation

/// Owns the lifecycle of our OAuth tokens: the interactive sign-in, the in-memory
/// cache, and in-place refresh. An actor so concurrent refreshes never race — Anthropic
/// rotates refresh tokens, and firing two refreshes with the same token makes the
/// second fail.
public actor ClaudeTokenProvider {
    public static let shared = ClaudeTokenProvider()
    public init() {}

    private var cache: [String: ClaudeOAuthToken] = [:]
    /// One in-flight refresh Task per account key, so concurrent `validTokens()`
    /// calls coalesce onto a single network refresh instead of racing the rotation.
    private var refreshing: [String: Task<ClaudeOAuthToken, Error>] = [:]
    /// Per-account usage response cache (TTL-bounded) so re-rendering after a config
    /// change (rename, cost folder) doesn't re-hit the rate-limited usage endpoint.
    private var usageCache: [String: (usage: ClaudeUsage, at: Date)] = [:]

    /// Usage for an account, served from cache within `ttl` seconds. On a **transient**
    /// error (rate-limit / network blip) the last good usage is served up to `staleTTL`
    /// so the % bars don't vanish; `unauthorized` is terminal and always propagates so
    /// the card can prompt to reconnect.
    public func cachedUsage(key: String, accessToken: String, api: ClaudeUsageAPI,
                            ttl: TimeInterval = 180, staleTTL: TimeInterval = 1800,
                            now: Date = Date()) async throws -> ClaudeUsage {
        if let hit = usageCache[key], now.timeIntervalSince(hit.at) < ttl { return hit.usage }
        do {
            let usage = try await api.fetch(accessToken: accessToken)
            usageCache[key] = (usage, now)
            return usage
        } catch ClaudeAPIError.unauthorized {
            throw ClaudeAPIError.unauthorized                       // terminal — never mask
        } catch {
            if let hit = usageCache[key], now.timeIntervalSince(hit.at) < staleTTL { return hit.usage }
            throw error
        }
    }

    // MARK: Interactive sign-in (not actor-isolated, so the up-to-5-min browser
    // wait never blocks a usage refresh).

    /// Runs the full PKCE loopback flow and stores the token. `openURL` opens the
    /// browser (injected so Core stays UI-free). Throws `.stateMismatch`,
    /// `.cancelled`, or a transport/HTTP error.
    public static func signIn(openURL: @Sendable @escaping (URL) -> Void) async throws -> ClaudeOAuthToken {
        let pkce = ClaudeOAuth.makePKCE()
        let loopback = try ClaudeOAuthLoopback()
        defer { loopback.stop() }

        let redirect = loopback.redirectURI
        openURL(ClaudeOAuth.authorizeURL(redirectURI: redirect, pkce: pkce))
        let cb = try await loopback.waitForCallback()
        // A genuine loopback callback always echoes the state we sent, so require it
        // present AND matching — an absent state means a forged/injected callback.
        guard cb.state == pkce.state else { throw ClaudeOAuthError.stateMismatch }

        var token = try await ClaudeOAuth.exchange(code: cb.code, state: cb.state,
                                                   redirectURI: redirect, pkce: pkce)
        // The token response usually carries identity; if the UUID is missing, ask the
        // profile endpoint — the account key is the UUID, so resolving it up front keeps
        // the key (and the config keyed by it) stable across future refreshes.
        if token.accountUUID == nil,
           let id = try? await ClaudeUsageAPI().fetchProfile(accessToken: token.accessToken) {
            token.accountEmail = token.accountEmail ?? id.email
            token.accountUUID = id.accountUuid
            token.orgUUID = token.orgUUID ?? id.orgUuid
        }
        await shared.store(token)
        return token
    }

    // MARK: Token access

    /// A valid (non-expired) token for every stored account, refreshing in place as
    /// needed. A dead refresh token (`invalid_grant`) leaves the account stored so
    /// the UI can prompt to reconnect; the (expired) token is still returned so the
    /// reader surfaces a 401 → "reconnect" rather than silently dropping the card.
    public func validTokens() async -> [ClaudeOAuthToken] {
        var out: [ClaudeOAuthToken] = []
        for stored in ClaudeTokenStore.all() {
            let key = ClaudeTokenStore.accountKey(for: stored)
            if let cached = cache[key], !cached.isExpired() { out.append(cached); continue }
            guard stored.isExpired(), stored.refreshToken != nil else {
                cache[key] = stored; out.append(stored); continue
            }
            do {
                out.append(try await refreshShared(key: key, stored: stored))
            } catch {
                out.append(stored)   // transient or terminal — let the reader decide
            }
        }
        return out
    }

    /// Refreshes one account, coalescing concurrent refreshes for the same key so a
    /// rotating refresh token is never spent twice (the loser would get
    /// `invalid_grant` and kill a still-valid session). Persists in place; if the
    /// identity-derived key changed, deletes the stale item so nothing is orphaned.
    private func refreshShared(key: String, stored: ClaudeOAuthToken) async throws -> ClaudeOAuthToken {
        if let cached = cache[key], !cached.isExpired() { return cached }
        if let inFlight = refreshing[key] { return try await inFlight.value }

        let task = Task { () throws -> ClaudeOAuthToken in
            var fresh = try await ClaudeOAuth.refresh(refreshToken: stored.refreshToken ?? "")
            fresh.accountUUID = fresh.accountUUID ?? stored.accountUUID
            fresh.accountEmail = fresh.accountEmail ?? stored.accountEmail
            fresh.orgUUID = fresh.orgUUID ?? stored.orgUUID
            return fresh
        }
        refreshing[key] = task
        defer { refreshing[key] = nil }

        let fresh = try await task.value
        let newKey = ClaudeTokenStore.accountKey(for: fresh)
        ClaudeTokenStore.save(fresh)
        if newKey != key {                       // identity firmed up → drop the old item
            ClaudeTokenStore.delete(account: key)
            cache[key] = nil
        }
        cache[newKey] = fresh
        return fresh
    }

    /// The stored accounts (identity only), for the Settings list. No network.
    public nonisolated func accounts() -> [ClaudeOAuthToken] { ClaudeTokenStore.all() }

    public func store(_ token: ClaudeOAuthToken) {
        ClaudeTokenStore.save(token)
        cache[ClaudeTokenStore.accountKey(for: token)] = token
    }

    public func signOut(account: String) {
        ClaudeTokenStore.delete(account: account)
        cache[account] = nil
        usageCache[account] = nil
    }
}
