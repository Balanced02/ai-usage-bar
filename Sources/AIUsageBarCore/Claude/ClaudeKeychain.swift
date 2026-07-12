import Foundation
import Security

/// An OAuth credential blob stored by Claude Code in the login Keychain.
public struct ClaudeCredential: Sendable {
    public var service: String            // e.g. "Claude Code-credentials-1a2b3c4d"
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAtMs: Double?       // epoch milliseconds
    public var scopes: [String]
    public var subscriptionType: String?

    public var isExpired: Bool {
        guard let ms = expiresAtMs else { return false }
        return Date().timeIntervalSince1970 * 1000 >= ms
    }
}

/// Reads Claude Code's OAuth credentials from the macOS Keychain.
///
/// The service name carries a per-config-dir hash suffix that cannot be reliably
/// computed, so we *enumerate* every `Claude Code-credentials-*` generic-password
/// item. Listing attributes does not prompt; reading the secret data prompts once
/// per app code-signature (the standard "Always Allow" dialog).
public enum ClaudeKeychain {
    public static let servicePrefix = "Claude Code-credentials"

    /// Service names of all Claude Code credential items (no auth prompt).
    public static func listServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }

        var services = Set<String>()
        for item in items {
            if let svc = item[kSecAttrService as String] as? String,
               svc.hasPrefix(servicePrefix) {
                services.insert(svc)
            }
        }
        return services.sorted()
    }

    /// Reads and parses one credential item (prompts for access on first use).
    public static func readCredential(service: String) -> ClaudeCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String
        else { return nil }

        return ClaudeCredential(
            service: service,
            accessToken: access,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAtMs: (oauth["expiresAt"] as? NSNumber)?.doubleValue,
            scopes: (oauth["scopes"] as? [String]) ?? [],
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    /// All readable credentials (each read may prompt on first access).
    public static func allCredentials() -> [ClaudeCredential] {
        listServices().compactMap(readCredential(service:))
    }
}

/// Minimal JWT payload decoder, used to try to bind a Keychain token to a profile
/// by matching account/organization identifiers. Access tokens may be opaque
/// (non-JWT), in which case this returns nil and callers fall back to other mapping.
public enum JWT {
    public static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4.
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
