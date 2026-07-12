import SwiftUI
import AIUsageBarCore

/// Per-kind data for a menu-bar meter icon: a 5h bar over a weekly bar.
public struct MenuBarMeterItem: Identifiable, Sendable {
    public var id: String { code }
    public var code: String
    public var fiveHour: Double?
    public var weekly: Double?

    public init(code: String, fiveHour: Double?, weekly: Double?) {
        self.code = code
        self.fiveHour = fiveHour
        self.weekly = weekly
    }
}

/// CodexBar-style menu-bar icon: for each provider, a tiny dual-bar meter
/// (5h on top, weekly below), threshold-colored, with the provider code.
public struct MenuBarMetersView: View {
    public let items: [MenuBarMeterItem]
    public var textColor: Color

    public init(items: [MenuBarMeterItem], textColor: Color = .primary) {
        self.items = items
        self.textColor = textColor
    }

    public var body: some View {
        HStack(spacing: 7) {
            if items.isEmpty {
                Text("AI").font(.system(size: 11, weight: .semibold))
            } else {
                ForEach(items) { item in
                    HStack(spacing: 3) {
                        Text(item.code)
                            .font(.system(size: 9, weight: .semibold))
                            .opacity(0.8)
                        VStack(spacing: 2) {
                            MiniBar(percent: item.fiveHour)
                            MiniBar(percent: item.weekly)
                        }
                    }
                }
            }
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 3)
        .frame(height: 18)
        .fixedSize()
    }
}

/// Single worst-percentage number, colored by threshold.
public struct MenuBarNumberView: View {
    public let percent: Double?
    public init(percent: Double?) { self.percent = percent }
    public var body: some View {
        Text(percent.map { "\(Int($0.rounded()))%" } ?? "AI")
            .font(.system(size: 12, weight: .bold)).monospacedDigit()
            .foregroundStyle(Theme.color(forPercent: percent))
            .padding(.horizontal, 3).frame(height: 18).fixedSize()
    }
}

/// Single traffic-light dot, colored by worst threshold.
public struct MenuBarDotView: View {
    public let percent: Double?
    public init(percent: Double?) { self.percent = percent }
    public var body: some View {
        Circle().fill(Theme.color(forPercent: percent))
            .frame(width: 10, height: 10)
            .padding(.horizontal, 4).frame(height: 18).fixedSize()
    }
}

private struct MiniBar: View {
    let percent: Double?
    private let width: CGFloat = 18
    private let height: CGFloat = 3

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.35))
                .frame(width: width, height: height)
            if let p = percent {
                RoundedRectangle(cornerRadius: 1).fill(Theme.color(forPercent: p))
                    .frame(width: max(2, width * min(max(p, 0), 100) / 100), height: height)
            }
        }
        .frame(width: width, height: height)
    }
}
