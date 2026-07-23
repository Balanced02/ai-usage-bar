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

    func testUsageConfigCarriesAccountConfigsAndRoots() {
        let settings = ProviderSettings(
            codexHome: URL(fileURLWithPath: "/tmp/codex"),
            geminiHome: URL(fileURLWithPath: "/tmp/gemini"),
            claudeAccountConfigs: ["acc-1": ClaudeAccountConfig(name: "Work", logsDir: "/tmp/.claude")])

        let config = settings.usageConfig(codexEnabled: true, claudeEnabled: true, geminiEnabled: true)

        XCTAssertEqual(config.codexHome?.path, "/tmp/codex")
        XCTAssertEqual(config.geminiHome?.path, "/tmp/gemini")
        XCTAssertEqual(config.claudeAccountConfigs["acc-1"]?.name, "Work")
        XCTAssertEqual(config.claudeAccountConfigs["acc-1"]?.logsDir, "/tmp/.claude")
    }

    func testProviderSettingsRoundTripsAccountConfigs() throws {
        let suite = "ProviderSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let original = ProviderSettings(
            codexHome: URL(fileURLWithPath: "/tmp/codex"),
            claudeAccountConfigs: ["acc-1": ClaudeAccountConfig(name: "Work", logsDir: "/tmp/w/.claude")])
        original.save(to: defaults)
        let restored = ProviderSettings.load(from: defaults)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.claudeAccountConfigs["acc-1"], ClaudeAccountConfig(name: "Work", logsDir: "/tmp/w/.claude"))
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

}
