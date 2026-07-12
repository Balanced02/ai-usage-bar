import Foundation
import AIUsageBarCore

// A tiny CLI to validate the readers against real local data.
//   usageprobe codex    (default) — Codex only, no network/Keychain
//   usageprobe gemini              — Gemini detection
//   usageprobe claude              — Claude (reads Keychain + calls endpoint)
//   usageprobe all                 — everything

func fmt(_ p: ProviderUsage) -> String {
    var lines: [String] = []
    lines.append("● \(p.displayName)  [\(p.status.rawValue)]"
        + (p.planType.map { "  plan=\($0)" } ?? "")
        + (p.accountLabel.map { "  \($0)" } ?? ""))
    for w in p.windows {
        let pct = w.usedPercent.map { $0.percentString } ?? "—"
        let reset = w.resetsAt.map { "resets " + relative($0) } ?? ""
        lines.append("    \(w.displayLabel.padding(toLength: 16, withPad: " ", startingAt: 0)) \(pct.padding(toLength: 5, withPad: " ", startingAt: 0)) \(reset)")
    }
    if let c = p.credits, let b = c.balance { lines.append("    credits: \(b)") }
    if let t = p.tokens?.totalTokens { lines.append("    tokens: \(t)") }
    if p.isThrottled { lines.append("    ⚠︎ throttled") }
    if let d = p.detail { lines.append("    note: \(d)") }
    if let path = p.sourcePath { lines.append("    src: \(path)") }
    return lines.joined(separator: "\n")
}

func relative(_ date: Date) -> String {
    let secs = date.timeIntervalSinceNow
    if secs < 0 { return "now" }
    let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
    return h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
}

let mode = CommandLine.arguments.dropFirst().first ?? "codex"

switch mode {
case "codex":
    print(fmt(CodexReader().read()))
case "gemini":
    print(fmt(GeminiReader().read()))
case "claude":
    let profiles = UsageConfig.autoDetect().claudeProfiles
    let results = await ClaudeReader(profiles: profiles).read()
    print(results.map(fmt).joined(separator: "\n\n"))
case "profiles":
    for p in ClaudeProfileDiscovery.discover() {
        let a = ClaudeAccountLoader.load(p)
        print("• \(p.name.padding(toLength: 10, withPad: " ", startingAt: 0)) dir=\(p.configDir.path)  default=\(p.isDefault)  email=\(a?.emailAddress ?? "-")  plan=\(a?.planLabel ?? "-")")
    }
case "all":
    let service = UsageService(config: .autoDetect())
    let results = await service.refresh()
    print(results.map(fmt).joined(separator: "\n\n"))
default:
    print("usage: usageprobe [codex|claude|gemini|all]")
}
