import SwiftUI
import AppKit
import AIUsageBarCore
import AIUsageBarUI

// Renders the dropdown + menu-bar label to PNGs for design review.
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
        let kinds = [ProviderKind.claude, .codex, .gemini].filter { k in providers.contains { $0.kind == k } }
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

let mockCost = CostSummary(
    todayUSD: 3.42, monthUSD: 128.5, monthToDateUSD: 84.0, totalTokens: 22_700_000,
    byModel: [ModelCost(model: "Opus", tokens: 14_000_000, usd: 92),
              ModelCost(model: "Sonnet", tokens: 7_000_000, usd: 30.5),
              ModelCost(model: "Haiku", tokens: 1_700_000, usd: 6)],
    byRepo: [RepoCost(repo: "api-server", tokens: 12_000_000, usd: 78),
             RepoCost(repo: "web-app", tokens: 6_000_000, usd: 32),
             RepoCost(repo: "infra", tokens: 4_700_000, usd: 18.5)],
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
    write(png(CostSection(cost: mockCost, expanded: true)
        .padding(12).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))), "cost-expanded.png")
    write(png(CostSection(cost: mockCost, budget: 100, expanded: true)
        .padding(12).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))), "cost-budget.png")
    write(png(CostSection(cost: mockCost, masked: true, expanded: true)
        .padding(12).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))), "cost-masked.png")
    write(png(PreviewPanel(title: "downshift", providers: [downshiftCard()], kind: .claude)), "panel-downshift.png")
    write(png(PreviewPanel(title: "privacy · masked", providers: mock, kind: .claude, masked: true)), "panel-masked.png")

    var cfg = UsageConfig.autoDetect()
    cfg.allowKeychain = false
    let real = await UsageService(config: cfg).refresh()
    write(png(PreviewPanel(title: "live", providers: real, kind: .codex)), "panel-live.png")

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
