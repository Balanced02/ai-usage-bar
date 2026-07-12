import SwiftUI
import AIUsageBarCore

/// The cost/analytics block for a Claude account: a headline "$ today · $ 30d ·
/// tokens" that expands to model-mix, per-repo breakdown, and cache-efficiency.
public struct CostSection: View {
    let cost: CostSummary
    @State private var expanded: Bool

    public init(cost: CostSummary, expanded: Bool = false) {
        self.cost = cost
        self._expanded = State(initialValue: expanded)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(Theme.usd(cost.todayUSD)) today").font(.caption).fontWeight(.semibold)
                    Text("· \(Theme.usd(cost.monthUSD)) 30d · \(Theme.compactTokens(cost.totalTokens) ?? "0") tok")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !cost.byModel.isEmpty { modelMix }
                if !cost.byRepo.isEmpty { repos }
                if let hit = cost.cacheHitRatio {
                    Text("Cache \(Int((hit * 100).rounded()))% hit · saved \(Theme.usd(cost.cacheSavedUSD))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Model mix

    private var modelTotal: Double { max(0.0001, cost.byModel.reduce(0) { $0 + $1.usd }) }

    private var modelMix: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(cost.byModel, id: \.model) { m in
                        Rectangle().fill(Theme.modelColor(m.model))
                            .frame(width: max(1, geo.size.width * m.usd / modelTotal))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())

            // Legend for the top few models.
            HStack(spacing: 10) {
                ForEach(cost.byModel.prefix(4), id: \.model) { m in
                    HStack(spacing: 3) {
                        Circle().fill(Theme.modelColor(m.model)).frame(width: 6, height: 6)
                        Text("\(m.model) \(Int((m.usd / modelTotal * 100).rounded()))%")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Repos

    private var repoMax: Double { max(0.0001, cost.byRepo.map(\.usd).max() ?? 0) }

    private var repos: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("By project").font(.caption2).foregroundStyle(.tertiary)
            ForEach(cost.byRepo.prefix(4), id: \.repo) { r in
                HStack(spacing: 8) {
                    Text(r.repo)
                        .font(.caption2).lineLimit(1).truncationMode(.middle)
                        .frame(width: 104, alignment: .leading)
                    MeterBar(percent: r.usd / repoMax * 100, height: 5, color: .secondary.opacity(0.55))
                    Text(Theme.usd(r.usd))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}
