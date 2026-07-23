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
- **Claude** — `GET api.anthropic.com/api/oauth/usage` (+ `/api/oauth/profile` for identity), using
  the app's **own** OAuth token (`Claude/ClaudeOAuth*`, `ClaudeTokenStore`, `ClaudeTokenProvider`),
  **not** Claude Code's Keychain item (that item's ACL is wiped on Claude Code's every refresh →
  recurring prompt; unfixable from the reader side). We run Claude Code's OAuth client
  (`9d1c250a-…`, PKCE S256, loopback `http://localhost:<ephemeral>/callback`, authorize
  `claude.ai/oauth/authorize`, token `platform.claude.com/v1/oauth/token`) and store the token in our
  own generic-password item (`com.aiusagebar.AIUsageBar.claude-oauth`), keyed by account UUID,
  updated **in place** (`SecItemUpdate`, never delete+add) so a signed build reads it with **no
  prompt**. **Two different, endpoint-specific User-Agents** (the non-obvious gotcha): the *usage*
  endpoint REQUIRES `User-Agent: claude-code/<ver>` (wrong UA → 429), but the *token* endpoint's edge
  hard-429s `claude-code/*` and `curl/*` and only accepts the CLI's real transport UA — send
  `axios/<ver>` there. Refresh tokens **rotate** (persist the new one; a `ClaudeTokenProvider` actor
  serializes refreshes); `invalid_grant` on refresh is terminal → re-auth. Keychain gotcha:
  `kSecReturnData` + `kSecMatchLimitAll` in one query is `errSecParam` (-50) — list attributes, then
  read each item. Headers otherwise: `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`.
  Cache ≥ 180s (per-account usage cache in `ClaudeTokenProvider.cachedUsage`, so re-rendering after a
  config change doesn't re-hit the endpoint). **No path auto-discovery**: accounts are exactly the
  OAuth sign-ins, each with a user config (`ClaudeAccountConfig`: name + optional logs dir). Cost +
  plan are opt-in per account — shown only when its `logsDir` points at a config dir (`ClaudeCostReader
  .summary(configDir:)`; `.claude.json` is at `<dir>/.claude.json` except the default `~/.claude` →
  `~/.claude.json`). `ClaudeProfileDiscovery` survives for the `usageprobe` CLI only.
- **Cost** — subscriptions have no per-token bill, so cost is an **equivalent API cost**:
  local JSONL token counts × per-model pricing (`Pricing.swift`).
- **Gemini** — detection only; no local live quota exists.
- **Custom** — user-configured (`CustomProvider`/`CustomProviderConfig`): a folder of `.jsonl` logs
  + dot-paths to the rate-limit fields, grouped under the `.custom` kind. Configured in Settings →
  Custom providers; persisted in `ProviderSettings`. Adding a *built-in* provider = a reader that
  returns `ProviderUsage`, wired into `UsageService`.

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
  blocks real emails, common secret patterns, terms from a **gitignored** `.personal-denylist`,
  and a real name/email in the **commit author identity** (`git var GIT_AUTHOR_IDENT`) — the last
  guards against a github.com web-UI commit stamping your profile name. Note it cannot catch
  commits authored *server-side* on GitHub (e.g. the web "Merge" button); prefer merging locally.
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
