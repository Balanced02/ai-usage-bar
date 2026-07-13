# Settings Window and Provider Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Replace the empty Settings scene with an explicitly opened, non-restorable Settings window and make Codex, Claude, and Gemini data locations configurable.

**Architecture:** The app becomes AppKit-launched and owns a lazily created NSWindowController for Settings, so no SwiftUI scene can launch or restore a window by itself. A Codable ProviderSettings value owns optional Codex/Gemini roots and manual Claude profiles; AppModel merges it with automatic discovery and feeds the result to UsageService.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Observation, XCTest, Swift Package Manager, macOS 14+.

## Global Constraints

- Support macOS 14; do not use macOS 15-only SwiftUI scene-restoration APIs.
- Preserve the menu-bar-only (LSUIElement) app behavior.
- Settings opens only from an explicit popover or right-click action and must not restore after relaunch.
- Paths are data/configuration roots, not executable paths.
- An unset Codex override preserves CODEX_HOME then ~/.codex; an unset Gemini override preserves ~/.gemini.
- Manual Claude profiles supplement automatic discovery and are deduplicated by normalized configuration-root path.
- A manually selected ~/.claude must remain a default Claude profile so identity reads from ~/.claude.json.
- Apply settings atomically, clear stale Claude cards when profiles change, and refresh immediately.
- Use test-first changes for all deterministic core/settings behavior.

---

## File Structure

| File | Responsibility |
| --- | --- |
| Sources/AIUsageBarCore/UsageService.swift | Carry configured Codex/Gemini roots into local reader construction and invalidate changed Claude caches. |
| Sources/AIUsageBarCore/CodexReader.swift | Report the actual configured sessions path in missing-data status. |
| Tests/AIUsageBarCoreTests/CoreTests.swift | Prove configured provider roots reach the readers. |
| Sources/AIUsageBarUI/ProviderSettings.swift | Codable provider-location persistence, profile validation/merging, and settings draft values. |
| Tests/AIUsageBarUITests/ProviderSettingsTests.swift | Test provider settings persistence, resolution, and validation without UI or Keychain access. |
| Sources/AIUsageBarUI/AppModel.swift | Load/save provider settings, build service config synchronously, and apply validated drafts once. |
| Sources/AIUsageBarUI/SettingsView.swift | Editable General, Providers, and Data locations Settings UI. |
| Sources/AIUsageBarUI/MenuContentView.swift | Replace the inline gear menu with an explicit Settings button. |
| Sources/AIUsageBar/AIUsageBarApp.swift | AppKit entry point, explicit settings controller, and Settings menu actions. |
| Package.swift | Add the UI unit-test target. |
| README.md | Explain the real Settings window and path configuration. |

## Task 1: Thread configured local roots through the core service

**Files:**
- Modify: Sources/AIUsageBarCore/UsageService.swift:4-88
- Modify: Sources/AIUsageBarCore/CodexReader.swift:76-84
- Modify: Tests/AIUsageBarCoreTests/CoreTests.swift

**Interfaces:**
- Consumes: CodexReader(codexHome:) and GeminiReader(geminiHome:), both already accept optional roots.
- Produces: UsageConfig.codexHome, UsageConfig.geminiHome, and UsageService reads that honor them.

- [x] **Step 1: Write the failing core tests**

Append these tests to CoreTests before touching production code:

~~~swift
func testUsageServiceReadsConfiguredLocalRoots() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("roots-\(UUID().uuidString)")
    let codex = root.appendingPathComponent("codex")
    let gemini = root.appendingPathComponent("gemini")
    let day = codex.appendingPathComponent("sessions/2026/07/13")
    try fm.createDirectory(at: day, withIntermediateDirectories: true)
    try fm.createDirectory(at: gemini, withIntermediateDirectories: true)
    try (tokenCountLine(ts: "2026-07-13T10:00:00.000Z", p5h: 10, wk: 20,
                        credits: nil, plan: "pro") + "\n")
        .write(to: day.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)
    try #"{"selectedAuthType":"oauth"}"#.write(
        to: gemini.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

    let config = UsageConfig(codexEnabled: true, claudeEnabled: false, geminiEnabled: true,
                             codexHome: codex, geminiHome: gemini)
    let local = await UsageService(config: config).readLocal()

    XCTAssertTrue(local.codex?.sourcePath?.hasPrefix(codex.path) == true)
    XCTAssertEqual(local.gemini?.sourcePath, gemini.path)
    try? fm.removeItem(at: root)
}

func testCodexReaderReportsConfiguredSessionsPath() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
    let usage = CodexReader(codexHome: root).read()
    XCTAssertEqual(usage.detail, "No \(root.appendingPathComponent("sessions").path) found")
}
~~~

- [x] **Step 2: Run test to verify it fails**

Run: swift test --filter CoreTests/testUsageServiceReadsConfiguredLocalRoots

Expected: compilation fails because UsageConfig does not yet accept codexHome or geminiHome.

- [x] **Step 3: Implement the minimal core plumbing**

In UsageConfig, add optional root fields and initializer parameters immediately after the enabled flags:

~~~swift
public var codexHome: URL?
public var geminiHome: URL?

public init(codexEnabled: Bool = true, claudeEnabled: Bool = true, geminiEnabled: Bool = true,
            codexHome: URL? = nil, geminiHome: URL? = nil,
            claudeProfiles: [ClaudeProfile] = [], claudeMinInterval: TimeInterval = 180,
            allowKeychain: Bool = true) {
    self.codexEnabled = codexEnabled
    self.claudeEnabled = claudeEnabled
    self.geminiEnabled = geminiEnabled
    self.codexHome = codexHome
    self.geminiHome = geminiHome
    self.claudeProfiles = claudeProfiles
    self.claudeMinInterval = claudeMinInterval
    self.allowKeychain = allowKeychain
}
~~~

Use those fields in both service read paths:

~~~swift
if config.codexEnabled { out.append(CodexReader(codexHome: config.codexHome).read()) }
if config.geminiEnabled { out.append(GeminiReader(geminiHome: config.geminiHome).read()) }

return (config.codexEnabled ? CodexReader(codexHome: config.codexHome).read() : nil,
        config.geminiEnabled ? GeminiReader(geminiHome: config.geminiHome).read() : nil)
~~~

Update UsageService.update(config:) so a changed claudeProfiles list clears claudeCache before assigning the new configuration:

~~~swift
let profilesChanged = self.config.claudeProfiles != config.claudeProfiles
self.config = config
if profilesChanged { claudeCache = [] }
lastClaudeFetch = nil
~~~

Replace the hard-coded Codex message with:

~~~swift
detail: "No \(sessions.path) found"
~~~

- [x] **Step 4: Run focused and full core tests**

Run: swift test --filter CoreTests

Expected: all Core tests pass, including both new configured-root tests.

- [x] **Step 5: Commit**

~~~bash
git add Sources/AIUsageBarCore/UsageService.swift Sources/AIUsageBarCore/CodexReader.swift Tests/AIUsageBarCoreTests/CoreTests.swift
git commit -m "feat: support configured provider data roots"
~~~

## Task 2: Build a testable provider settings domain model

**Files:**
- Modify: Package.swift:14-42
- Create: Sources/AIUsageBarUI/ProviderSettings.swift
- Create: Tests/AIUsageBarUITests/ProviderSettingsTests.swift

**Interfaces:**
- Consumes: ClaudeProfile and the UsageConfig root parameters from Task 1.
- Produces: ManualClaudeProfile, ProviderSettings, and ProviderSettingsError for AppModel and SettingsView.

- [x] **Step 1: Add failing UI-domain tests**

Add an AIUsageBarUITests target in Package.swift depending on AIUsageBarUI and AIUsageBarCore. Create tests covering these exact behaviors:

~~~swift
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
~~~

- [x] **Step 2: Run test to verify it fails**

Run: swift test --filter ProviderSettingsTests

Expected: target or symbols are missing.

- [x] **Step 3: Implement the provider-settings model**

Create ProviderSettings.swift with these public types and behavior:

~~~swift
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

    public init(codexHome: URL? = nil, geminiHome: URL? = nil,
                manualClaudeProfiles: [ManualClaudeProfile] = []) {
        self.codexHome = codexHome?.standardizedFileURL
        self.geminiHome = geminiHome?.standardizedFileURL
        self.manualClaudeProfiles = manualClaudeProfiles
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
                    claudeProfiles: try resolvedClaudeProfiles(discoveredProfiles: discoveredProfiles))
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
~~~

The resolvedClaudeProfiles method must reject a duplicate manual root, retain the manual name when it matches an auto-discovered root, and set isDefault only when the selected root is the current user's ~/.claude directory.

- [x] **Step 4: Verify the new domain target**

Run: swift test --filter ProviderSettingsTests

Expected: all five profile/root/persistence tests pass without accessing a live Keychain, network, or real provider data.

- [x] **Step 5: Commit**

~~~bash
git add Package.swift Sources/AIUsageBarUI/ProviderSettings.swift Tests/AIUsageBarUITests/ProviderSettingsTests.swift
git commit -m "feat: add persistent provider path settings"
~~~

## Task 3: Make AppModel apply settings as one validated refresh

**Files:**
- Modify: Sources/AIUsageBarUI/AppModel.swift:12-292
- Modify: Tests/AIUsageBarUITests/ProviderSettingsTests.swift

**Interfaces:**
- Consumes: ProviderSettings.load, save, usageConfig, and resolvedClaudeProfiles from Task 2.
- Produces: SettingsDraft, AppModel.settingsDraft(), AppModel.automaticClaudeProfiles(), and AppModel.apply(_:) async -> String? for SettingsView.

- [x] **Step 1: Add a failing AppModel-application test**

~~~swift
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
    draft.providerSettings = ProviderSettings(codexHome: URL(fileURLWithPath: "/tmp/codex"))

    XCTAssertNil(await model.apply(draft))
    XCTAssertEqual(ProviderSettings.load(from: defaults), draft.providerSettings)
    XCTAssertFalse(model.codexEnabled)
    XCTAssertFalse(model.claudeEnabled)
    XCTAssertFalse(model.geminiEnabled)
}
~~~

- [x] **Step 2: Run test to verify it fails**

Run: swift test --filter ProviderSettingsTests/testAppModelApplyPersistsValidatedDraftWithoutReadingProviders

Expected: compilation fails because AppModel does not yet have the injected initializer, settingsDraft(), or apply(_:).

- [x] **Step 3: Add draft and atomic model APIs**

Make MenuBarStyle conform to Equatable, then add this UI-only draft value beside it:

~~~swift
public struct SettingsDraft: Equatable {
    public var cadenceSeconds: Double
    public var codexEnabled: Bool
    public var claudeEnabled: Bool
    public var geminiEnabled: Bool
    public var notificationsEnabled: Bool
    public var menuBarStyle: MenuBarStyle
    public var launchAtLogin: Bool
    public var providerSettings: ProviderSettings
}
~~~

Change AppModel to accept UserDefaults in its initializer, load providerSettings before constructing UsageService, and construct the initial service with a synchronous helper equivalent to:

~~~swift
private func usageConfig(discovered: [ClaudeProfile] = ClaudeProfileDiscovery.discover()) -> UsageConfig {
    (try? providerSettings.usageConfig(codexEnabled: codexEnabled, claudeEnabled: claudeEnabled,
                                       geminiEnabled: geminiEnabled, discoveredProfiles: discovered))
    ?? UsageConfig(codexEnabled: codexEnabled, claudeEnabled: claudeEnabled, geminiEnabled: geminiEnabled,
                   claudeProfiles: discovered)
}
~~~

Expose these main-actor APIs:

~~~swift
public func settingsDraft() -> SettingsDraft
public func automaticClaudeProfiles() -> [ClaudeProfile]
public func apply(_ draft: SettingsDraft) async -> String?
~~~

apply(_:) must first validate draft.providerSettings using one freshly discovered profile list. On validation failure, return the error message without changing any live setting. On success, update every scalar, provider setting, notifier state, and launch-at-login state; persist once; reset lastClaude when the resolved profile list differs; await service.update(config:); and await refresh() before returning nil.

Remove direct reconfigure() calls from property observers because the new Settings UI applies one complete draft rather than mutating settings one control at a time. Keep persist() responsible for existing scalar keys plus providerSettings.save(to:).

- [x] **Step 4: Run UI and core tests**

Run: swift test --filter ProviderSettingsTests && swift test --filter CoreTests

Expected: all settings-domain and core reader tests pass; no test reads live usage data.

- [x] **Step 5: Commit**

~~~bash
git add Sources/AIUsageBarUI/AppModel.swift Tests/AIUsageBarUITests/ProviderSettingsTests.swift
git commit -m "feat: apply provider settings immediately"
~~~

## Task 4: Create the real Settings UI and explicit non-restorable window

**Files:**
- Create: Sources/AIUsageBarUI/SettingsView.swift
- Modify: Sources/AIUsageBarUI/MenuContentView.swift:5-116
- Modify: Sources/AIUsageBar/AIUsageBarApp.swift:1-128

**Interfaces:**
- Consumes: SettingsDraft and AppModel APIs from Task 3.
- Produces: a SettingsView(model:) that invokes AppModel.apply(_:), and an AppDelegate.showSettings() action used by both menu surfaces.

- [x] **Step 1: Write the view contract before presentation code**

Create SettingsView with a model initializer that captures an independent draft and auto-discovered rows:

~~~swift
public struct SettingsView: View {
    @Bindable private var model: AppModel
    @State private var draft: SettingsDraft
    @State private var detectedProfiles: [ClaudeProfile]
    @State private var errorMessage: String?

    public init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settingsDraft())
        _detectedProfiles = State(initialValue: model.automaticClaudeProfiles())
    }
}
~~~

Build the view around a scrollable Form with exact sections General, Providers, and Data locations. General exposes the existing cadence/menu-style/notification/launch-at-login values. Providers exposes three toggles. Data locations exposes Codex and Gemini folder rows, auto-detected Claude rows, manual Claude editable rows, Add profile, Rescan, Apply, and Cancel.

- [x] **Step 2: Implement folder and profile editing behavior**

Use NSOpenPanel with canChooseDirectories = true, canChooseFiles = false, and allowsMultipleSelection = false to select roots. Assign url.standardizedFileURL to the relevant draft field. Do not create security-scoped bookmarks because the app is non-sandboxed.

Render manual rows using bindings so edits remain only in the draft until Apply:

~~~swift
ForEach($draft.providerSettings.manualClaudeProfiles) { $profile in
    TextField("Name", text: $profile.name)
    Text(profile.configDir.path)
        .font(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
    HStack {
        Button("Choose folder") { chooseClaudeFolder(id: profile.wrappedValue.id) }
        Button("Remove", role: .destructive) {
            let id = profile.wrappedValue.id
            draft.providerSettings.manualClaudeProfiles.removeAll { $0.id == id }
        }
    }
}
~~~

Add profile inserts:

~~~swift
ManualClaudeProfile(name: "New profile",
                    configDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"))
~~~

Rescan refreshes only detectedProfiles. Apply runs Task { errorMessage = await model.apply(draft) }; when it succeeds, reload both the draft and detected rows from the model. Cancel resets the draft and detected rows from the model without changing the running app configuration.

- [x] **Step 3: Replace the popover gear menu**

Change MenuContentView's initializer to accept openSettings: @escaping () -> Void. Replace the current Menu gear with:

~~~swift
Button(action: openSettings) {
    Image(systemName: "gearshape")
}
.buttonStyle(.borderless)
.help("Settings")
~~~

Keep the existing launch-at-login checkbox and Quit button in the popover. The Settings window owns all other controls, preventing two UI surfaces from mutating settings differently.

- [x] **Step 4: Replace the SwiftUI scene launcher with an AppKit presenter**

Replace the current @main App type with this AppKit entry point pattern:

~~~swift
@main
struct AIUsageBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
~~~

Add a SettingsWindowController that creates an NSWindow with an NSHostingController(rootView: SettingsView(model: model)), title AI Usage Bar Settings, standard titled/closable/miniaturizable/resizable style, and an initial content size of about 620 × 650. Set window.isRestorable = false and call window.disableSnapshotRestoration().

Have AppDelegate retain the controller lazily and add:

~~~swift
@objc func showSettings() {
    if settingsWindowController == nil {
        settingsWindowController = SettingsWindowController(model: model)
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindowController?.showWindow(nil)
    settingsWindowController?.window?.makeKeyAndOrderFront(nil)
}

func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    false
}
~~~

Pass showSettings to the popover closure. Add a Settings… action to the right-click quick menu before Quit. Do not add a SwiftUI Settings scene anywhere in the app target.

- [x] **Step 5: Build and manually verify lifecycle behavior**

Run: swift build

Then run: Scripts/build-app.sh --run

Manual acceptance checks:

1. Launch shows no normal window and only the menu-bar item.
2. The gear and right-click Settings… both open the same populated Settings window.
3. Close Settings, quit the app, relaunch it, and confirm Settings does not reopen.
4. Add a manual Claude profile and choose custom Codex/Gemini roots; click Apply and confirm the panel updates immediately.
5. Use a missing but selectable root and confirm the reader reports status rather than refusing to save it.

- [x] **Step 6: Commit**

~~~bash
git add Sources/AIUsageBarUI/SettingsView.swift Sources/AIUsageBarUI/MenuContentView.swift Sources/AIUsageBar/AIUsageBarApp.swift
git commit -m "feat: add explicit settings window"
~~~

## Task 5: Document and verify the finished user workflow

**Files:**
- Modify: README.md:80-83
- Modify: docs/superpowers/plans/2026-07-13-settings-window-provider-paths.md (mark completed steps only after evidence is collected)

**Interfaces:**
- Consumes: implemented Settings window and documented accepted behavior.
- Produces: accurate setup instructions and final verification evidence.

- [x] **Step 1: Update the Settings documentation**

Replace the existing short Settings paragraph with wording that tells users to click the gear to open Settings, lists General/Providers/Data locations, explains that Codex and Gemini accept their configuration-root folders, and says manual named Claude profiles supplement automatic discovery.

- [x] **Step 2: Run the complete verification suite**

Run: swift test

Expected: every Core and UI settings test passes. Note only pre-existing compiler warnings separately if they remain.

Run: Scripts/build-app.sh

Expected: a release .app bundle is assembled and code signing completes or reports the script's existing nonfatal ad-hoc warning.

- [x] **Step 3: Inspect the final diff**

Run: git diff "$(git merge-base main HEAD)" HEAD --check && git status --short

Expected: no whitespace errors; only the intended Settings/core/test/README changes are present.

- [x] **Step 4: Commit**

~~~bash
git add README.md docs/superpowers/plans/2026-07-13-settings-window-provider-paths.md
git commit -m "docs: explain provider path settings"
~~~
