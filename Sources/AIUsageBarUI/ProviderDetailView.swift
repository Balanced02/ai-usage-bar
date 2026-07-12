import SwiftUI
import AppKit
import AIUsageBarCore

/// The detail side: every account of the selected kind, stacked. Under "Claude"
/// this shows Personal + Work together, each color-coded, with per-model windows.
public struct KindDetailView: View {
    public let cards: [ProviderUsage]
    public init(cards: [ProviderUsage]) { self.cards = cards }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                AccountBlock(usage: card, accent: Theme.accountColor(index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One account: header (colored dot · name · plan · email) then its windows.
struct AccountBlock: View {
    let usage: ProviderUsage
    let accent: Color

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

    private var needsSignIn: Bool {
        usage.kind == .claude && usage.windows.isEmpty &&
        (usage.status == .notConfigured || (usage.detail?.contains("Not signed in") ?? false))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            if usage.windows.isEmpty {
                emptyState
            } else {
                VStack(spacing: 12) {
                    ForEach(usage.windows) { WindowRow(window: $0, accent: accent) }
                }
                if let note = footnote {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
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
                Text(email)
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
            if needsSignIn { SignInHint(configDir: usage.sourcePath) }
        }
    }

    private var footnote: String? {
        var parts: [String] = []
        if let c = usage.credits, let b = c.balance, b != "0" { parts.append("Credits: \(b)") }
        if let t = Theme.compactTokens(usage.tokens?.totalTokens) {
            parts.append(usage.kind == .codex ? "\(t) session tokens" : "\(t) tokens")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }
}

/// One window row: `LABEL   45%            resets in…` over a full-width meter,
/// with a pace tick and (only when relevant) a burn-rate warning.
struct WindowRow: View {
    let window: UsageWindow
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(window.name ?? window.kind.shortLabel)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 17, weight: .bold)).monospacedDigit()
                    .foregroundStyle((window.usedPercent ?? 0) >= 90 ? .red : .primary)
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

/// Inline helper for a Claude profile that isn't signed into the Keychain.
struct SignInHint: View {
    let configDir: String?
    @State private var copied = false

    private var command: String {
        guard let dir = configDir else { return "claude" }
        return dir.hasSuffix("/.claude") ? "claude" : "CLAUDE_CONFIG_DIR=\(abbreviate(dir)) claude"
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command + "   # then run /login", forType: .string)
            copied = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text(copied ? "Copied — run it, then /login" : "Copy sign-in command")
            }
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
