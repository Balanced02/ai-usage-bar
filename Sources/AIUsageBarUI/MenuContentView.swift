import SwiftUI
import Combine
import AIUsageBarCore

public struct MenuContentView: View {
    @Bindable public var model: AppModel
    private let openSettings: () -> Void

    public init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.providers.isEmpty {
                loading
            } else {
                KindTabBar(kinds: model.kinds, worst: model.worstPercent(for:), selection: $model.selectedKind)
                Divider()
                if model.selectedKind == .claude && !model.claudeConnected {
                    ClaudeConnectBanner { model.connectClaude() }
                }
                KindDetailView(cards: model.cards(for: model.selectedKind),
                               history: { card, window in model.sparkline(card.id, window) },
                               budget: model.monthlyBudgetUSD,
                               masked: model.maskAccounts)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 344)
        // Report the content's natural height so the hosting NSPopover sizes to it.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack {
            Text("AI Usage").font(.headline)
            Spacer()
            if let last = model.lastRefresh {
                RelativeUpdatedLabel(date: last)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading usage…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
                .toggleStyle(.checkbox)
                .font(.callout)

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Quit")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })
    }
}

/// Shown in the Claude tab until the user opts in to live limits — this keeps the
/// Keychain read (and its one-time macOS prompt) out of the app's launch path.
struct ClaudeConnectBanner: View {
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.tint)
                Text("Connect Claude for live limits").font(.callout.weight(.semibold))
            }
            Text("Reads the token Claude Code already stored to show your 5-hour and weekly limits. macOS asks once — choose “Always Allow.” Your account and cost still show without connecting.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect", action: action)
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25)))
    }
}

/// Live-updating "updated Ns ago" label.
struct RelativeUpdatedLabel: View {
    let date: Date
    @State private var now = Date()
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("updated \(short(now.timeIntervalSince(date)))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .onReceive(timer) { now = $0 }
    }

    private func short(_ secs: TimeInterval) -> String {
        let s = Int(max(0, secs))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}
