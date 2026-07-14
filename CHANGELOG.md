# Changelog

All notable changes to **ai-usage-bar** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The release workflow publishes the notes for a tagged version from its section
below, so keep the newest release at the top and move items out of _Unreleased_
as you cut a tag.

## [Unreleased]

## [0.1.6] - 2026-07-14

### Added
- **Local Claude usage without connecting.** When Claude isn't connected, the Claude tab now
  shows your **last 5H and 7D** token counts and equivalent cost, derived entirely from your
  local `~/.claude` logs (ccusage-style) — so the tab is useful before you ever click **Connect**.
  Connecting still adds the live limit percentage from Claude's usage endpoint.

### Changed
- The release `.dmg` now opens to a **branded installer window** — app icon, a purple
  drag-to-Applications arrow, and the app name/tagline over a light background — rendered at
  retina resolution (a multi-representation TIFF Finder resolves per display).

## [0.1.5] - 2026-07-14

### Changed
- **Claude live limits are now opt-in.** The app no longer reads the Claude Code token from
  the Keychain at launch, so no credential prompt appears when it starts. The Claude tab shows a
  **Connect** banner (also a Connect/Disconnect control in Settings → Claude); clicking it reads
  the token in a context you initiated — macOS asks once, then remembers. Your account and cost
  data still show without connecting. **Upgrading from an earlier version?** Live Claude limits are
  off until you click **Connect** once (it's a one-time, opt-in step now).
- Local `Scripts/build-app.sh` builds now auto-sign with an installed **Developer ID** (stable
  signature) instead of ad-hoc, so rebuilding during development doesn't re-trigger the Keychain
  prompt. Falls back to ad-hoc when no Developer ID is present.

## [0.1.4] - 2026-07-13

### Fixed
- **No longer prompts for access to your Documents folder.** The worktree→project rollup
  read the `.git` file at each project's working directory — which live under `~/Documents`
  — tripping a macOS privacy prompt. Project names are now derived from the path string
  alone. The app touches nothing outside `~/.claude`, `~/.codex`, `~/.gemini`, and its own
  Application Support data.

## [0.1.3] - 2026-07-13

### Changed
- The release `.dmg` now opens to a proper **drag-to-Applications** window — app on the
  left, Applications folder on the right, with a saved layout — via `create-dmg`, instead
  of a bare `.app` icon.

## [0.1.2] - 2026-07-13

### Changed
- Added an `/Applications` symlink to the release `.dmg` (superseded by the laid-out
  window in 0.1.3).

## [0.1.1] - 2026-07-13

### Fixed
- **Crash on launch on a fresh install.** `UsageNotifier.requestAuthorization()` used the
  completion-handler notification API, whose callback fires on a background queue. Because the
  notifier is `@MainActor`, Swift inserts a main-actor executor check at the closure's entry, which
  trapped (`dispatch_assert_queue_fail`) whenever notification authorization was still undetermined —
  i.e. on any clean install. Switched to the `async` authorization API. Did not surface locally
  because authorization was already granted from a prior run.

## [0.1.0] - 2026-07-13

First public release — every AI-coding limit in your menu bar.

### Added
- **Multi-provider menu bar** — Claude, Codex, and Gemini usage at a glance, with
  four menu-bar styles (text, dual-bar meters, single number, dot).
- **Multiple Claude profiles** — personal + work stacked together, color-coded,
  auto-discovered from `CLAUDE_CONFIG_DIR=…` in your shell rc files.
- **Per-model windows** — `5H`, `7D`, and per-model weekly meters that appear only
  when you've used that model, with a **pace tick** and **burn-rate warnings**.
- **Cost & analytics** — an equivalent-$ breakdown per account: today / 30-day, by
  model, by project, cache-hit efficiency, a month-end forecast, and an optional
  budget gauge — all computed from local logs.
- **Per-project drilldown** — expand any project for its own model mix, share of
  spend, and a 14-day trend; git worktrees roll up into the project they belong to.
- **Model-downshift nudge** and **best-account hint** for multi-profile setups.
- **Trends** — inline sparklines of each window's recent history (on-disk timeseries).
- **Notifications** — native alerts on 75% / 90% / burning-too-fast / cleared.
- **Custom providers** — point at any tool's `.jsonl` logs plus dot-paths to its
  rate-limit fields to add a provider with no code.
- **Privacy** — a persisted "Mask account details" toggle for screen-sharing, and a
  pre-commit guard that blocks personal data (incl. the commit author identity).
- **Settings window** — refresh cadence, menu-bar style, budget, notifications,
  provider toggles, and data-location roots.

[Unreleased]: https://github.com/Balanced02/ai-usage-bar/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/Balanced02/ai-usage-bar/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/Balanced02/ai-usage-bar/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/Balanced02/ai-usage-bar/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Balanced02/ai-usage-bar/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Balanced02/ai-usage-bar/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Balanced02/ai-usage-bar/releases/tag/v0.1.0
