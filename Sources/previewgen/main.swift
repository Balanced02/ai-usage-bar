import SwiftUI
import AppKit
import AIUsageBarCore
import AIUsageBarUI

// Renders fixture-backed UI images to PNGs for README/design review.
//   previewgen <outputDir>

@MainActor
func png(_ view: some View, scale: CGFloat = 2) -> Data? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

func win(_ kind: WindowKind, _ pct: Double, _ mins: Int, _ inHours: Double, _ name: String? = nil) -> UsageWindow {
    UsageWindow(kind: kind, usedPercent: pct, windowMinutes: mins,
                resetsAt: Date().addingTimeInterval(inHours * 3600), name: name)
}

// A Claude account whose Opus weekly window is high while Sonnet has room — trips
// the downshift nudge.
func downshiftCard() -> ProviderUsage {
    ProviderUsage(id: "claude:personal", kind: .claude, displayName: "Claude — Personal",
                  accountLabel: "you@example.com", planType: "Max",
                  windows: [win(.fiveHour, 20, 300, 3), win(.weekly, 60, 10080, 100),
                            win(.weekly, 90, 10080, 100, "7D OPUS"),
                            win(.weekly, 20, 10080, 100, "7D SONNET")],
                  cost: CostSummary(todayUSD: 5, monthUSD: 200, monthToDateUSD: 130, totalTokens: 30_000_000,
                                    byModel: [ModelCost(model: "Opus", tokens: 24_000_000, usd: 180),
                                              ModelCost(model: "Sonnet", tokens: 6_000_000, usd: 20)],
                                    byRepo: [RepoCost(repo: "api-server", tokens: 20_000_000, usd: 140),
                                             RepoCost(repo: "web-app", tokens: 10_000_000, usd: 60)],
                                    cacheHitRatio: 0.80, cacheSavedUSD: 30),
                  status: .ok, lastUpdated: Date())
}

// Synthetic 24h series so sparklines show in the static previews.
func syntheticHistory(_ card: ProviderUsage, _ window: UsageWindow) -> [Double] {
    let p = window.usedPercent ?? 0
    let n = 24
    return (0..<n).map { i in
        let frac = Double(i) / Double(n - 1)
        if window.kind == .fiveHour {
            let saw = (frac * 3).truncatingRemainder(dividingBy: 1.0)  // reset sawtooth
            return min(100, saw * p * 1.3)
        }
        return frac * p  // weekly ramp
    }
}

// A non-interactive panel mirroring MenuContentView for snapshots.
struct PreviewPanel: View {
    let title: String
    let providers: [ProviderUsage]
    let kind: ProviderKind
    var masked: Bool = false
    var body: some View {
        let kinds = [ProviderKind.claude, .codex, .gemini, .custom].filter { k in providers.contains { $0.kind == k } }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI Usage").font(.headline)
                Spacer()
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            }
            KindTabBar(kinds: kinds,
                       worst: { k in providers.filter { $0.kind == k }.compactMap { $0.maxUsedPercent }.max() },
                       selection: .constant(kind))
            Divider()
            KindDetailView(cards: providers.filter { $0.kind == kind }, history: syntheticHistory, masked: masked)
            Divider()
            HStack {
                Image(systemName: "checkmark.square.fill").foregroundStyle(.blue)
                Text("Launch at login").font(.callout)
                Spacer()
                Image(systemName: "gearshape").foregroundStyle(.secondary)
                Image(systemName: "power").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 344)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A fixture-only rendering of the two visible portions of `SettingsView`.
///
/// This deliberately does not construct `AppModel`: previews must not read
/// UserDefaults, discover local configuration folders, or expose a developer's
/// actual paths. Keep every string here as an example-only value.
private struct SettingsPreviewFixture {
    static let example = SettingsPreviewFixture(
        refreshCadence: "5 minutes",
        menuBarStyle: "Text (Cx 2%)",
        monthlyBudget: "$250",
        codexRoot: "/config/codex",
        geminiRoot: "/config/gemini",
        automaticClaudeName: "Personal",
        automaticClaudeRoot: "/config/claude",
        manualClaudeName: "Studio",
        manualClaudeRoot: "/config/claude-studio"
    )

    let refreshCadence: String
    let menuBarStyle: String
    let monthlyBudget: String
    let codexRoot: String
    let geminiRoot: String
    let automaticClaudeName: String
    let automaticClaudeRoot: String
    let manualClaudeName: String
    let manualClaudeRoot: String
}

private struct SettingsPreview: View {
    enum Page {
        case general
        case dataLocations
    }

    let page: Page
    private let fixture = SettingsPreviewFixture.example

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch page {
            case .general:
                generalSection
                providersSection
            case .dataLocations:
                dataLocationsSection
            }
        }
        .padding(24)
        .frame(width: 620, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var generalSection: some View {
        settingsSection("General") {
            settingsCard {
                choiceRow(label: "Refresh cadence", value: fixture.refreshCadence)
                rowDivider
                choiceRow(label: "Menu bar style", value: fixture.menuBarStyle)
                rowDivider
                choiceRow(label: "Monthly budget", value: fixture.monthlyBudget)
                rowDivider
                toggleRow("Notifications")
                rowDivider
                toggleRow("Mask account details")
                rowDivider
                toggleRow("Launch at login")
            }
        }
    }

    private var providersSection: some View {
        settingsSection("Providers") {
            settingsCard {
                toggleRow("Codex")
                rowDivider
                toggleRow("Claude")
                rowDivider
                toggleRow("Gemini")
            }
        }
    }

    private var dataLocationsSection: some View {
        settingsSection("Data locations") {
            settingsCard {
                dataRootRow(label: "Codex data folder", path: fixture.codexRoot)
                rowDivider
                dataRootRow(label: "Gemini data folder", path: fixture.geminiRoot)
                rowDivider
                subsectionTitle("Automatic Claude profiles")
                profileRow(name: fixture.automaticClaudeName,
                           path: fixture.automaticClaudeRoot,
                           defaultProfile: true)
                trailingButton("Rescan")
                rowDivider
                subsectionTitle("Manual Claude profiles")
                manualProfileRow(name: fixture.manualClaudeName, path: fixture.manualClaudeRoot)
                trailingButton("Add profile")
                footerButtons
            }
        }
    }

    private func dataRootRow(label: String, path: String) -> some View {
        LabeledContent(label) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    fixtureButton("Choose folder")
                    fixtureButton("Use automatic")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func profileRow(name: String, path: String, defaultProfile: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name)
                if defaultProfile {
                    Text("Default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func manualProfileRow(name: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Name")
                    .foregroundStyle(.secondary)
                Text(name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    }
            }
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                fixtureButton("Choose folder")
                fixtureButton("Remove", destructive: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func settingsSection<Content: View>(_ title: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private func choiceRow(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 24)
            Text(value)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }

    private func toggleRow(_ label: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            FixtureSwitch()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }

    private func subsectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func trailingButton(_ title: String) -> some View {
        HStack {
            Spacer()
            fixtureButton(title)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var footerButtons: some View {
        HStack(spacing: 8) {
            Spacer()
            fixtureButton("Cancel")
            fixtureButton("Apply", primary: true)
        }
        .padding(12)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 12)
    }

    private func fixtureButton(_ title: String, primary: Bool = false,
                               destructive: Bool = false) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(primary ? Color.white : destructive ? Color.red : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(primary ? Color.accentColor : Color.primary.opacity(0.10))
            }
    }
}

private struct FixtureSwitch: View {
    var body: some View {
        ZStack(alignment: .trailing) {
            Capsule()
                .fill(Color.accentColor)
            Circle()
                .fill(.white)
                .padding(2)
        }
        .frame(width: 32, height: 20)
    }
}

let mockCost = CostSummary(
    todayUSD: 3.42, monthUSD: 128.5, monthToDateUSD: 84.0, totalTokens: 22_700_000,
    byModel: [ModelCost(model: "Opus", tokens: 14_000_000, usd: 92),
              ModelCost(model: "Sonnet", tokens: 7_000_000, usd: 30.5),
              ModelCost(model: "Haiku", tokens: 1_700_000, usd: 6)],
    byRepo: [RepoCost(repo: "api-server", tokens: 12_000_000, usd: 78,
                      byModel: [ModelCost(model: "Opus", tokens: 9_000_000, usd: 55),
                                ModelCost(model: "Sonnet", tokens: 2_400_000, usd: 18),
                                ModelCost(model: "Haiku", tokens: 600_000, usd: 5)],
                      dailyUSD: [3, 4, 2, 5, 6, 4, 7, 5, 9, 6, 8, 7, 6, 10]),
             RepoCost(repo: "web-app", tokens: 6_000_000, usd: 32,
                      byModel: [ModelCost(model: "Sonnet", tokens: 4_500_000, usd: 24),
                                ModelCost(model: "Opus", tokens: 1_500_000, usd: 8)],
                      dailyUSD: [1, 2, 1, 3, 2, 4, 2, 3, 1, 4, 3, 2, 3, 2]),
             RepoCost(repo: "infra", tokens: 4_700_000, usd: 18.5,
                      byModel: [ModelCost(model: "Haiku", tokens: 3_200_000, usd: 11),
                                ModelCost(model: "Sonnet", tokens: 1_500_000, usd: 7.5)],
                      dailyUSD: [0, 1, 0, 2, 1, 1, 2, 0, 3, 1, 2, 1, 2, 1.5])],
    cacheHitRatio: 0.84, cacheSavedUSD: 22.3)

func mockProviders() -> [ProviderUsage] {
    func w(_ kind: WindowKind, _ pct: Double, _ mins: Int, _ inHours: Double, name: String? = nil) -> UsageWindow {
        UsageWindow(kind: kind, usedPercent: pct, windowMinutes: mins,
                    resetsAt: Date().addingTimeInterval(inHours * 3600), name: name)
    }
    return [
        ProviderUsage(id: "codex", kind: .codex, displayName: "Codex", planType: "pro",
                      windows: [w(.fiveHour, 72, 300, 2.3), w(.weekly, 40, 10080, 96)],
                      tokens: TokenStats(totalTokens: 588_536_196),
                      status: .ok, lastUpdated: Date()),
        ProviderUsage(id: "claude:personal", kind: .claude, displayName: "Claude — Personal",
                      accountLabel: "you@example.com", planType: "Max",
                      windows: [w(.fiveHour, 2, 300, 4.6), w(.weekly, 23, 10080, 110),
                                w(.weekly, 9, 10080, 110, name: "7D FABLE")],
                      cost: mockCost, status: .ok, lastUpdated: Date()),
        ProviderUsage(id: "claude:work", kind: .claude, displayName: "Claude — Work",
                      accountLabel: "work@example.com", planType: "Team",
                      windows: [w(.fiveHour, 18, 300, 4.6), w(.weekly, 29, 10080, 130),
                                w(.weekly, 53, 10080, 130, name: "7D FABLE")],
                      cost: mockCost, status: .ok, lastUpdated: Date()),
        ProviderUsage(id: "gemini", kind: .gemini, displayName: "Gemini",
                      status: .notInstalled, detail: "Not detected — install gemini-cli"),
        ProviderUsage(id: "custom:openrouter", kind: .custom, displayName: "OpenRouter",
                      windows: [w(.other, 34, 1440, 20, name: "Daily")],
                      status: .ok, lastUpdated: Date()),
    ]
}

@MainActor
func generate() async {
    let outDir = CommandLine.arguments.dropFirst().first
        ?? FileManager.default.temporaryDirectory.path
    let dir = URL(fileURLWithPath: outDir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    func write(_ data: Data?, _ name: String) {
        guard let data else { print("  ! failed \(name)"); return }
        try? data.write(to: dir.appendingPathComponent(name))
        print("  ✓ \(dir.appendingPathComponent(name).path)")
    }

    let mock = mockProviders()
    write(png(PreviewPanel(title: "updated just now", providers: mock, kind: .claude)), "panel-mock.png")
    write(png(PreviewPanel(title: "updated just now", providers: mock, kind: .codex)), "panel-mock-codex.png")
    write(png(PreviewPanel(title: "updated just now", providers: mock, kind: .gemini)), "panel-mock-gemini.png")
    write(png(PreviewPanel(title: "custom provider", providers: mock, kind: .custom)), "panel-custom.png")
    write(png(CostSection(cost: mockCost, expanded: true)
        .padding(12).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))), "cost-expanded.png")
    write(png(CostSection(cost: mockCost, budget: 100, expanded: true)
        .padding(12).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))), "cost-budget.png")
    write(png(CostSection(cost: mockCost, budget: 100, expanded: true, expandTopProject: true)
        .padding(12).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))), "cost-drilldown.png")
    write(png(CostSection(cost: mockCost, masked: true, expanded: true)
        .padding(12).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))), "cost-masked.png")
    write(png(PreviewPanel(title: "downshift", providers: [downshiftCard()], kind: .claude)), "panel-downshift.png")
    write(png(PreviewPanel(title: "privacy · masked", providers: mock, kind: .claude, masked: true)), "panel-masked.png")
    write(png(SettingsPreview(page: .general)), "settings-general.png")
    write(png(SettingsPreview(page: .dataLocations)), "settings-data-locations.png")

    let chips = [
        LabelChip(code: "Cx", percent: 72, throttled: false),
        LabelChip(code: "Cl", percent: 53, throttled: false),
    ]
    write(png(MenuBarLabelView(chips: chips, textColor: .black).padding(4)
        .background(Color(white: 0.92)), scale: 3), "label-light.png")
    write(png(MenuBarLabelView(chips: chips, textColor: .white).padding(4)
        .background(Color(white: 0.15)), scale: 3), "label-dark.png")

    // Menu-bar meter icons (the CodexBar-style dual bars).
    let meters = [
        MenuBarMeterItem(code: "Cx", fiveHour: 72, weekly: 40),
        MenuBarMeterItem(code: "Cl", fiveHour: 18, weekly: 53),
    ]
    write(png(MenuBarMetersView(items: meters, textColor: .white).padding(5)
        .background(Color(white: 0.15)), scale: 4), "label-meters.png")

    print("done.")
}

await generate()
