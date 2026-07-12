import Foundation

public enum ClaudeAPIError: Error, Sendable {
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized              // 401 — token expired/invalid
    case http(Int)
    case transport(String)
    case decode(String)
}

/// Extra (pay-as-you-go) usage block from the endpoint.
public struct ClaudeExtraUsage: Sendable, Hashable {
    public var isEnabled: Bool
    public var monthlyLimit: Double?
    public var usedCredits: Double?
    public var utilization: Double?
}

public struct ClaudeUsage: Sendable {
    public var windows: [UsageWindow]
    public var extra: ClaudeExtraUsage?
}

/// Account identity for a token, from the profile endpoint — used to bind a
/// Keychain credential to the right configured profile.
public struct ClaudeIdentity: Sendable, Hashable {
    public var email: String?
    public var accountUuid: String?
    public var orgUuid: String?
}

/// Client for the undocumented Claude Code OAuth endpoints.
/// `GET https://api.anthropic.com/api/oauth/usage` and `.../api/oauth/profile`.
public struct ClaudeUsageAPI: Sendable {
    public var endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public var profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    public init() {}

    /// Builds a GET request carrying the headers the endpoints require. The
    /// `User-Agent: claude-code/<ver>` is mandatory — a wrong one triggers 429s.
    private func request(_ url: URL, accessToken: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(ClaudeCLI.userAgent(), forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    /// Fetches the account/org identity for a token (for profile mapping).
    public func fetchProfile(accessToken: String) async throws -> ClaudeIdentity {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request(profileEndpoint, accessToken: accessToken))
        } catch {
            throw ClaudeAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ClaudeAPIError.transport("no HTTP response") }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw ClaudeAPIError.unauthorized
        case 429: throw ClaudeAPIError.rateLimited(retryAfter: nil)
        default: throw ClaudeAPIError.http(http.statusCode)
        }
        struct P: Decodable {
            struct Account: Decodable { let uuid: String?; let email: String? }
            struct Org: Decodable { let uuid: String? }
            let account: Account?
            let organization: Org?
        }
        let p = try JSONDecoder().decode(P.self, from: data)
        return ClaudeIdentity(email: p.account?.email, accountUuid: p.account?.uuid, orgUuid: p.organization?.uuid)
    }

    private struct Response: Decodable {
        let five_hour: Win?
        let seven_day: Win?
        let seven_day_opus: Win?
        let seven_day_sonnet: Win?
        let seven_day_haiku: Win?
        let seven_day_fable: Win?
        let extra_usage: Extra?

        struct Win: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        struct Extra: Decodable {
            let is_enabled: Bool?
            let monthly_limit: Double?
            let used_credits: Double?
            let utilization: Double?
        }
    }

    public func fetch(accessToken: String) async throws -> ClaudeUsage {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request(endpoint, accessToken: accessToken))
        } catch {
            throw ClaudeAPIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAPIError.transport("no HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw ClaudeAPIError.unauthorized
        case 429:
            let retry = (http.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init)
            throw ClaudeAPIError.rateLimited(retryAfter: retry)
        default:
            throw ClaudeAPIError.http(http.statusCode)
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ClaudeAPIError.decode(error.localizedDescription)
        }

        var windows: [UsageWindow] = []
        func add(_ w: Response.Win?, kind: WindowKind, minutes: Int, name: String?, hideIfZero: Bool = false) {
            guard let w, let u = w.utilization else { return }
            if hideIfZero && u <= 0 { return }
            windows.append(UsageWindow(kind: kind, usedPercent: u, windowMinutes: minutes,
                                       resetsAt: ISODate.parse(w.resets_at), name: name))
        }
        add(decoded.five_hour, kind: .fiveHour, minutes: 300, name: nil)
        add(decoded.seven_day, kind: .weekly, minutes: 10080, name: nil)
        // Per-model 7-day windows — only shown when actually used.
        add(decoded.seven_day_opus, kind: .weekly, minutes: 10080, name: "7D OPUS", hideIfZero: true)
        add(decoded.seven_day_sonnet, kind: .weekly, minutes: 10080, name: "7D SONNET", hideIfZero: true)
        add(decoded.seven_day_haiku, kind: .weekly, minutes: 10080, name: "7D HAIKU", hideIfZero: true)
        add(decoded.seven_day_fable, kind: .weekly, minutes: 10080, name: "7D FABLE", hideIfZero: true)

        let extra = decoded.extra_usage.map {
            ClaudeExtraUsage(isEnabled: $0.is_enabled ?? false,
                             monthlyLimit: $0.monthly_limit,
                             usedCredits: $0.used_credits,
                             utilization: $0.utilization)
        }
        return ClaudeUsage(windows: windows, extra: extra)
    }
}
