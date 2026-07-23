import Foundation

/// User-controlled settings for one signed-in Claude account, keyed by the account's
/// Keychain key (`ClaudeTokenStore.accountKey`). Persisted outside the Keychain (it
/// holds no secrets). `logsDir` is opt-in: when set, the reader computes the $ /
/// token breakdown from that config dir's logs; when nil, the account shows live
/// limits only (there is no cost API — it can only come from local logs).
public struct ClaudeAccountConfig: Codable, Sendable, Hashable {
    /// User-assigned display name; falls back to the account email in the UI.
    public var name: String?
    /// Absolute path to the Claude config dir (containing `projects/`) whose logs
    /// this account's cost is read from. Nil = cost off.
    public var logsDir: String?

    public init(name: String? = nil, logsDir: String? = nil) {
        self.name = name
        self.logsDir = logsDir
    }

    public var logsURL: URL? { logsDir.map { URL(fileURLWithPath: $0) } }
}
