import SwiftUI
import AIUsageBarCore

/// The compact menu-bar title: a threshold-colored dot for the worst provider
/// plus an adaptive-color list of per-provider chips ("Cx 2%  Cl 40%").
public struct MenuBarLabelView: View {
    public let chips: [LabelChip]
    public var textColor: Color

    public init(chips: [LabelChip], textColor: Color = .primary) {
        self.chips = chips
        self.textColor = textColor
    }

    private var worst: Double? { chips.compactMap(\.percent).max() }

    public var body: some View {
        HStack(spacing: 5) {
            if let worst {
                Circle()
                    .fill(Theme.color(forPercent: worst))
                    .frame(width: 7, height: 7)
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 12, weight: .medium))
            }

            if chips.isEmpty {
                Text("AI")
                    .font(.system(size: 11, weight: .semibold))
            } else {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        HStack(spacing: 2) {
                            Text(chip.code)
                                .font(.system(size: 11, weight: .semibold))
                                .opacity(0.75)
                            Text(chip.percent.map { "\(Int($0.rounded()))%" } ?? "—")
                                .font(.system(size: 11, weight: .bold))
                                .monospacedDigit()
                            if chip.throttled {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.red)
                            }
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
