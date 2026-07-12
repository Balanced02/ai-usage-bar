import SwiftUI
import AIUsageBarCore

/// A row of text tabs, one per provider kind (Claude · Codex · Gemini).
public struct KindTabBar: View {
    public let kinds: [ProviderKind]
    public let worst: (ProviderKind) -> Double?
    @Binding public var selection: ProviderKind?

    public init(kinds: [ProviderKind], worst: @escaping (ProviderKind) -> Double?, selection: Binding<ProviderKind?>) {
        self.kinds = kinds
        self.worst = worst
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(kinds, id: \.self) { kind in
                let isSelected = kind == selection
                Button {
                    selection = kind
                } label: {
                    HStack(spacing: 4) {
                        Text(Theme.kindName(kind))
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        // Subtle warning dot only when this kind is near a limit.
                        if let p = worst(kind), p >= 75 {
                            Circle().fill(Theme.color(forPercent: p)).frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
