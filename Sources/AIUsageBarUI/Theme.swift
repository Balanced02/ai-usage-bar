import SwiftUI
import AIUsageBarCore

/// Colors, icons and formatting shared across the UI.
public enum Theme {
    // Threshold bands for "% of limit used".
    public static func color(forPercent p: Double?) -> Color {
        guard let p else { return .secondary }
        switch p {
        case ..<50: return .green
        case ..<75: return .yellow
        case ..<90: return .orange
        default: return .red
        }
    }

    /// Burn-rate vs the clock: compares % used against % of the window elapsed.
    /// "Behind" = using slower than time passes (good); "Ahead" = burning fast.
    public struct Pace: Sendable {
        public var text: String
        public var ahead: Bool
    }

    public static func pace(for window: UsageWindow, now: Date = Date()) -> Pace? {
        guard let used = window.usedPercent, let reset = window.resetsAt,
              let mins = window.windowMinutes, mins > 0 else { return nil }
        let total = Double(mins)
        let leftMin = reset.timeIntervalSince(now) / 60
        guard leftMin > 0, leftMin <= total + 1 else { return nil }
        let elapsed = max(0, min(100, (total - leftMin) / total * 100))
        let delta = Int((used - elapsed).rounded())
        if delta <= 0 { return Pace(text: "Behind (\(delta)%)", ahead: false) }
        return Pace(text: "Ahead (+\(delta)%)", ahead: true)
    }

    /// A short human countdown to a reset, e.g. "3h 12m", "2d 4h", "now".
    public static func resetString(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Masks an email for screen-sharing: "jane.doe@acme.com" → "j•••@•••".
    /// Hides the domain entirely so the employer isn't revealed.
    public static func maskEmail(_ s: String) -> String {
        guard let at = s.firstIndex(of: "@") else {
            return (s.first.map(String.init) ?? "") + "•••"
        }
        let head = s[s.startIndex..<at].first.map(String.init) ?? ""
        return head + "•••@•••"
    }

    /// Compact USD, e.g. "$254", "$12.3", "$0.04".
    public static func usd(_ v: Double) -> String {
        if v >= 100 { return "$\(Int(v.rounded()))" }
        if v >= 10 { return String(format: "$%.1f", v) }
        if v > 0 { return String(format: "$%.2f", v) }
        return "$0"
    }

    /// Per-model color for the mix bar / legend.
    public static func modelColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "opus": return Color(red: 0.55, green: 0.35, blue: 0.85)   // purple
        case "sonnet": return Color(red: 0.20, green: 0.47, blue: 0.96) // blue
        case "haiku": return Color(red: 0.10, green: 0.65, blue: 0.55)  // teal
        case "fable": return Color(red: 0.90, green: 0.49, blue: 0.13)  // orange
        default: return .gray
        }
    }

    /// Compact token count, e.g. "1.2M", "45k".
    public static func compactTokens(_ n: Int?) -> String? {
        guard let n, n > 0 else { return nil }
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fk", Double(n) / 1_000)
        default: return String(n)
        }
    }

    // Per-account colors for grouping (Personal orange, Work blue, …).
    public static let accountColors: [Color] = [
        Color(red: 0.90, green: 0.49, blue: 0.13),  // orange
        Color(red: 0.20, green: 0.47, blue: 0.96),  // blue
        Color(red: 0.55, green: 0.35, blue: 0.85),  // purple
        Color(red: 0.10, green: 0.65, blue: 0.55),  // teal
        Color(red: 0.85, green: 0.30, blue: 0.55),  // pink
    ]
    public static func accountColor(_ index: Int) -> Color {
        accountColors[((index % accountColors.count) + accountColors.count) % accountColors.count]
    }

    /// Meter color: the account color normally, escalating to orange/red near the
    /// limit so grouping stays clean but you still see when you're about to run out.
    public static func barColor(percent: Double?, accent: Color) -> Color {
        guard let p = percent else { return accent.opacity(0.5) }
        if p >= 90 { return .red }
        if p >= 75 { return .orange }
        return accent
    }

    /// The provider's web usage dashboard, opened on click-through.
    public static func dashboardURL(for kind: ProviderKind) -> URL? {
        switch kind {
        case .claude: return URL(string: "https://claude.ai/settings/usage")
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .gemini: return URL(string: "https://aistudio.google.com/usage")
        case .custom: return nil
        }
    }

    /// A burn-rate warning like "on pace to run out in 1h 20m", only when the
    /// window is actually projected to exceed before it resets.
    public static func burnRateText(for window: UsageWindow, now: Date = Date()) -> String? {
        guard let p = windowProjection(window, now: now), p.willExceed, let secs = p.secondsToLimit
        else { return nil }
        let mins = max(1, Int(secs / 60))
        let hm = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
        return "on pace to run out in \(hm)"
    }

    /// Display name for a provider kind (used as the tab label).
    public static func kindName(_ kind: ProviderKind) -> String {
        switch kind {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .custom: return "Custom"
        }
    }

    nonisolated(unsafe) private static let refillFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"      // "Sat 14:59"
        return f
    }()

    /// Reset text: a countdown for short windows ("resets in 4h 38m"), an absolute
    /// day+time for weekly+ windows ("refills Sat 14:59").
    public static func resetText(for window: UsageWindow, now: Date = Date()) -> String? {
        guard let reset = window.resetsAt else { return nil }
        if (window.windowMinutes ?? 0) <= 24 * 60 {
            return resetString(reset, now: now).map { "resets in \($0)" }
        }
        return "refills \(refillFormatter.string(from: reset))"
    }

    // Per-provider styling.
    public static func symbol(for kind: ProviderKind) -> String {
        switch kind {
        case .claude: return "a.circle.fill"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "sparkle"
        case .custom: return "puzzlepiece.extension.fill"
        }
    }

    public static func accent(for kind: ProviderKind) -> Color {
        switch kind {
        case .claude: return Color(red: 0.85, green: 0.45, blue: 0.24) // Claude clay
        case .codex: return Color(red: 0.10, green: 0.62, blue: 0.47)  // OpenAI green
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96) // Google blue
        case .custom: return Color(red: 0.55, green: 0.55, blue: 0.60) // neutral
        }
    }

    public static func shortCode(for kind: ProviderKind) -> String {
        switch kind {
        case .claude: return "Cl"
        case .codex: return "Cx"
        case .gemini: return "Gm"
        case .custom: return "Cu"
        }
    }

    public static func statusText(_ s: UsageStatus) -> String {
        switch s {
        case .ok: return "OK"
        case .noData: return "No data"
        case .notConfigured: return "Not signed in"
        case .notInstalled: return "Not installed"
        case .error: return "Error"
        }
    }

    public static func statusColor(_ s: UsageStatus) -> Color {
        switch s {
        case .ok: return .green
        case .noData, .notConfigured: return .secondary
        case .notInstalled: return Color.secondary.opacity(0.6)
        case .error: return .red
        }
    }
}
