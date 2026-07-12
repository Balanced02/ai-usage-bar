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

/// How the menu-bar title is drawn.
public enum MenuBarStyle: String, Sendable, CaseIterable {
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
    private let debugEnabled = ProcessInfo.processInfo.environment["AIUSAGEBAR_DEBUG"] != nil

    // Settings (persisted).
    public var cadenceSeconds: Double { didSet { persist(); } }
    public var codexEnabled: Bool { didSet { persist(); reconfigure() } }
    public var claudeEnabled: Bool { didSet { persist(); reconfigure() } }
    public var geminiEnabled: Bool { didSet { persist(); reconfigure() } }
    public var notificationsEnabled: Bool { didSet { persist(); notifier.enabled = notificationsEnabled } }
    public var menuBarStyle: MenuBarStyle { didSet { persist(); updateLabel() } }
    /// Optional monthly $ budget for the cost gauge (0 = off).
    public var monthlyBudgetUSD: Double { didSet { persist() } }
    /// Masks emails + repo names in the panel (for screen-sharing).
    public var maskAccounts: Bool { didSet { persist() } }

    public let notifier = UsageNotifier()
    private let history = UsageHistory()

    private var service: UsageService
    private var pollTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    public init() {
        cadenceSeconds = defaults.object(forKey: "cadenceSeconds") as? Double ?? 45
        codexEnabled = defaults.object(forKey: "codexEnabled") as? Bool ?? true
        claudeEnabled = defaults.object(forKey: "claudeEnabled") as? Bool ?? true
        geminiEnabled = defaults.object(forKey: "geminiEnabled") as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .text
        monthlyBudgetUSD = defaults.object(forKey: "monthlyBudgetUSD") as? Double ?? 0
        maskAccounts = defaults.object(forKey: "maskAccounts") as? Bool ?? false
        service = UsageService(config: Self.buildConfig(codex: true, claude: true, gemini: true))
        reconfigure()
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
        if lastClaude.isEmpty { lastClaude = await service.claudePlaceholders() }
        rebuild(local: local)

        // 2. Claude live data (may briefly block on a first-run Keychain prompt).
        let claude = await service.readClaude()
        if !claude.isEmpty { lastClaude = claude }
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
    private func rebuild(local: (codex: ProviderUsage?, gemini: ProviderUsage?)) {
        var arr: [ProviderUsage] = []
        if let c = local.codex { arr.append(c) }
        arr.append(contentsOf: lastClaude)
        if let g = local.gemini { arr.append(g) }
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
        for kind in [ProviderKind.codex, .claude, .gemini] {
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
        return [.claude, .codex, .gemini].filter(present.contains)
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
        for kind in [ProviderKind.codex, .claude, .gemini] {
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
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("ai-usage-bar: launch-at-login toggle failed: \(error)")
            }
        }
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
    }

    private func reconfigure() {
        let config = Self.buildConfig(codex: codexEnabled, claude: claudeEnabled, gemini: geminiEnabled)
        Task { await service.update(config: config) }
    }

    private static func buildConfig(codex: Bool, claude: Bool, gemini: Bool) -> UsageConfig {
        var config = UsageConfig.autoDetect()
        config.codexEnabled = codex
        config.claudeEnabled = claude
        config.geminiEnabled = gemini
        // Dev/test escape hatch: skip Keychain + live endpoint (Claude falls back
        // to local token activity). Set AIUSAGEBAR_NO_KEYCHAIN=1 to enable.
        if ProcessInfo.processInfo.environment["AIUSAGEBAR_NO_KEYCHAIN"] != nil {
            config.allowKeychain = false
        }
        return config
    }
}
