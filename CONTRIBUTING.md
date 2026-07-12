# Contributing

Thanks for your interest! This is a small, native macOS app — contributions welcome.

## Build & run

Requires macOS 14+ and Swift 6 (Xcode 16+).

```bash
swift build            # build everything
swift test             # run the unit tests
Scripts/build-app.sh --run   # build + launch the menu-bar app
```

## Project layout

- `Sources/AIUsageBarCore` — pure logic (readers, models, history, projection). No UI. Unit-tested.
  - `CodexReader`, `Claude/*`, `GeminiReader` — one reader per provider.
  - `UsageService` — aggregates providers; `UsageHistory` — the on-disk timeseries.
- `Sources/AIUsageBarUI` — SwiftUI views + `AppModel` (the observable state) + menu-bar rendering.
- `Sources/AIUsageBar` — the `@main` app: `NSStatusItem` + `NSPopover` glue.
- `Sources/usageprobe` — CLI to exercise the readers (`usageprobe codex|claude|gemini|all|profiles|statusline`).
- `Sources/previewgen` — renders the UI to PNGs (used for the README screenshots).
- `Sources/icongen` — renders the app icon.

## Adding a provider

Today each provider is its own reader in `AIUsageBarCore` returning a `ProviderUsage`, wired into
`UsageService`. A `UsageProvider` protocol + registry to make this a one-file change is on the roadmap —
if you want to add Cursor / Copilot / Grok, open an issue first so we can land that refactor.

## Guidelines

- Keep `AIUsageBarCore` UI-free and unit-tested.
- No secrets or personal data in code, comments, tests, or committed screenshots (screenshots use
  `example.com` mock accounts via `previewgen`).
- Match the surrounding style; run `swift test` before opening a PR (CI runs it too).
