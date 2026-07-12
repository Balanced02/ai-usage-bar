import SwiftUI
import Combine
import AIUsageBarCore

public struct MenuContentView: View {
    @Bindable public var model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.providers.isEmpty {
                loading
            } else {
                KindTabBar(kinds: model.kinds, worst: model.worstPercent(for:), selection: $model.selectedKind)
                Divider()
                KindDetailView(cards: model.cards(for: model.selectedKind),
                               history: { card, window in model.sparkline(card.id, window) })
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

            Menu {
                Section("Refresh every") {
                    Picker("Cadence", selection: $model.cadenceSeconds) {
                        Text("30s").tag(30.0)
                        Text("45s").tag(45.0)
                        Text("1m").tag(60.0)
                        Text("2m").tag(120.0)
                        Text("5m").tag(300.0)
                    }
                    .pickerStyle(.inline)
                }
                Section("Providers") {
                    Toggle("Codex", isOn: $model.codexEnabled)
                    Toggle("Claude", isOn: $model.claudeEnabled)
                    Toggle("Gemini", isOn: $model.geminiEnabled)
                }
                Section("Menu bar") {
                    Picker("Style", selection: $model.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Section {
                    Toggle("Notifications", isOn: $model.notificationsEnabled)
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

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
