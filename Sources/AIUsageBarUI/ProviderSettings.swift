import Foundation
import AIUsageBarCore

public struct ManualClaudeProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var configDir: URL

    public init(id: UUID = UUID(), name: String, configDir: URL) {
        self.id = id
        self.name = name
        self.configDir = configDir.standardizedFileURL
    }

    func asClaudeProfile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeProfile {
        let root = configDir.standardizedFileURL
        let defaultRoot = home.appendingPathComponent(".claude").standardizedFileURL
        return ClaudeProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                             configDir: root, isDefault: root.path == defaultRoot.path)
    }
}

public enum ProviderSettingsError: LocalizedError, Equatable {
    case emptyProfileName
    case duplicateProfilePath(String)
    case duplicateProfileName(String)

    public var errorDescription: String? {
        switch self {
        case .emptyProfileName:
            return "Each Claude profile needs a name."
        case .duplicateProfilePath:
            return "Each manual Claude profile must use a different folder."
        case .duplicateProfileName:
            return "Claude profile names must be unique."
        }
    }
}

public struct ProviderSettings: Codable, Sendable, Hashable {
    public static let defaultsKey = "providerSettings"
    public var codexHome: URL?
    public var geminiHome: URL?
    public var manualClaudeProfiles: [ManualClaudeProfile]
    public var customProviders: [CustomProviderConfig]

    public init(codexHome: URL? = nil, geminiHome: URL? = nil,
                manualClaudeProfiles: [ManualClaudeProfile] = [],
                customProviders: [CustomProviderConfig] = []) {
        self.codexHome = codexHome?.standardizedFileURL
        self.geminiHome = geminiHome?.standardizedFileURL
        self.manualClaudeProfiles = manualClaudeProfiles
        self.customProviders = customProviders
    }

    // Tolerant decoder so older saved settings (without newer fields) still load.
    private enum CodingKeys: String, CodingKey {
        case codexHome, geminiHome, manualClaudeProfiles, customProviders
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codexHome = try c.decodeIfPresent(URL.self, forKey: .codexHome)
        geminiHome = try c.decodeIfPresent(URL.self, forKey: .geminiHome)
        manualClaudeProfiles = try c.decodeIfPresent([ManualClaudeProfile].self, forKey: .manualClaudeProfiles) ?? []
        customProviders = try c.decodeIfPresent([CustomProviderConfig].self, forKey: .customProviders) ?? []
    }

    public func resolvedClaudeProfiles(discoveredProfiles: [ClaudeProfile]) throws -> [ClaudeProfile] {
        var manualByPath: [String: ClaudeProfile] = [:]
        for entry in manualClaudeProfiles {
            let profile = entry.asClaudeProfile()
            let path = profile.configDir.standardizedFileURL.path
            guard manualByPath[path] == nil else { throw ProviderSettingsError.duplicateProfilePath(path) }
            manualByPath[path] = profile
        }

        var result: [ClaudeProfile] = []
        var emittedPaths = Set<String>()
        for automatic in discoveredProfiles {
            let path = automatic.configDir.standardizedFileURL.path
            guard emittedPaths.insert(path).inserted else { continue }
            result.append(manualByPath.removeValue(forKey: path) ?? automatic)
        }
        for entry in manualClaudeProfiles {
            let profile = entry.asClaudeProfile()
            let path = profile.configDir.standardizedFileURL.path
            guard emittedPaths.insert(path).inserted else { continue }
            result.append(profile)
        }

        var names = Set<String>()
        for profile in result {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ProviderSettingsError.emptyProfileName }
            guard names.insert(name.lowercased()).inserted else {
                throw ProviderSettingsError.duplicateProfileName(name)
            }
        }
        return result
    }

    public func usageConfig(codexEnabled: Bool, claudeEnabled: Bool, geminiEnabled: Bool,
                            discoveredProfiles: [ClaudeProfile]) throws -> UsageConfig {
        UsageConfig(codexEnabled: codexEnabled, claudeEnabled: claudeEnabled,
                    geminiEnabled: geminiEnabled, codexHome: codexHome,
                    geminiHome: geminiHome,
                    claudeProfiles: try resolvedClaudeProfiles(discoveredProfiles: discoveredProfiles),
                    customProviders: customProviders)
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
