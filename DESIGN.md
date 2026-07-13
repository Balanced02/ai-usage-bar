# ai-usage-bar — Design & Research

A native macOS menu-bar app that shows AI-coding usage/limits for **Claude** (multiple
profiles), **Codex**, and **Gemini** at a glance — inspired by
[steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT), extended for a
multi-tool, multi-profile setup.

## Goals

- One glanceable menu-bar readout of how close each tool is to its limits.
- Codex 5-hour + weekly windows with % used and reset countdowns (like CodexBar).
- Claude 5-hour + weekly (and per-model) windows for **both** work and personal profiles.
- Gemini best-effort (detection + plan cap; real % only if the CLI later exposes it).
- Tiny, native, no Dock icon, launches at login, no data leaves the machine.

## Tech stack (decided)

- **Swift 6 + SwiftUI**, Swift Package Manager, target **macOS 14+** (built on 27).
- Menu bar via **`NSStatusItem` + `NSPopover`**, with a lazily created AppKit settings
  window. This avoids a Dock icon and prevents Settings from reopening on app launch.
- The menu-bar **label is a rendered `NSImage`** (SwiftUI `ImageRenderer`, `isTemplate=false`)
  so colored percentage/meter survives the system's monochrome tinting — the single most
  common menu-bar-label surprise.
- **Non-sandboxed**, ad-hoc signed local builds (sandbox blocks reading `~/.codex`, `~/.claude`,
  and other apps' Keychain items).
- `LSUIElement = true` (agent, no Dock icon). Launch-at-login via `SMAppService.mainApp`.
- **Timer poll** (default ~45s; Claude endpoint throttled to ≥180s). Optional FSEvents later.

## Data sources

### Codex — configured-root `sessions/YYYY/MM/DD/rollout-<ISO>-<uuid>.jsonl`  (✅ high confidence)

The settings window can override the configuration root. Without an override, Codex follows
`$CODEX_HOME` and then `~/.codex`.

Lines are JSON events. The ones we want:

```json
{ "timestamp": "2026-07-12T21:01:02.125Z", "type": "event_msg",
  "payload": { "type": "token_count",
    "info": { "total_token_usage": {"input_tokens":…, "total_tokens":…}, "model_context_window": 353400 },
    "rate_limits": {
      "limit_id": "codex", "plan_type": "pro",
      "primary":   {"used_percent": 2.0, "window_minutes": 10080, "resets_at": 1784488331},
      "secondary": null,
      "credits":   {"has_credits": false, "unlimited": false, "balance": "0"},
      "rate_limit_reached_type": null } } }
```

Parsing rules (learned the hard way from real data):
- **Latest = max event `timestamp`** across recently-modified rollout files, not newest file / not file position. Rate limits are account-global but written into whichever session is active.
- **Classify each window by `window_minutes`** (300 → 5h, 10080 → weekly). The primary/secondary
  slots are *not* positional — we've seen `primary=5h,secondary=weekly` and `primary=weekly,secondary=null` on the same machine.
- Either `primary` or `secondary` can be `null`. `credits.balance` is a **string**.
- `resets_at` is **unix epoch seconds**.
- Read only the **tail** of each file (files reach tens of MB). Never scan `~/.codex/logs_2.sqlite` (~570MB).
- `plan_type`, `credits`, `rate_limit_reached_type` are surfaced. `total_token_usage` is per-session
  cumulative — take the max per session, don't sum across events.

### Claude — OAuth usage endpoint  (✅ verified)

`GET https://api.anthropic.com/api/oauth/usage`

Headers (all required):
- `Authorization: Bearer <accessToken>`
- `anthropic-beta: oauth-2025-04-20`
- `User-Agent: claude-code/<installed version>`  ← **critical**: wrong/missing UA → persistent 429
- `Content-Type: application/json`

Response:
```json
{ "five_hour":         {"utilization": 12.3, "resets_at": "2026-07-12T22:59:59.9+00:00"},
  "seven_day":         {"utilization": 40.0, "resets_at": "…"},
  "seven_day_opus":    {"utilization": 55.0, "resets_at": "…"},
  "seven_day_sonnet":  {"utilization": 10.0, "resets_at": "…"},
  "extra_usage":       {"is_enabled": true, "monthly_limit": …, "used_credits": …, "utilization": …} }
```
- `utilization` is already 0–100 (0 when the window is inactive). `resets_at` is ISO-8601 (µs + offset).
- Map `five_hour → 5h`, `seven_day → weekly` for parity with Codex; optionally show the per-model windows.
- **Cache ≥180s** (data changes hourly; poll 5–15 min). On 429/5xx keep serving cache.
- Endpoint is undocumented/unstable (open Anthropic bugs) — treat as best-effort behind caching.

**Credentials (Keychain, per profile):** generic-password items named `Claude Code-credentials-<8hex>`.
The suffix is a hash of `CLAUDE_CONFIG_DIR` that **cannot be reliably computed** → we **enumerate**
all `Claude Code-credentials-*` items. Each secret is JSON:
`{ claudeAiOauth: { accessToken, refreshToken, expiresAt (epoch ms), scopes, subscriptionType } }`.
First read by our (differently-signed) app triggers a one-time Keychain "Always Allow" prompt.

**Profiles (example):**
- Personal → `~/.claude`  (identity in `~/.claude.json` → `oauthAccount.emailAddress`)
- Work → `~/.claude-work`  (`CLAUDE_CONFIG_DIR=~/.claude-work`; identity in `~/.claude-work/.claude.json`)

Profiles are auto-discovered by parsing `CLAUDE_CONFIG_DIR=…` out of the shell rc files. Settings
can also add named manual configuration directories; those supplement automatic discovery.

Mapping Keychain item → profile: attempt to match each token's account against each profile's
`.claude.json` `oauthAccount` (via the endpoint / token claims). Identity/plan/tier come from
`.claude.json` (`organizationType`, `organizationRateLimitTier`).

**Fallback ladder** (when the endpoint 429s / no token):
1. PTY-scrape `CLAUDE_CONFIG_DIR=<dir> claude` → `/usage` (true %, routes through Claude Code's client, correct profile).
2. `POST /v1/messages` (max_tokens 1), read `anthropic-ratelimit-unified-5h-*/-7d-*` headers.
3. Token-sum **estimate** from `~/.claude/projects/**/*.jsonl` — labeled "estimate", never shown as authoritative %.
4. "usage unavailable / sign in to Claude Code" + last cached value with timestamp.

### Gemini — best-effort  (⚠️ weakest)

The configuration root can be selected in Settings and defaults to `~/.gemini`.

No Codex-style quota file exists. State machine:
- `gemini` not in PATH and no `~/.gemini` → **"Not detected — install gemini-cli"**.
- `~/.gemini` present, telemetry off → read `settings.json` `selectedAuthType`, show the **static plan cap**
  (Google login: 60 req/min, 1,000 req/day; API key: ~250/day Flash-only), labeled "plan cap, not live".
- Telemetry file logging on → tail `~/.gemini/telemetry.log` for session tokens/requests (a counter, not a %).
- Ignore `~/Library/.../com.google.GeminiMacOS*` — that's the unrelated desktop app.
- Stretch: PTY-drive `gemini` → `/stats` and scrape "Usage left %". Brittle; not v1.

## Architecture

```
AIUsageBarCore (library, pure Foundation + Security)
  Models.swift            UsageWindow / ProviderUsage / TokenStats / CreditInfo / status
  TailReader.swift        efficient tail read of large append-only files
  CodexReader.swift       ~/.codex rollout parsing → ProviderUsage
  Claude/
    ClaudeProfile.swift   name + configDir → paths + identity
    ClaudeKeychain.swift  enumerate/read "Claude Code-credentials-*"
    ClaudeUsageAPI.swift  GET /api/oauth/usage (headers, decode, cache)
    ClaudeReader.swift    per-profile identity + usage + fallbacks
  GeminiReader.swift      detection state machine
  UsageService.swift      aggregate all providers, cache, refresh

AIUsageBar (executable, AppKit entry point)
  AIUsageBarApp.swift     @main, NSStatusItem + NSPopover + SettingsWindowController, LSUIElement
  MenuContentView.swift   dropdown: provider cards, windows, resets, refresh, gear → Settings
  SettingsView.swift      draft-backed General, Providers, and Data locations form
  AppModel.swift          @Observable; owns UsageService + timer + persisted settings

usageprobe (executable)   CLI that prints parsed usage as JSON — used to verify readers
Scripts/build-app.sh      build → assemble .app (LSUIElement) → ad-hoc sign → launch
```

## UX (borrowed from CodexBar + prior art)

- Compact label: worst-case window across enabled providers (e.g. `◱ 66%`), colored by threshold.
- Threshold color bands: green < 50 < yellow < 75 < orange < 90 < red.
- Dropdown: one card per provider/profile → each window as a labeled progress bar with % and
  "resets in 3h 12m"; plan/tier + credits; token totals; per-source freshness + status.
- Manual refresh, cadence picker, launch-at-login toggle, per-provider enable toggles, native
  notifications, history sparklines, and burn-rate/time-to-limit projection.
- Settings is explicitly opened from the panel gear or right-click menu. Its draft can be
  cancelled, and it owns refresh, privacy, budget, provider toggles, data roots, and automatic
  plus named manual Claude configurations.

## Distribution

- Personal use now: `swift build -c release` → assemble `.app` → `codesign --sign -` (ad-hoc);
  on other Macs `xattr -dr com.apple.quarantine`.
- Public later: Apple Developer ID ($99/yr) → `notarytool` → staple → Sparkle (EdDSA appcast) + Homebrew cask.

## Non-goals (v1)

- Browser-cookie scraping, API-key spend dashboards, 59-provider support, WidgetKit, localization.

## Key risks / gotchas

- Plain-text menu-bar labels lose color → render an image.
- Claude endpoint 429s without the exact `User-Agent`; cache hard, back off.
- Keychain suffix isn't computable → enumerate; expect a one-time access prompt.
- Codex windows aren't positional → classify by `window_minutes`. `resets_at` is **seconds**.
- App Sandbox silently breaks all file/Keychain reads — stay non-sandboxed.
