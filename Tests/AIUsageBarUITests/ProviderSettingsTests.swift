import AppKit
import Foundation
import XCTest
import AIUsageBarCore
@testable import AIUsageBar
@testable import AIUsageBarUI

final class ProviderSettingsTests: XCTestCase {
    @MainActor
    func testSettingsCloseCreatesFreshSessionButVisibleOpenKeepsCurrentSession() {
        let delegate = AppDelegate()

        delegate.showSettings()
        guard let firstWindow = settingsWindow() else {
            XCTFail("Settings window should be visible after opening")
            return
        }
        guard let firstSession = firstWindow.contentViewController else {
            XCTFail("Settings window should have a hosting controller")
            return
        }

        delegate.showSettings()
        guard let visibleSession = settingsWindow()?.contentViewController else {
            XCTFail("Settings window should stay visible when reopened")
            return
        }
        XCTAssertTrue(firstSession === visibleSession)

        firstWindow.close()
        delegate.showSettings()

        guard let reopenedWindow = settingsWindow(),
              let reopenedSession = reopenedWindow.contentViewController else {
            XCTFail("Settings window should reopen with a hosting controller")
            return
        }
        XCTAssertFalse(firstSession === reopenedSession)
        reopenedWindow.close()
    }

    @MainActor
    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.title == "AI Usage Bar Settings" && $0.isVisible
        }
    }

    func testProviderSettingsMergesManualProfilesAndUsesExplicitRoots() throws {
        let discovered = [ClaudeProfile(name: "Personal", configDir: URL(fileURLWithPath: "/tmp/personal"), isDefault: false)]
        let manual = ManualClaudeProfile(name: "Work", configDir: URL(fileURLWithPath: "/tmp/work"))
        let settings = ProviderSettings(codexHome: URL(fileURLWithPath: "/tmp/codex"),
                                        geminiHome: URL(fileURLWithPath: "/tmp/gemini"),
                                        manualClaudeProfiles: [manual])

        let config = try settings.usageConfig(codexEnabled: true, claudeEnabled: true,
                                              geminiEnabled: true, discoveredProfiles: discovered)

        XCTAssertEqual(config.codexHome?.path, "/tmp/codex")
        XCTAssertEqual(config.geminiHome?.path, "/tmp/gemini")
        XCTAssertEqual(config.claudeProfiles.map(\.name), ["Personal", "Work"])
    }

    func testManualProfileReplacesDiscoveredProfileAtSamePath() throws {
        let path = URL(fileURLWithPath: "/tmp/claude-work")
        let discovered = [ClaudeProfile(name: "Detected", configDir: path, isDefault: false)]
        let settings = ProviderSettings(manualClaudeProfiles: [ManualClaudeProfile(name: "Client", configDir: path)])
        XCTAssertEqual(try settings.resolvedClaudeProfiles(discoveredProfiles: discovered).map(\.name), ["Client"])
    }

    func testProviderSettingsRejectsBlankAndDuplicateManualProfileNames() {
        XCTAssertThrowsError(try ProviderSettings(manualClaudeProfiles: [
            ManualClaudeProfile(name: " ", configDir: URL(fileURLWithPath: "/tmp/a"))
        ]).resolvedClaudeProfiles(discoveredProfiles: []))
        XCTAssertThrowsError(try ProviderSettings(manualClaudeProfiles: [
            ManualClaudeProfile(name: "Work", configDir: URL(fileURLWithPath: "/tmp/a")),
            ManualClaudeProfile(name: "work", configDir: URL(fileURLWithPath: "/tmp/b"))
        ]).resolvedClaudeProfiles(discoveredProfiles: []))
    }

    func testManualDefaultClaudeDirectoryKeepsDefaultIdentitySemantics() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let profiles = try ProviderSettings(manualClaudeProfiles: [
            ManualClaudeProfile(name: "Personal", configDir: home.appendingPathComponent(".claude"))
        ]).resolvedClaudeProfiles(discoveredProfiles: [])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertTrue(profiles[0].isDefault)
        XCTAssertEqual(profiles[0].dotClaudeJSON.path, home.appendingPathComponent(".claude.json").path)
    }

    func testProviderSettingsRoundTripsAndBuildsSameConfiguration() throws {
        let suite = "ProviderSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let original = ProviderSettings(codexHome: URL(fileURLWithPath: "/tmp/codex"),
                                        geminiHome: URL(fileURLWithPath: "/tmp/gemini"),
                                        manualClaudeProfiles: [ManualClaudeProfile(name: "Work", configDir: URL(fileURLWithPath: "/tmp/work"))])
        original.save(to: defaults)
        let restored = ProviderSettings.load(from: defaults)
        let config = try restored.usageConfig(codexEnabled: false, claudeEnabled: true,
                                              geminiEnabled: false, discoveredProfiles: [])

        XCTAssertEqual(restored, original)
        XCTAssertFalse(config.codexEnabled)
        XCTAssertTrue(config.claudeEnabled)
        XCTAssertFalse(config.geminiEnabled)
        XCTAssertEqual(config.claudeProfiles.map(\.name), ["Work"])
    }

    @MainActor
    func testClaudeConnectIsOptInAndPersisted() async {
        let suite = "AppModelConnect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        setenv("AIUSAGEBAR_NO_KEYCHAIN", "1", 1)   // never touch the real Keychain in tests
        defer { unsetenv("AIUSAGEBAR_NO_KEYCHAIN") }

        // Off by default → nothing reads the Keychain at launch.
        let model = AppModel(defaults: defaults)
        XCTAssertFalse(model.claudeConnected)
        XCTAssertFalse(defaults.bool(forKey: "claudeConnected"))

        model.connectClaude()
        XCTAssertTrue(model.claudeConnected)
        XCTAssertTrue(defaults.bool(forKey: "claudeConnected"))

        // Persists across a relaunch.
        XCTAssertTrue(AppModel(defaults: defaults).claudeConnected)

        model.disconnectClaude()
        XCTAssertFalse(model.claudeConnected)
        XCTAssertFalse(defaults.bool(forKey: "claudeConnected"))
    }

    @MainActor
    func testAppModelApplyPersistsValidatedDraftWithoutReadingProviders() async {
        let suite = "AppModelSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(defaults: defaults)
        var draft = model.settingsDraft()
        draft.codexEnabled = false
        draft.claudeEnabled = false
        draft.geminiEnabled = false
        draft.monthlyBudgetUSD = 250
        draft.maskAccounts = true
        draft.providerSettings = ProviderSettings(codexHome: URL(fileURLWithPath: "/tmp/codex"))

        let error = await model.apply(draft)

        XCTAssertNil(error)
        XCTAssertEqual(ProviderSettings.load(from: defaults), draft.providerSettings)
        XCTAssertFalse(model.codexEnabled)
        XCTAssertFalse(model.claudeEnabled)
        XCTAssertFalse(model.geminiEnabled)
        XCTAssertEqual(model.monthlyBudgetUSD, 250)
        XCTAssertTrue(model.maskAccounts)
        XCTAssertEqual(defaults.double(forKey: "monthlyBudgetUSD"), 250)
        XCTAssertTrue(defaults.bool(forKey: "maskAccounts"))
    }

    @MainActor
    func testAppModelApplyLeavesLiveSettingsUntouchedWhenValidationFails() async {
        let suite = "AppModelSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(30.0, forKey: "cadenceSeconds")
        defaults.set(true, forKey: "codexEnabled")
        defaults.set(true, forKey: "claudeEnabled")
        defaults.set(true, forKey: "geminiEnabled")
        defaults.set(false, forKey: "notificationsEnabled")
        defaults.set(MenuBarStyle.meters.rawValue, forKey: "menuBarStyle")
        defaults.set("must-survive-invalid-apply", forKey: "unrelatedSetting")
        ProviderSettings(codexHome: URL(fileURLWithPath: "/tmp/original-codex")).save(to: defaults)
        let originalDomain = defaults.persistentDomain(forName: suite)! as NSDictionary

        let model = AppModel(defaults: defaults)
        let original = model.settingsDraft()
        var invalid = original
        invalid.cadenceSeconds = 90
        invalid.codexEnabled = false
        invalid.claudeEnabled = false
        invalid.geminiEnabled = false
        invalid.notificationsEnabled = true
        invalid.menuBarStyle = .dot
        invalid.providerSettings = ProviderSettings(manualClaudeProfiles: [
            ManualClaudeProfile(name: " ", configDir: URL(fileURLWithPath: "/tmp/claude"))
        ])

        let error = await model.apply(invalid)

        XCTAssertEqual(error, "Each Claude profile needs a name.")
        XCTAssertEqual(model.settingsDraft(), original)
        let resultingDomain = defaults.persistentDomain(forName: suite)! as NSDictionary
        XCTAssertTrue(originalDomain.isEqual(resultingDomain))
    }

    @MainActor
    func testAppModelApplyClearsClaudeCardsWhenClaudeIsDisabled() async {
        let suite = "AppModelSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let originalNoKeychain = ProcessInfo.processInfo.environment["AIUSAGEBAR_NO_KEYCHAIN"]
        setenv("AIUSAGEBAR_NO_KEYCHAIN", "1", 1)
        defer {
            if let originalNoKeychain {
                setenv("AIUSAGEBAR_NO_KEYCHAIN", originalNoKeychain, 1)
            } else {
                unsetenv("AIUSAGEBAR_NO_KEYCHAIN")
            }
        }

        let model = AppModel(defaults: defaults)
        var enabled = model.settingsDraft()
        enabled.codexEnabled = false
        enabled.claudeEnabled = true
        enabled.geminiEnabled = false

        let enableError = await model.apply(enabled)

        XCTAssertNil(enableError)
        XCTAssertFalse(model.cards(for: .claude).isEmpty)

        var disabled = enabled
        disabled.claudeEnabled = false
        let disableError = await model.apply(disabled)

        XCTAssertNil(disableError)
        XCTAssertTrue(model.cards(for: .claude).isEmpty)
        XCTAssertFalse(model.providers.contains { $0.kind == .claude })
    }

    @MainActor
    func testAppModelApplyClearsPreviouslyAppliedClaudeCardsAfterAutomaticProfileRescan() async {
        let suite = "AppModelSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let originalNoKeychain = ProcessInfo.processInfo.environment["AIUSAGEBAR_NO_KEYCHAIN"]
        setenv("AIUSAGEBAR_NO_KEYCHAIN", "1", 1)
        defer {
            if let originalNoKeychain {
                setenv("AIUSAGEBAR_NO_KEYCHAIN", originalNoKeychain, 1)
            } else {
                unsetenv("AIUSAGEBAR_NO_KEYCHAIN")
            }
        }

        let initialProfile = ClaudeProfile(
            name: "Before Rescan",
            configDir: URL(fileURLWithPath: "/tmp/ai-usage-bar-before-rescan"),
            isDefault: false
        )
        var discoveredProfiles = [initialProfile]
        let model = AppModel(defaults: defaults, discoverClaudeProfiles: { discoveredProfiles })
        var draft = model.settingsDraft()
        draft.codexEnabled = false
        draft.claudeEnabled = true
        draft.geminiEnabled = false

        let initialError = await model.apply(draft)

        XCTAssertNil(initialError)
        XCTAssertEqual(model.cards(for: .claude).map { $0.sourcePath }, [initialProfile.configDir.path])

        discoveredProfiles = []
        let rescanError = await model.apply(draft)

        XCTAssertNil(rescanError)
        XCTAssertTrue(model.cards(for: .claude).isEmpty)
    }
}
