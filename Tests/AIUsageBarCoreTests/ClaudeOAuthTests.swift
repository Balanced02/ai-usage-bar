import XCTest
import CryptoKit
@testable import AIUsageBarCore

final class ClaudeOAuthTests: XCTestCase {

    // MARK: PKCE

    func testPKCEChallengeIsS256OfVerifier() {
        let pkce = ClaudeOAuth.makePKCE()
        // Recompute base64url(SHA256(verifier)) independently and compare.
        let expected = ClaudeOAuth.base64URL(Data(SHA256.hash(data: Data(pkce.verifier.utf8))))
        XCTAssertEqual(pkce.challenge, expected)
        XCTAssertFalse(pkce.verifier.isEmpty)
        XCTAssertFalse(pkce.state.isEmpty)
        XCTAssertNotEqual(pkce.verifier, pkce.state)   // independent nonces
    }

    func testBase64URLHasNoPaddingOrUnsafeChars() {
        // 32 bytes → 44-char base64 with padding; base64url must strip it.
        let s = ClaudeOAuth.base64URL(Data(repeating: 0xAB, count: 32))
        XCTAssertFalse(s.contains("="))
        XCTAssertFalse(s.contains("+"))
        XCTAssertFalse(s.contains("/"))
    }

    // MARK: Authorize URL

    func testAuthorizeURLContainsRequiredParams() {
        let pkce = ClaudeOAuth.makePKCE()
        let url = ClaudeOAuth.authorizeURL(redirectURI: "http://localhost:51234/callback", pkce: pkce)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }

        XCTAssertEqual(url.host, "claude.ai")
        XCTAssertEqual(v("client_id"), ClaudeOAuth.clientID)
        XCTAssertEqual(v("response_type"), "code")
        XCTAssertEqual(v("code"), "true")
        XCTAssertEqual(v("code_challenge_method"), "S256")
        XCTAssertEqual(v("code_challenge"), pkce.challenge)
        XCTAssertEqual(v("state"), pkce.state)
        XCTAssertEqual(v("redirect_uri"), "http://localhost:51234/callback")
        // The subscription-limits scope must be present.
        XCTAssertTrue((v("scope") ?? "").contains("user:profile"))
    }

    func testSplitCodeState() {
        XCTAssertEqual(ClaudeOAuth.splitCodeState("abc#xyz").code, "abc")
        XCTAssertEqual(ClaudeOAuth.splitCodeState("abc#xyz").state, "xyz")
        XCTAssertNil(ClaudeOAuth.splitCodeState("nostate").state)
        XCTAssertEqual(ClaudeOAuth.splitCodeState("  a # b ").code, "a")   // trimmed
        XCTAssertEqual(ClaudeOAuth.splitCodeState("  a # b ").state, "b")
    }

    // MARK: Token parsing

    func testParseTokenRotatesRefreshAndComputesExpiry() throws {
        let json = """
        {"access_token":"acc-1","refresh_token":"ref-2","expires_in":3600,
         "scope":"user:profile user:inference",
         "account":{"uuid":"u-1","email_address":"you@example.com"},
         "organization":{"uuid":"o-1"}}
        """
        let now = Date(timeIntervalSince1970: 1_000_000)
        let t = try ClaudeOAuth.parseToken(Data(json.utf8), existingRefresh: "old", now: now)
        XCTAssertEqual(t.accessToken, "acc-1")
        XCTAssertEqual(t.refreshToken, "ref-2")                 // rotated
        XCTAssertEqual(t.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(t.accountUUID, "u-1")
        XCTAssertEqual(t.accountEmail, "you@example.com")
        XCTAssertEqual(t.orgUUID, "o-1")
        XCTAssertEqual(t.scopes, ["user:profile", "user:inference"])
    }

    func testParseTokenKeepsOldRefreshWhenAbsent() throws {
        let json = #"{"access_token":"acc-1","expires_in":60}"#
        let t = try ClaudeOAuth.parseToken(Data(json.utf8), existingRefresh: "keep-me")
        XCTAssertEqual(t.refreshToken, "keep-me")
    }

    func testTokenExpiryBoundary() {
        let past = ClaudeOAuthToken(accessToken: "a", expiresAt: Date(timeIntervalSinceNow: -10))
        XCTAssertTrue(past.isExpired())
        let soon = ClaudeOAuthToken(accessToken: "a", expiresAt: Date(timeIntervalSinceNow: 30))
        XCTAssertTrue(soon.isExpired())     // within the 60s early-refresh window
        let later = ClaudeOAuthToken(accessToken: "a", expiresAt: Date(timeIntervalSinceNow: 600))
        XCTAssertFalse(later.isExpired())
        let never = ClaudeOAuthToken(accessToken: "a", expiresAt: nil)
        XCTAssertFalse(never.isExpired())
    }

    // MARK: Loopback request parsing

    func testLoopbackParsesCallback() {
        let req = "GET /callback?code=AUTH123&state=ST456 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertEqual(ClaudeOAuthLoopback.parse(req), .code("AUTH123", "ST456"))
    }

    func testLoopbackParsesErrorAndIgnoresNoise() {
        let err = "GET /callback?error=access_denied HTTP/1.1\r\n\r\n"
        XCTAssertEqual(ClaudeOAuthLoopback.parse(err), .error("access_denied"))
        let favicon = "GET /favicon.ico HTTP/1.1\r\n\r\n"
        XCTAssertEqual(ClaudeOAuthLoopback.parse(favicon), .ignore)
        let noCode = "GET /callback HTTP/1.1\r\n\r\n"
        XCTAssertEqual(ClaudeOAuthLoopback.parse(noCode), .ignore)
    }

    // MARK: Account config

    func testAccountConfigLogsURL() {
        XCTAssertNil(ClaudeAccountConfig().logsURL)
        XCTAssertEqual(ClaudeAccountConfig(logsDir: "/tmp/.claude").logsURL,
                       URL(fileURLWithPath: "/tmp/.claude"))
    }
}
