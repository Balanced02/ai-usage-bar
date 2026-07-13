# Changelog

All notable changes to **ai-usage-bar** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The release workflow publishes the notes for a tagged version from its section
below, so keep the newest release at the top and move items out of _Unreleased_
as you cut a tag.

## [Unreleased]

### Changed
- The release `.dmg` now includes an `/Applications` symlink, so mounting it shows the
  standard drag-to-Applications install window instead of a bare `.app`.

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

[Unreleased]: https://github.com/Balanced02/ai-usage-bar/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Balanced02/ai-usage-bar/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Balanced02/ai-usage-bar/releases/tag/v0.1.0
