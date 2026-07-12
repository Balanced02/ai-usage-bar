import SwiftUI
import AIUsageBarCore

/// A thin horizontal usage meter. Uses `color` if given, else threshold color.
/// An optional `tick` (0–100) draws a marker for "where you should be" (elapsed).
public struct MeterBar: View {
    public let percent: Double?
    public var height: CGFloat
    public var color: Color?
    public var tick: Double?

    public init(percent: Double?, height: CGFloat = 6, color: Color? = nil, tick: Double? = nil) {
        self.percent = percent
        self.height = height
        self.color = color
        self.tick = tick
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                if let p = percent {
                    Capsule()
                        .fill(color ?? Theme.color(forPercent: p))
                        .frame(width: max(height, geo.size.width * clamped(p) / 100))
                }
                if let t = tick {
                    // Vertical "pace" marker at the elapsed-time position.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 2, height: height + 4)
                        .offset(x: geo.size.width * clamped(t) / 100 - 1)
                }
            }
        }
        .frame(height: height)
    }

    private func clamped(_ v: Double) -> Double { min(max(v, 0), 100) }
}
