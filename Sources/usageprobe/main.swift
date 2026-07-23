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
    // The CLI can't do OAuth (its code signature differs from the app's, so it can't
    // read the app's Keychain token), so it shows local cost per discovered config
    // dir rather than live limits. Live 5H/7D % needs the app's Add-account sign-in.
    for p in ClaudeProfileDiscovery.discover() {
        let cost = ClaudeCostReader.summary(configDir: p.configDir)
        let usd = cost.map { "$" + String(format: "%.2f", $0.monthUSD) } ?? "-"
        print("• \(p.name)  dir=\(p.configDir.path)  30d=\(usd)  tokens=\(cost?.totalTokens ?? 0)")
    }
    print("(live 5H/7D % requires the app's OAuth sign-in)")
case "profiles":
    for p in ClaudeProfileDiscovery.discover() {
        let a = ClaudeAccountLoader.load(p)
        print("• \(p.name.padding(toLength: 10, withPad: " ", startingAt: 0)) dir=\(p.configDir.path)  default=\(p.isDefault)  email=\(a?.emailAddress ?? "-")  plan=\(a?.planLabel ?? "-")")
    }
case "all":
    let service = UsageService(config: UsageConfig())
    let results = await service.refresh()
    print(results.map(fmt).joined(separator: "\n\n"))
case "statusline":
    // One compact line for a shell prompt / Claude Code statusLine.
    let results = await UsageService(config: UsageConfig()).refresh()
    var parts: [String] = []
    for kind in [ProviderKind.codex, .claude, .gemini] {
        let pct = results.filter { $0.kind == kind }.compactMap { $0.maxUsedPercent }.max()
        guard let p = pct else { continue }
        let code = kind == .codex ? "Cx" : (kind == .claude ? "Cl" : "Gm")
        parts.append("\(code) \(Int(p.rounded()))%")
    }
    print(parts.isEmpty ? "AI usage: n/a" : parts.joined(separator: " · "))
default:
    print("usage: usageprobe [codex|claude|gemini|all]")
}
