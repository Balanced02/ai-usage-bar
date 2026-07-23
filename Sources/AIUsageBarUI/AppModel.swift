import SwiftUI
import AppKit
import Observation
import ServiceManagement
import AIUsageBarCore

/// A per-kind summary chip for the menu-bar label.
public struct LabelChip: Identifiable, Sendable {
    public var id: String { code }
    public var code: String
    public var percent: Double?
    public var throttled: Bool

    public init(code: String, percent: Double?, throttled: Bool) {
        self.code = code
        self.percent = percent
        self.throttled = throttled
    }
}

/// A signed-in Claude account for the Settings list (no secret material).
public struct ClaudeAccountSummary: Identifiable, Sendable, Hashable {
    public let key: String        // Keychain account key (UUID/email)
    public let email: String?
    public let name: String?      // user-assigned display name
    public let logsDir: String?   // configured cost-logs folder (nil = cost off)
    public var id: String { key }
    public var label: String { name ?? email ?? key }
    public var hasCost: Bool { logsDir != nil }
}

/// How the menu-bar title is drawn.
public enum MenuBarStyle: String, Sendable, CaseIterable, Equatable {
    case text     // "Cx 2%  Cl 30%"
    case meters   // tiny dual-bar meters per provider
    case number   // worst window as a single colored "85%"
    case dot      // a single traffic-light dot

    public var label: String {
        switch self {
        case .text: return "Text (Cx 2%)"
        case .meters: return "Meters"
        case .number: return "Number (85%)"
        case .dot: return "Dot"
        }
    }
}

/// The complete, editable settings state shown by the settings window.
public struct SettingsDraft: Equatable {
    public var cadenceSeconds: Double
    public var codexEnabled: Bool
    public var claudeEnabled: Bool
    public var geminiEnabled: Bool
    public var notificationsEnabled: Bool
    public var menuBarStyle: MenuBarStyle
    public var monthlyBudgetUSD: Double
    public var maskAccounts: Bool
    public var launchAtLogin: Bool
    public var providerSettings: ProviderSettings
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var providers: [ProviderUsage] = []
    public private(set) var lastRefresh: Date?
    public private(set) var isRefreshing = false
    public private(set) var labelImage: NSImage?

    /// Which provider tab (Claude / Codex / Gemini) is shown in the detail panel.
    public var selectedKind: ProviderKind?

    private var lastClaude: [ProviderUsage] = []
    /// The resolved Claude profiles represented by the currently applied settings.
    /// Disabled Claude is intentionally represented by no effective profiles.
    private var appliedClaudeConfigs: [String: ClaudeAccountConfig]
    private let debugEnabled = ProcessInfo.processInfo.environment["AIUSAGEBAR_DEBUG"] != nil

    // Settings (persisted). The menu's live controls mutate these directly; the
    // `didSet` handlers persist/reconfigure, and are suppressed during `apply(_:)`.
    public var cadenceSeconds: Double { didSet { settingChanged() } }
    public var codexEnabled: Bool { didSet { settingChanged(rebuildConfig: true) } }
    public var claudeEnabled: Bool { didSet { settingChanged(rebuildConfig: true) } }
    public var geminiEnabled: Bool { didSet { settingChanged(rebuildConfig: true) } }
    public var notificationsEnabled: Bool { didSet { settingChanged(); notifier.enabled = notificationsEnabled } }
    public var menuBarStyle: MenuBarStyle { didSet { settingChanged(); updateLabel() } }
    /// Optional monthly $ budget for the cost gauge (0 = off).
    public var monthlyBudgetUSD: Double { didSet { settingChanged() } }
    /// Masks emails + repo names in the panel (for screen-sharing).
    public var maskAccounts: Bool { didSet { settingChanged() } }
    /// Claude accounts the user has signed into via our own OAuth (Settings →
    /// Claude → Add account). Live limits come from a token we mint and store in our
    /// own Keychain item, so nothing ever prompts for Keychain access.
    public private(set) var claudeAccounts: [ClaudeAccountSummary]
    /// True while an interactive sign-in is in flight (browser open, awaiting code).
    public private(set) var signingInClaude = false
    /// Last sign-in failure, for the Settings UI (nil when none / user cancelled).
    public var claudeSignInError: String?
    private var providerSettings: ProviderSettings

    /// Suppresses the reactive `didSet` handlers during a bulk `apply(_:)`.
    private var isApplying = false

    public let notifier = UsageNotifier()
    private let history = UsageHistory()

    private var service: UsageService
    private var pollTask: Task<Void, Never>?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        let cadenceSeconds = defaults.object(forKey: "cadenceSeconds") as? Double ?? 45
        let codexEnabled = defaults.object(forKey: "codexEnabled") as? Bool ?? true
        let claudeEnabled = defaults.object(forKey: "claudeEnabled") as? Bool ?? true
        let geminiEnabled = defaults.object(forKey: "geminiEnabled") as? Bool ?? true
        let notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        let menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .text
        let monthlyBudgetUSD = defaults.object(forKey: "monthlyBudgetUSD") as? Double ?? 0
        let maskAccounts = defaults.object(forKey: "maskAccounts") as? Bool ?? false
        let providerSettings = ProviderSettings.load(from: defaults)
        let initialConfig = Self.usageConfig(
            providerSettings: providerSettings,
            codexEnabled: codexEnabled,
            claudeEnabled: claudeEnabled,
            geminiEnabled: geminiEnabled
        )

        self.defaults = defaults
        self.cadenceSeconds = cadenceSeconds
        self.codexEnabled = codexEnabled
        self.claudeEnabled = claudeEnabled
        self.geminiEnabled = geminiEnabled
        self.notificationsEnabled = notificationsEnabled
        self.menuBarStyle = menuBarStyle
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.maskAccounts = maskAccounts
        self.claudeAccounts = Self.loadClaudeAccounts(configs: providerSettings.claudeAccountConfigs)
        self.providerSettings = providerSettings
        self.appliedClaudeConfigs = Self.effectiveClaudeConfigs(for: initialConfig)
        self.service = UsageService(config: initialConfig)
        notifier.enabled = notificationsEnabled
    }

    // MARK: Polling

    public func startPolling() {
        notifier.requestAuthorization()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let secs = self?.cadenceSeconds ?? 45
                try? await Task.sleep(for: .seconds(secs))
            }
        }
    }

    public func stopPolling() { pollTask?.cancel() }

    public func refresh() async {
        isRefreshing = true

        // 1. Publish fast local providers (Codex + Gemini) immediately, with
        //    identity-only Claude placeholders so the panel is never blank.
        let local = await service.readLocal()
        if !claudeEnabled {
            lastClaude = []
        } else if lastClaude.isEmpty {
            lastClaude = await service.claudePlaceholders()
        }
        rebuild(local: local)

        // 2. Claude live data (may briefly block on a first-run Keychain prompt).
        let claude = await service.readClaude()
        if claudeEnabled, !claude.isEmpty { lastClaude = claude }
        rebuild(local: local)

        notifier.evaluate(providers)
        history.record(providers)
        lastRefresh = Date()
        isRefreshing = false
        writeDebugLog()
    }

    /// Recent 24h series for a window, for its sparkline.
    public func sparkline(_ providerId: String, _ window: UsageWindow) -> [Double] {
        let key = UsageHistory.key(providerId: providerId, windowLabel: window.name ?? window.kind.shortLabel)
        return history.series(forKey: key, since: Date().addingTimeInterval(-24 * 3600))
    }

    /// Rebuilds the ordered provider list (Codex → Claude profiles → Gemini),
    /// the menu-bar label, and keeps a valid tab selected.
    private func rebuild(local: (codex: ProviderUsage?, gemini: ProviderUsage?, customs: [ProviderUsage])) {
        var arr: [ProviderUsage] = []
        if let c = local.codex { arr.append(c) }
        if claudeEnabled { arr.append(contentsOf: lastClaude) }
        if let g = local.gemini { arr.append(g) }
        arr.append(contentsOf: local.customs)
        providers = arr
        updateLabel()
        ensureSelection()
    }

    private func updateLabel() {
        switch menuBarStyle {
        case .text: labelImage = LabelRenderer.render(chips: labelChips())
        case .meters: labelImage = LabelRenderer.renderMeters(items: meterItems())
        case .number: labelImage = LabelRenderer.renderNumber(percent: overallWorst)
        case .dot: labelImage = LabelRenderer.renderDot(percent: overallWorst)
        }
    }

    /// Highest window % across every provider/account (for number/dot styles).
    public var overallWorst: Double? {
        providers.compactMap { $0.maxUsedPercent }.max()
    }

    /// One-line summary of a card, e.g. "Claude — Work: 5H 73% · 7D 7%".
    public func peek(_ card: ProviderUsage) -> String {
        if card.windows.isEmpty {
            return "\(card.displayName): \(card.detail ?? Theme.statusText(card.status))"
        }
        let ws = card.windows
            .map { "\($0.name ?? $0.kind.shortLabel) \(Int(($0.usedPercent ?? 0).rounded()))%" }
            .joined(separator: " · ")
        return "\(card.displayName): \(ws)"
    }

    /// Multi-line snapshot of all providers, for sharing.
    public func snapshotText() -> String {
        var lines = ["AI Usage"]
        for kind in kinds { for card in cards(for: kind) { lines.append(peek(card)) } }
        return lines.joined(separator: "\n")
    }

    public func copySnapshot() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshotText(), forType: .string)
    }

    /// One dual-bar meter item per provider kind (worst 5h / weekly across accounts).
    public func meterItems() -> [MenuBarMeterItem] {
        var items: [MenuBarMeterItem] = []
        for kind in [ProviderKind.codex, .claude, .gemini, .custom] {
            let cards = providers.filter { $0.kind == kind }
            guard !cards.isEmpty else { continue }
            let allWindows = cards.flatMap { $0.windows }
            let five = allWindows.filter { $0.kind == .fiveHour }.compactMap { $0.usedPercent }.max()
            let week = allWindows.filter { $0.kind == .weekly && $0.name == nil }.compactMap { $0.usedPercent }.max()
            if five == nil && week == nil { continue }
            items.append(MenuBarMeterItem(code: Theme.shortCode(for: kind), fiveHour: five, weekly: week))
        }
        return items
    }

    /// Provider kinds present, in a stable tab order.
    public var kinds: [ProviderKind] {
        let present = Set(providers.map(\.kind))
        return [.claude, .codex, .gemini, .custom].filter(present.contains)
    }

    /// All account cards for a kind (e.g. both Claude profiles), in order.
    public func cards(for kind: ProviderKind?) -> [ProviderUsage] {
        guard let kind else { return [] }
        return providers.filter { $0.kind == kind }
    }

    private func ensureSelection() {
        let present = kinds
        if let k = selectedKind, present.contains(k) { return }
        // Default to Claude (the primary agent) when present, else the first tab.
        selectedKind = present.contains(.claude) ? .claude : present.first
    }

    /// Highest window % across all accounts of a kind (for tab warning dots).
    public func worstPercent(for kind: ProviderKind) -> Double? {
        providers.filter { $0.kind == kind }.compactMap { $0.maxUsedPercent }.max()
    }

    private func writeDebugLog() {
        guard debugEnabled else { return }
        var lines = ["--- refresh \(Date()) ---"]
        for p in providers {
            let wins = p.windows.map { "\($0.displayLabel)=\($0.usedPercent.map { String(Int($0)) } ?? "nil")%" }.joined(separator: ",")
            lines.append("\(p.id) [\(p.status.rawValue)] plan=\(p.planType ?? "-") wins=[\(wins)] detail=\(p.detail ?? "-")")
        }
        let text = lines.joined(separator: "\n") + "\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ai-usage-bar-debug.log")
        if let data = text.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    // MARK: Derived

    /// One chip per provider kind, using the worst window across that kind's cards.
    public func labelChips() -> [LabelChip] {
        var chips: [LabelChip] = []
        for kind in [ProviderKind.codex, .claude, .gemini, .custom] {
            let cards = providers.filter { $0.kind == kind }
            guard !cards.isEmpty else { continue }
            let pct = cards.compactMap { $0.maxUsedPercent }.max()
            let throttled = cards.contains { $0.isThrottled }
            // Skip kinds with no percentage AND nothing meaningful to show.
            if pct == nil && cards.allSatisfy({ $0.status == .notInstalled }) { continue }
            if pct == nil { continue }
            chips.append(LabelChip(code: Theme.shortCode(for: kind), percent: pct, throttled: throttled))
        }
        return chips
    }

    // MARK: Settings

    public var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            guard newValue != launchAtLogin else { return }
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("ai-usage-bar: launch-at-login toggle failed: \(error)")
            }
        }
    }

    public func settingsDraft() -> SettingsDraft {
        SettingsDraft(
            cadenceSeconds: cadenceSeconds,
            codexEnabled: codexEnabled,
            claudeEnabled: claudeEnabled,
            geminiEnabled: geminiEnabled,
            notificationsEnabled: notificationsEnabled,
            menuBarStyle: menuBarStyle,
            monthlyBudgetUSD: monthlyBudgetUSD,
            maskAccounts: maskAccounts,
            launchAtLogin: launchAtLogin,
            providerSettings: providerSettings
        )
    }

    /// Validates and applies every setting as a single refresh operation.
    /// Returns a validation message without changing live state when invalid.
    public func apply(_ draft: SettingsDraft) async -> String? {
        // Claude account configs (name/logs) are edited live on the model, not via the
        // settings draft — so an Apply of *other* settings must not revert them.
        var settings = draft.providerSettings
        settings.claudeAccountConfigs = providerSettings.claudeAccountConfigs
        var config = settings.usageConfig(
            codexEnabled: draft.codexEnabled,
            claudeEnabled: draft.claudeEnabled,
            geminiEnabled: draft.geminiEnabled
        )
        Self.applyRuntimeOverrides(to: &config)
        let effectiveClaudeConfigs = Self.effectiveClaudeConfigs(for: config)
        let shouldClearClaudeCards = appliedClaudeConfigs != effectiveClaudeConfigs

        isApplying = true
        cadenceSeconds = draft.cadenceSeconds
        codexEnabled = draft.codexEnabled
        claudeEnabled = draft.claudeEnabled
        geminiEnabled = draft.geminiEnabled
        notificationsEnabled = draft.notificationsEnabled
        menuBarStyle = draft.menuBarStyle
        monthlyBudgetUSD = draft.monthlyBudgetUSD
        maskAccounts = draft.maskAccounts
        providerSettings = settings          // draft settings + preserved account configs
        isApplying = false
        notifier.enabled = notificationsEnabled
        launchAtLogin = draft.launchAtLogin
        persist()

        if shouldClearClaudeCards || !draft.claudeEnabled { lastClaude = [] }
        appliedClaudeConfigs = effectiveClaudeConfigs
        await service.update(config: config)
        await refresh()
        return nil
    }

    private func persist() {
        defaults.set(cadenceSeconds, forKey: "cadenceSeconds")
        defaults.set(codexEnabled, forKey: "codexEnabled")
        defaults.set(claudeEnabled, forKey: "claudeEnabled")
        defaults.set(geminiEnabled, forKey: "geminiEnabled")
        defaults.set(notificationsEnabled, forKey: "notificationsEnabled")
        defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle")
        defaults.set(monthlyBudgetUSD, forKey: "monthlyBudgetUSD")
        defaults.set(maskAccounts, forKey: "maskAccounts")
        providerSettings.save(to: defaults)
    }

    /// Sign into a Claude account via our own OAuth. Opens the browser, captures the
    /// code on a loopback listener, mints a token, and stores it in our own Keychain
    /// item — so this never prompts for access to Claude Code's Keychain entry.
    public func addClaudeAccount() {
        guard !signingInClaude else { return }
        signingInClaude = true
        claudeSignInError = nil
        Task {
            do {
                _ = try await ClaudeTokenProvider.signIn(openURL: { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                })
                signingInClaude = false
                lastClaude = []
                reloadClaudeAccounts()
                reconfigure()
                await refresh()
            } catch ClaudeOAuthError.cancelled {
                signingInClaude = false            // user closed the browser — silent
            } catch {
                signingInClaude = false
                claudeSignInError = Self.describeSignInError(error)
            }
        }
    }

    /// Remove a signed-in account (deletes its stored token + config) and its card.
    public func removeClaudeAccount(_ key: String) {
        Task {
            await ClaudeTokenProvider.shared.signOut(account: key)
            providerSettings.claudeAccountConfigs[key] = nil
            lastClaude = []
            persist()
            reloadClaudeAccounts()
            reconfigure()
            await refresh()
        }
    }

    /// Set a friendly display name for an account (empty clears back to the email).
    public func renameClaudeAccount(_ key: String, to name: String) {
        var cfg = providerSettings.claudeAccountConfigs[key] ?? ClaudeAccountConfig()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.name = trimmed.isEmpty ? nil : trimmed
        updateClaudeConfig(key, cfg)
    }

    /// Point an account at a logs folder to show $ cost (nil = cost off).
    public func setClaudeAccountLogs(_ key: String, dir: String?) {
        var cfg = providerSettings.claudeAccountConfigs[key] ?? ClaudeAccountConfig()
        cfg.logsDir = dir
        updateClaudeConfig(key, cfg)
    }

    private func updateClaudeConfig(_ key: String, _ cfg: ClaudeAccountConfig) {
        // Drop the entry entirely when it carries nothing (keeps the map sparse).
        providerSettings.claudeAccountConfigs[key] = (cfg.name == nil && cfg.logsDir == nil) ? nil : cfg
        lastClaude = []
        persist()
        reloadClaudeAccounts()
        reconfigure()
        Task { await refresh() }
    }

    /// Refresh the account list shown in Settings from the token store + configs.
    public func reloadClaudeAccounts() {
        claudeAccounts = Self.loadClaudeAccounts(configs: providerSettings.claudeAccountConfigs)
    }

    private static func loadClaudeAccounts(configs: [String: ClaudeAccountConfig]) -> [ClaudeAccountSummary] {
        ClaudeTokenProvider.shared.accounts().map { token in
            let key = ClaudeTokenStore.accountKey(for: token)
            // A stored name equal to the email is not a real custom name (older builds
            // could persist that) — treat it as none so the email shows as default.
            var name = configs[key]?.name
            if let n = name, n.caseInsensitiveCompare(token.accountEmail ?? "\u{0}") == .orderedSame { name = nil }
            return ClaudeAccountSummary(key: key, email: token.accountEmail,
                                        name: name, logsDir: configs[key]?.logsDir)
        }
    }

    private static func describeSignInError(_ error: Error) -> String {
        switch error {
        case ClaudeOAuthError.stateMismatch: return "Sign-in check failed (state mismatch). Please try again."
        case ClaudeOAuthError.invalidGrant: return "Authorization expired. Please try again."
        case let ClaudeOAuthError.http(code, _): return "Sign-in failed (HTTP \(code))."
        case let ClaudeOAuthError.transport(msg): return "Couldn't reach Claude: \(msg)"
        default: return "Sign-in failed. Please try again."
        }
    }

    /// Reactive path for the menu's live controls; a no-op during `apply(_:)`.
    private func settingChanged(rebuildConfig: Bool = false) {
        guard !isApplying else { return }
        persist()
        if rebuildConfig { reconfigure() }
    }

    /// Rebuilds the service config from the current settings (gear-menu path).
    private func reconfigure() {
        let config = Self.usageConfig(providerSettings: providerSettings,
                                      codexEnabled: codexEnabled,
                                      claudeEnabled: claudeEnabled,
                                      geminiEnabled: geminiEnabled)
        appliedClaudeConfigs = Self.effectiveClaudeConfigs(for: config)
        if !claudeEnabled { lastClaude = [] }
        Task { await service.update(config: config) }
    }

    private static func usageConfig(providerSettings: ProviderSettings,
                                    codexEnabled: Bool,
                                    claudeEnabled: Bool,
                                    geminiEnabled: Bool) -> UsageConfig {
        var config = providerSettings.usageConfig(codexEnabled: codexEnabled,
                                                  claudeEnabled: claudeEnabled,
                                                  geminiEnabled: geminiEnabled)
        applyRuntimeOverrides(to: &config)
        return config
    }

    private static func effectiveClaudeConfigs(for config: UsageConfig) -> [String: ClaudeAccountConfig] {
        config.claudeEnabled ? config.claudeAccountConfigs : [:]
    }

    private static func applyRuntimeOverrides(to config: inout UsageConfig) {
        // Live limits read our OWN OAuth token from our OWN Keychain item, which the
        // signed app can read without a prompt — so this is on by default. With no
        // accounts added, the store is empty and nothing live is fetched.
        // Dev/test escape hatch: force off (skips the token store + endpoint).
        config.allowKeychain = ProcessInfo.processInfo.environment["AIUSAGEBAR_NO_KEYCHAIN"] == nil
    }
}
