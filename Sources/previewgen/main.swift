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

// A non-interactive panel mirroring MenuContentView for snapshots.
struct PreviewPanel: View {
    let title: String
    let providers: [ProviderUsage]
    let kind: ProviderKind
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
            KindDetailView(cards: providers.filter { $0.kind == kind })
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
                      status: .ok, lastUpdated: Date()),
        ProviderUsage(id: "claude:work", kind: .claude, displayName: "Claude — Work",
                      accountLabel: "work@example.com", planType: "Team",
                      windows: [w(.fiveHour, 18, 300, 4.6), w(.weekly, 29, 10080, 130),
                                w(.weekly, 53, 10080, 130, name: "7D FABLE")],
                      status: .ok, lastUpdated: Date()),
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
