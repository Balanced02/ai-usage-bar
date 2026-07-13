# Settings Window and Provider Paths Design

## Goal

Replace the empty SwiftUI Settings scene with a useful, explicitly opened Settings window. It must never appear automatically at app launch and must let a user configure the app's existing behavior plus its Codex, Claude, and Gemini data locations.

## User-facing behavior

### Opening and lifecycle

- AI Usage Bar remains a menu-bar-only app with no Dock icon.
- Launching the app or logging in must not show a window.
- A Settings window opens only when the user selects **Settings…** from the popover or the right-click menu.
- Closing Settings hides that window; it does not quit the app.
- macOS must not restore the Settings window after relaunch, login, or an AppKit reopen event.

The current `Settings { EmptyView() }` scene is the source of the blank window. Because the app supports macOS 14, the app will use an AppKit entry point and a lazily created `NSWindowController` hosting a SwiftUI `SettingsView`, rather than relying on a SwiftUI `Settings` scene whose first-scene launch behavior cannot be suppressed on macOS 14.

The window controller will set `isRestorable = false` and disable snapshot restoration. The app delegate will decline default reopen handling. This makes the window entirely explicit while still giving it standard macOS title-bar controls and normal window-switcher behavior while it is open.

### Settings content

The Settings view will replace the inline gear menu and include these sections:

1. **General**
   - Refresh cadence
   - Launch at login
   - Notifications
   - Menu-bar display style

2. **Providers**
   - Enable or disable Codex, Claude, and Gemini

3. **Data locations**
   - Codex: one optional `.codex` data-root folder override.
   - Gemini: one optional `.gemini` data-root folder override.
   - Claude: auto-detected profiles plus a separate editable list of named manual profiles.

These are data/configuration roots, not executable locations. Executable-path configuration is out of scope.

### Claude profile rules

- Automatic discovery remains active. It continues to find `~/.claude` and `CLAUDE_CONFIG_DIR` values found in supported shell configuration files.
- A user can add any number of manual profiles, each with a required friendly name and selected configuration-root folder.
- Automatic rows are informational and cannot be deleted in Settings; manual rows can be renamed or removed.
- Profiles are deduplicated by normalized absolute configuration-root path. If a manual profile uses an automatically discovered path, the manual entry replaces the automatic entry so the user's name wins and only one card is shown.
- Manual profile names must be nonempty and unique case-insensitively across the resolved list. The UI reports validation errors before applying changes.
- Selecting `~/.claude` creates a default Claude profile, preserving the special identity path `~/.claude.json`. Other profile roots use `<selected root>/.claude.json`.
- Settings provides a **Rescan** action for automatic discovery.

### Applying changes

Settings edits use a draft with **Apply** and **Cancel**. Apply validates profile names, persists settings, updates the service configuration, clears stale Claude cards when the effective profile list changes, and triggers an immediate refresh rather than waiting for the polling cadence. Cancel leaves the running app configuration unchanged.

Selected folders are accepted even when they do not yet contain usage data. The provider card will show the existing reader's status (for example, no sessions found) rather than blocking a user who is setting up a tool for the first time.

An unset Codex or Gemini override means automatic behavior. Codex resolution remains: explicit setting, then `CODEX_HOME`, then `~/.codex`. Gemini resolution remains: explicit setting, then `~/.gemini`.

## Architecture

### App lifecycle and presentation

- Replace the SwiftUI `App` scene launcher with an AppKit `NSApplication` entry point that owns `AppDelegate` for the life of the app.
- Keep the existing status-item and popover management in `AppDelegate`.
- Add a lazily created settings-window controller in the app target. It hosts `SettingsView(model: model)` and is the sole way to present settings.
- Pass an explicit `openSettings` closure to `MenuContentView`; make the popover gear open Settings rather than contain the current configuration menu. Add the same command to the right-click quick menu.

### Persistent settings and configuration building

Introduce a small Codable, testable settings value for provider locations and manual Claude profiles. Existing scalar preferences can remain in their current UserDefaults keys, while the provider-location value is encoded as data in UserDefaults.

`AppModel` will build a `UsageConfig` synchronously from persisted settings during initialization. This removes the current startup sequence that creates an all-enabled service and asynchronously reconfigures it afterwards.

`UsageConfig` will gain optional `codexHome` and `geminiHome` values. `UsageService` will pass these values to `CodexReader` and `GeminiReader` in both its full and local-only read paths. The Claude profile list will be built by merging auto-discovered and manual entries according to the rules above.

When `UsageService` receives a new configuration with a changed Claude profile list, it will clear its cached Claude result as well as reset the live-fetch timer so removed profiles cannot remain visible.

The Codex missing-data diagnostic will use the resolved configured path rather than incorrectly referring to `~/.codex` after an override is selected.

## Error handling

- Folder selection is restricted to directories and paths are normalized before persistence and comparison.
- Apply shows an inline validation message for an empty or duplicate manual profile name; it does not mutate the live configuration in that case.
- A readable-but-empty or not-yet-created provider folder is valid input. Reader status remains the source of truth for what data is available.
- Failure to register or unregister launch-at-login continues to be logged and leaves the Settings control reflecting the service's actual status on its next render.

## Testing and verification

Tests will be written before production changes.

1. Unit-test the pure provider-location settings codec and configuration builder:
   - automatic defaults are retained when overrides are absent;
   - explicit Codex and Gemini roots reach `UsageConfig`;
   - manual Claude profiles supplement discovery;
   - a manual duplicate replaces its auto-discovered counterpart;
   - default Claude-root semantics and name validation are preserved.
2. Extend `UsageService` tests with temporary Codex and Gemini roots to prove custom paths are used in `readLocal()` and `refresh()`.
3. Add coverage for the configured Codex missing-data message.
4. Build and run the full Swift test suite.
5. Manually verify the app launches without a Settings window; opening Settings from each entry point shows controls; applying a path immediately updates the displayed provider source/status; closing and relaunching does not reopen Settings.

## Out of scope

- Configuring the `codex`, `claude`, or `gemini` executable paths.
- Altering how provider usage is parsed or changing network/keychain behavior beyond correctly applying the selected data roots.
- Hiding or disabling automatic Claude discovery; manual profiles intentionally supplement it.
