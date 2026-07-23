import Foundation
import AIUsageBarCore

/// Persisted provider settings. Claude accounts come from OAuth sign-in (the token
/// store); this holds the user's per-account config (name + optional logs dir), keyed
/// by `ClaudeTokenStore.accountKey`.
public struct ProviderSettings: Codable, Sendable, Hashable {
    public static let defaultsKey = "providerSettings"
    public var codexHome: URL?
    public var geminiHome: URL?
    public var claudeAccountConfigs: [String: ClaudeAccountConfig]
    public var customProviders: [CustomProviderConfig]

    public init(codexHome: URL? = nil, geminiHome: URL? = nil,
                claudeAccountConfigs: [String: ClaudeAccountConfig] = [:],
                customProviders: [CustomProviderConfig] = []) {
        self.codexHome = codexHome?.standardizedFileURL
        self.geminiHome = geminiHome?.standardizedFileURL
        self.claudeAccountConfigs = claudeAccountConfigs
        self.customProviders = customProviders
    }

    // Tolerant decoder so older saved settings (without newer fields, or with the
    // retired `manualClaudeProfiles` key) still load.
    private enum CodingKeys: String, CodingKey {
        case codexHome, geminiHome, claudeAccountConfigs, customProviders
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codexHome = try c.decodeIfPresent(URL.self, forKey: .codexHome)
        geminiHome = try c.decodeIfPresent(URL.self, forKey: .geminiHome)
        claudeAccountConfigs = try c.decodeIfPresent([String: ClaudeAccountConfig].self,
                                                     forKey: .claudeAccountConfigs) ?? [:]
        customProviders = try c.decodeIfPresent([CustomProviderConfig].self, forKey: .customProviders) ?? []
    }

    public func usageConfig(codexEnabled: Bool, claudeEnabled: Bool, geminiEnabled: Bool) -> UsageConfig {
        UsageConfig(codexEnabled: codexEnabled, claudeEnabled: claudeEnabled,
                    geminiEnabled: geminiEnabled, codexHome: codexHome, geminiHome: geminiHome,
                    claudeAccountConfigs: claudeAccountConfigs, customProviders: customProviders)
    }

    public static func load(from defaults: UserDefaults) -> ProviderSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else { return ProviderSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: ProviderSettings.defaultsKey)
    }
}
