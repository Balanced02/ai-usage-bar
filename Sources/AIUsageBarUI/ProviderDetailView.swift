import SwiftUI
import AppKit
import AIUsageBarCore

/// The detail side: every account of the selected kind, stacked. Under "Claude"
/// this shows Personal + Work together, each color-coded, with per-model windows.
public struct KindDetailView: View {
    public let cards: [ProviderUsage]
    /// Optional 24h sample lookup for sparklines.
    public var history: ((ProviderUsage, UsageWindow) -> [Double])?
    public var budget: Double
    public var masked: Bool

    public init(cards: [ProviderUsage],
                history: ((ProviderUsage, UsageWindow) -> [Double])? = nil,
                budget: Double = 0,
                masked: Bool = false) {
        self.cards = cards
        self.history = history
        self.budget = budget
        self.masked = masked
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let rec = recommendation {
                RecommendationBanner(name: rec.name, accent: rec.accent,
                                     headroom: rec.headroom, tightest: rec.tightest)
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    AccountBlock(usage: card, accent: Theme.accountColor(index),
                                 history: history.map { lookup in { window in lookup(card, window) } },
                                 budget: budget, masked: masked)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Best account to use right now: the one whose tightest window has the most
    /// headroom. Only shown when 2+ accounts of the same kind have live windows.
    private var recommendation: (name: String, accent: Color, headroom: Double, tightest: String)? {
        guard cards.count >= 2 else { return nil }
        let ranked = cards.enumerated()
            .filter { $0.element.maxUsedPercent != nil }
            .map { (index: $0.offset, card: $0.element, headroom: 100 - ($0.element.maxUsedPercent ?? 100)) }
            .sorted { $0.headroom > $1.headroom }
        guard ranked.count >= 2, let best = ranked.first else { return nil }
        // Don't bother if they're basically tied.
        guard best.headroom - ranked[1].headroom >= 3 else { return nil }
        let name = best.card.displayName.components(separatedBy: " — ").last ?? best.card.displayName
        let tight = best.card.windows.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
        let tightStr = tight.map { "\($0.name ?? $0.kind.shortLabel) \(Int(($0.usedPercent ?? 0).rounded()))%" } ?? ""
        return (name, Theme.accountColor(best.index), best.headroom, tightStr)
    }
}

/// "Use Work — 88% free" hint above the account list.
struct RecommendationBanner: View {
    let name: String
    let accent: Color
    let headroom: Double
    let tightest: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lightbulb.fill").font(.caption2).foregroundStyle(.yellow)
            Text("Use \(name)").font(.caption).fontWeight(.semibold)
            Text("· \(Int(headroom.rounded()))% free").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if !tightest.isEmpty {
                Text("tightest \(tightest)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.12)))
    }
}

/// One account: header (colored dot · name · plan · email) then its windows.
struct AccountBlock: View {
    let usage: ProviderUsage
    let accent: Color
    var history: ((UsageWindow) -> [Double])? = nil
    var budget: Double = 0
    var masked: Bool = false

    private var accountName: String {
        usage.displayName.components(separatedBy: " — ").last ?? usage.displayName
    }

    private var isStale: Bool {
        if let d = usage.detail,
           d.contains("Rate limited") || d.contains("unavailable") || d.contains("expired") { return true }
        if !usage.windows.isEmpty, let lu = usage.lastUpdated,
           Date().timeIntervalSince(lu) > 300 { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            if usage.windows.isEmpty {
                // No live limits (not connected) — show ccusage-style local usage
                // from the logs so the account is still useful without the Keychain.
                if let cost = usage.cost, cost.last7dTokens > 0 {
                    LocalUsageRows(cost: cost, accent: accent)
                } else {
                    emptyState
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(usage.windows) { WindowRow(window: $0, accent: accent, samples: history?($0) ?? []) }
                }
            }

            if let hint = downshiftHint {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.orange)
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.10)))
            }
            if let cost = usage.cost, cost.totalTokens > 0 {
                CostSection(cost: cost, budget: budget, masked: masked)
            }
            if let note = footnote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// "Opus is 72% of spend · 7D Opus 90% — Sonnet has 53% left, try /model sonnet".
    /// Only when the top-spend premium model's weekly window is high and a cheaper
    /// model still has headroom.
    private var downshiftHint: String? {
        guard usage.kind == .claude, let cost = usage.cost, let top = cost.byModel.first else { return nil }
        let total = cost.byModel.reduce(0) { $0 + $1.usd }
        guard total > 0 else { return nil }
        let share = top.usd / total
        let rank = ["fable": 0, "haiku": 1, "sonnet": 2, "opus": 3]
        guard let topRank = rank[top.model.lowercased()], topRank >= 2, share >= 0.5 else { return nil }

        func window(_ model: String) -> Double? {
            usage.windows.first { ($0.name ?? "").lowercased().contains(model.lowercased()) }?.usedPercent
        }
        guard let topPct = window(top.model), topPct >= 70 else { return nil }

        // Prefer the next-cheaper model that still has room.
        for cheaper in ["sonnet", "haiku"] where (rank[cheaper] ?? 0) < topRank {
            if let p = window(cheaper), p < 50 {
                return "\(top.model) is \(Int((share * 100).rounded()))% of spend · 7D \(top.model.uppercased()) \(Int(topPct.rounded()))% — \(cheaper.capitalized) has \(Int(100 - p))% left, try /model \(cheaper)"
            }
        }
        return nil
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(accent).frame(width: 9, height: 9)
            Button {
                if let url = Theme.dashboardURL(for: usage.kind) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 3) {
                    Text(accountName).font(.system(size: 15, weight: .bold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help("Open \(Theme.kindName(usage.kind)) usage dashboard")

            if let plan = usage.planType {
                Text(plan)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            if usage.isThrottled {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
            }
            if isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("Data may be stale")
            }
            Spacer(minLength: 8)
            if let email = usage.accountLabel {
                Text(masked ? Theme.maskEmail(email) : email)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Theme.statusColor(usage.status)).frame(width: 6, height: 6)
                Text(usage.detail ?? Theme.statusText(usage.status))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footnote: String? {
        var parts: [String] = []
        if let c = usage.credits, let b = c.balance, b != "0" { parts.append("Credits: \(b)") }
        // Codex token total; Claude tokens are shown in the cost section instead.
        if usage.kind == .codex, let t = Theme.compactTokens(usage.tokens?.totalTokens) {
            parts.append("\(t) session tokens")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }
}

/// One window row: `LABEL   45%            resets in…` over a full-width meter,
/// with a pace tick and (only when relevant) a burn-rate warning.
/// ccusage-style local usage windows (5H / 7D) derived from the logs — token
/// volume + equivalent cost, no live quota %. Shown when a Claude account isn't
/// connected, so it stays useful without any Keychain access.
struct LocalUsageRows: View {
    let cost: CostSummary
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            usageRow("5H", tokens: cost.last5hTokens, usd: cost.last5hUSD)
            usageRow("7D", tokens: cost.last7dTokens, usd: cost.last7dUSD)
            Text("Local activity from your logs — Connect for the live limit %.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func usageRow(_ label: String, tokens: Int, usd: Double) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12, weight: .semibold))
                .frame(width: 32, alignment: .leading)
            Text("\(Theme.compactTokens(tokens) ?? "0") tok")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(Theme.usd(usd))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.modelColor("Opus"))
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let accent: Color
    var samples: [Double] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(window.name ?? window.kind.shortLabel)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 17, weight: .bold)).monospacedDigit()
                    .foregroundStyle((window.usedPercent ?? 0) >= 90 ? .red : .primary)
                if samples.count >= 3 {
                    Sparkline(values: samples, color: accent)
                        .frame(width: 42, height: 12)
                        .padding(.leading, 2)
                }
                Spacer(minLength: 8)
                if let reset = Theme.resetText(for: window) {
                    Text(reset).font(.caption).foregroundStyle(.secondary)
                }
            }
            MeterBar(percent: window.usedPercent, height: 6,
                     color: Theme.barColor(percent: window.usedPercent, accent: accent),
                     tick: windowProjection(window)?.elapsedPercent)
            if let burn = Theme.burnRateText(for: window) {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill").font(.system(size: 8))
                    Text(burn).font(.caption2)
                }
                .foregroundStyle(.orange)
            }
        }
    }
}

