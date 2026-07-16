import Foundation
import Security

/// Persists our own OAuth tokens in the login Keychain — one generic-password item
/// per Claude account, keyed by account UUID.
///
/// The whole point of minting our own token is this store: because **this app**
/// creates the items, macOS auto-grants this (signed) app read access with no
/// prompt, and refreshes update each item **in place** (`SecItemUpdate`) so its
/// access-control list is never wiped. That is the one difference from reading
/// Claude Code's item — Claude Code deletes + re-adds on refresh, resetting the ACL
/// and forcing macOS to re-prompt. Ours never re-prompts on a stable signature.
public enum ClaudeTokenStore {
    public static let service = "com.aiusagebar.AIUsageBar.claude-oauth"

    /// The per-account Keychain key. UUID first (stable), then email, then a
    /// singleton fallback. The `"default"` fallback is effectively unreachable: sign-in
    /// resolves identity before storing (the token exchange returns `account.uuid`,
    /// and `ClaudeTokenProvider.signIn` fills it from the profile endpoint otherwise),
    /// and refresh carries the stored identity forward — so a real token always keys on
    /// its UUID. If identity ever firms up after a store, `refreshShared` deletes the
    /// old-keyed item, so nothing is orphaned.
    public static func accountKey(for token: ClaudeOAuthToken) -> String {
        token.accountUUID ?? token.accountEmail ?? "default"
    }

    /// Upsert. Updates in place when the item exists (preserving the ACL); adds it
    /// otherwise. `ThisDeviceOnly` after first unlock so background refresh works
    /// but the token never syncs to iCloud Keychain.
    @discardableResult
    public static func save(_ token: ClaudeOAuthToken) -> Bool {
        guard let data = try? JSONEncoder().encode(token) else { return false }
        let account = accountKey(for: token)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(identity as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            return SecItemAdd(identity.merging(attrs) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Reads one account's token (no prompt for an item we created).
    public static func load(account: String) -> ClaudeOAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(ClaudeOAuthToken.self, from: data)
    }

    /// All stored tokens. No prompt: these are our own items. Two steps — list the
    /// account keys (attributes only), then read each item's data — because
    /// `kSecReturnData` + `kSecMatchLimitAll` in one query is rejected (errSecParam).
    public static func all() -> [ClaudeOAuthToken] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        return accounts.compactMap { load(account: $0) }
    }

    @discardableResult
    public static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
