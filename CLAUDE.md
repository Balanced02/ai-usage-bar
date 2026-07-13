# CLAUDE.md

Guidance for working in **ai-usage-bar** — a native macOS menu-bar app (SwiftUI + AppKit)
that shows Claude / Codex / Gemini usage. Everything is read from local files and the
Keychain; the only network calls are Claude's own OAuth usage endpoints with the user's token.

## Commands

```bash
swift build                       # build all targets
swift test                        # Core unit tests (readers, cost, history, discovery)
Scripts/build-app.sh --run        # build + assemble the .app and launch
Scripts/build-app.sh --install    # copy to /Applications and launch (for launch-at-login)
swift run usageprobe codex        # print parsed usage: codex|claude|gemini|all|profiles|statusline
swift run previewgen <dir>        # render the UI to PNGs (used for README screenshots)
swift run icongen out.png         # render the app icon
Scripts/install-hooks.sh          # activate the pre-commit personal-data guard (do this once)
```

## Architecture

- **`Sources/AIUsageBarCore`** — pure logic, **no UI**, unit-tested. One reader per provider
  (`CodexReader`, `Claude/*`, `GeminiReader`), the models (`Models.swift`), `UsageService`
  (aggregator), `UsageHistory` (on-disk timeseries), `Pricing` + `Claude/ClaudeCostReader`
  (cost), `Projection` (burn-rate), `ClaudeProfileDiscovery` (aliases → profiles).
- **`Sources/AIUsageBarUI`** — SwiftUI views + `AppModel` (`@Observable`, the app state) +
  menu-bar rendering (`LabelRenderer`, `MenuBarMeters`).
- **`Sources/AIUsageBar`** — the `@main` app: `NSStatusItem` + `NSPopover` glue only.
- **`Sources/{usageprobe,previewgen,icongen}`** — dev CLIs.
- **`Tests/AIUsageBarCoreTests`** — Core tests.

## Data sources & the non-obvious bits

- **Codex** — `~/.codex/sessions/**/rollout-*.jsonl`. Use the newest `token_count` event **by
  event timestamp** (not file mtime/position). Classify windows by **`window_minutes`**
  (300 = 5h, 10080 = weekly), never by primary/secondary position; either can be null. Tail-read
  (files reach tens of MB); never scan `logs_2.sqlite`.
- **Claude** — `GET api.anthropic.com/api/oauth/usage` (+ `/api/oauth/profile` for identity).
  Token from Keychain `Claude Code-credentials-<hash>` — **enumerate, don't compute** the suffix.
  Headers are mandatory: `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`,
  `User-Agent: claude-code/<ver>` (wrong UA → permanent 429s). Cache ≥ 180s. Multiple profiles
  are auto-discovered by parsing `CLAUDE_CONFIG_DIR=…` from shell rc files; tokens are matched to
  profiles by account email/UUID.
- **Cost** — subscriptions have no per-token bill, so cost is an **equivalent API cost**:
  local JSONL token counts × per-model pricing (`Pricing.swift`).
- **Gemini** — detection only; no local live quota exists.

## macOS gotchas (learned the hard way)

- Use **`NSStatusItem` + `NSPopover`**, not `MenuBarExtra` — its window won't shrink between
  tabs (content floats/centers). The popover sizes to content.
- **Target macOS 14.** Avoid macOS 15+ APIs (e.g. `.symbolEffect(.rotate)`).
- The menu-bar label is a **rendered `NSImage`** — a plain SwiftUI text label loses color to the
  system's monochrome tinting.
- Ad-hoc signing re-prompts for Keychain on every rebuild. Use `--install` and rebuild rarely.

## Privacy & security — IMPORTANT

**Never commit personal data**: real emails, usernames, absolute `/Users/<name>/` paths,
employer/domain names, private repo names, Keychain hashes, or tokens.

- A **pre-commit hook** (`Scripts/hooks/pre-commit`, activated by `Scripts/install-hooks.sh`)
  blocks real emails, common secret patterns, and terms from a **gitignored** `.personal-denylist`.
  Don't disable it; if you must bypass, you're probably about to leak something.
- Screenshots are rendered from **mock `example.com` accounts** via `previewgen` — never real data.
- In docs/comments use placeholders: `you@example.com`, `jane.doe@acme.com`.

## Conventions

- Keep `AIUsageBarCore` UI-free and covered by tests. Run `swift test` before committing (CI does too).
- New provider = a reader in Core returning a `ProviderUsage`, wired into `UsageService`
  (a provider protocol/registry to make this one-file is on the roadmap).
- Match the surrounding style; see `DESIGN.md` for the full rationale and `README.md` for the roadmap.

## Plugins

`.claude/settings.json` enables the **superpowers** plugin (`claude-plugins-official`) at the
project level. When you open this repo and trust the folder, Claude Code installs/enables it
automatically. If it doesn't, run `/plugin install superpowers@claude-plugins-official` once.
