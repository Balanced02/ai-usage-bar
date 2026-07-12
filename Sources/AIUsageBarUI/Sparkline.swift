import SwiftUI

/// A tiny line chart of a window's recent % (fixed 0–100 scale so the sawtooth
/// of resets stays readable).
public struct Sparkline: View {
    public let values: [Double]
    public var color: Color

    public init(values: [Double], color: Color) {
        self.values = values
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count >= 2 else { return }
                let stepX = geo.size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height * (1 - CGFloat(min(max(v, 0), 100)) / 100)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
    }
}
