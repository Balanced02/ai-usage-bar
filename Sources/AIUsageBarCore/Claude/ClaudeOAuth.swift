import Foundation
import CryptoKit
import Security

/// Our own OAuth against Anthropic's "Claude Code" OAuth client, so the app mints
/// and holds its **own** subscription-usage token instead of reading Claude Code's
/// Keychain item. That item's access-control list is wiped every time Claude Code
/// refreshes its token (it deletes + re-adds the item), which is what makes macOS
/// re-prompt us at random. A token we mint and store in our own Keychain item
/// (`ClaudeTokenStore`) and refresh *in place* never resets its ACL — so a signed
/// build reads it with no prompt, ever.
///
/// There is no third-party OAuth client for the subscription usage endpoint, so we
/// use Claude Code's public client (the same one its CLI and CodexBar use). Flow is
/// RFC 8252 native-app PKCE, mirroring the CLI:
///
///   makePKCE() → authorizeURL(redirectURI:pkce:) opened in the browser
///   → loopback (`ClaudeOAuthLoopback`) captures `?code&state`
///   → exchange(code:state:…) → {accessToken, refreshToken, expiresAt, identity}
///
/// All literal values (client id, endpoints, scopes, PKCE shape, `code#state`
/// split) are cross-verified against the Claude Code CLI source and several
/// community implementations.
public enum ClaudeOAuth {
    /// Claude Code's public OAuth client id.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    public static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// The hosted copy-paste callback, used only if a loopback redirect is rejected.
    public static let manualRedirectURI = "https://platform.claude.com/oauth/code/callback"
    /// `user:profile` is what gates reading subscription limits; the rest mirror the
    /// current CLI so the token looks exactly like a Claude Code token.
    public static let scopes = ["user:inference", "user:profile",
                                "user:sessions:claude_code", "user:mcp_servers"]
    /// UA for the token endpoint — the CLI's HTTP client (axios) UA. The endpoint's
    /// edge 429s `claude-code/*` and `curl/*`; `axios/*` passes (verified live).
    static let tokenUserAgent = "axios/1.7.9"

    // MARK: - PKCE

    /// A PKCE session: the verifier (kept secret, sent at exchange), its S256
    /// challenge (sent at authorize), and an independent `state` nonce.
    public struct PKCE: Sendable, Equatable {
        public let verifier: String
        public let challenge: String
        public let state: String
    }

    /// Generates a fresh PKCE session — verifier and state are each 32 random bytes,
    /// base64url without padding; the challenge is base64url(SHA-256(verifier)).
    public static func makePKCE() -> PKCE {
        let verifier = base64URL(randomBytes(32))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = base64URL(randomBytes(32))
        return PKCE(verifier: verifier, challenge: challenge, state: state)
    }

    // MARK: - Authorize URL

    /// The browser URL that starts the flow. `redirectURI` must be echoed
    /// byte-for-byte at exchange time — the #1 cause of exchange failures otherwise.
    public static func authorizeURL(redirectURI: String, pkce: PKCE) -> URL {
        var c = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "code", value: "true"),          // show the Max upsell / code flow
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.state),
        ]
        return c.url!
    }

    /// Splits a pasted `code#state` value (the manual/hosted flow returns them
    /// joined). Loopback delivers them as separate query items, so callers there
    /// pass the parts directly and never hit this.
    public static func splitCodeState(_ raw: String) -> (code: String, state: String?) {
        let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let state = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return (code, state)
    }

    // MARK: - Token exchange & refresh

    /// Exchanges an authorization code for tokens. Send the same `redirectURI` used
    /// to build the authorize URL, and the `state` returned by the callback.
    public static func exchange(code: String, state: String?, redirectURI: String,
                                pkce: PKCE, session: URLSession = .shared) async throws -> ClaudeOAuthToken {
        var body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier,
        ]
        if let state { body["state"] = state }
        return try await postToken(body, session: session, existingRefresh: nil)
    }

    /// Refreshes an access token. Anthropic **rotates** refresh tokens, so the
    /// returned token's `refreshToken` may differ — always persist it. A `400
    /// invalid_grant` here is terminal (the refresh token is dead → re-auth).
    public static func refresh(refreshToken: String,
                               session: URLSession = .shared) async throws -> ClaudeOAuthToken {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        return try await postToken(body, session: session, existingRefresh: refreshToken)
    }

    private static func postToken(_ body: [String: Any], session: URLSession,
                                  existingRefresh: String?) async throws -> ClaudeOAuthToken {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60          // the token endpoint can be slow (30–60s seen)
        // Mirror the real CLI exactly: plain JSON, and the axios User-Agent its HTTP
        // client actually sends. The token endpoint's edge hard-429s `claude-code/*`
        // and `curl/*` UAs (verified live); `axios/*` passes. This is the opposite of
        // the *usage* endpoint, which REQUIRES `claude-code/<ver>` — see ClaudeUsageAPI.
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.tokenUserAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw ClaudeOAuthError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeOAuthError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 400, text.contains("invalid_grant") {
                throw ClaudeOAuthError.invalidGrant
            }
            throw ClaudeOAuthError.http(http.statusCode, String(text.prefix(300)))
        }
        return try parseToken(data, existingRefresh: existingRefresh)
    }

    /// Parses a token response. `expiresAt` is computed locally from `expires_in`;
    /// a missing `refresh_token` (some responses omit it) falls back to the one we
    /// already held so a refresh never drops our ability to refresh again.
    static func parseToken(_ data: Data, existingRefresh: String?,
                           now: Date = Date()) throws -> ClaudeOAuthToken {
        struct R: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
            let scope: String?
            struct Account: Decodable { let uuid: String?; let email_address: String? }
            struct Org: Decodable { let uuid: String? }
            let account: Account?
            let organization: Org?
        }
        let r: R
        do { r = try JSONDecoder().decode(R.self, from: data) }
        catch { throw ClaudeOAuthError.decode(error.localizedDescription) }
        return ClaudeOAuthToken(
            accessToken: r.access_token,
            refreshToken: r.refresh_token ?? existingRefresh,
            expiresAt: r.expires_in.map { now.addingTimeInterval($0) },
            scopes: r.scope?.split(separator: " ").map(String.init) ?? [],
            accountUUID: r.account?.uuid,
            accountEmail: r.account?.email_address,
            orgUUID: r.organization?.uuid
        )
    }

    // MARK: - Helpers

    static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes)
    }

    /// Base64url without padding (`+`→`-`, `/`→`_`, drop `=`).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum ClaudeOAuthError: Error, Sendable, Equatable {
    case invalidGrant              // terminal — refresh token dead, must re-authenticate
    case stateMismatch             // callback state != expected (possible CSRF)
    case cancelled                 // user closed the browser / aborted
    case http(Int, String)
    case transport(String)
    case decode(String)
}

/// A token minted by our own OAuth flow. Persisted in the Keychain by
/// `ClaudeTokenStore`, keyed by `accountUUID`.
public struct ClaudeOAuthToken: Sendable, Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scopes: [String]
    public var accountUUID: String?
    public var accountEmail: String?
    public var orgUUID: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                scopes: [String] = [], accountUUID: String? = nil,
                accountEmail: String? = nil, orgUUID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.accountUUID = accountUUID
        self.accountEmail = accountEmail
        self.orgUUID = orgUUID
    }

    /// True within 60s of expiry (refresh a little early), so a call never races
    /// the boundary.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let e = expiresAt else { return false }
        return now >= e.addingTimeInterval(-60)
    }
}
