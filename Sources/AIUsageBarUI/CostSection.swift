import SwiftUI
import AIUsageBarCore

/// The cost/analytics block for a Claude account: a headline "$ today · $ 30d ·
/// tokens" that expands to model-mix, per-repo breakdown, and cache-efficiency.
public struct CostSection: View {
    let cost: CostSummary
    let budget: Double
    let masked: Bool
    @State private var expanded: Bool

    public init(cost: CostSummary, budget: Double = 0, masked: Bool = false, expanded: Bool = false) {
        self.cost = cost
        self.budget = budget
        self.masked = masked
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
                forecast
            }
        }
    }

    // MARK: Forecast / budget

    private var projectedMonthEnd: Double {
        let cal = Calendar.current
        let now = Date()
        let day = cal.component(.day, from: now)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        guard day > 0 else { return cost.monthToDateUSD }
        return cost.monthToDateUSD / Double(day) * Double(daysInMonth)
    }

    @ViewBuilder private var forecast: some View {
        let projected = projectedMonthEnd
        let over = budget > 0 && projected > budget
        VStack(alignment: .leading, spacing: 4) {
            if budget > 0 {
                HStack {
                    Text("Budget").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(Theme.usd(cost.monthToDateUSD)) / \(Theme.usd(budget))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                MeterBar(percent: min(100, cost.monthToDateUSD / budget * 100), height: 6,
                         color: over ? .red : .green)
            }
            Text("Projected \(Theme.usd(projected)) by month-end" + (over ? " · over budget" : ""))
                .font(.caption2)
                .foregroundStyle(over ? .orange : .secondary)
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
            ForEach(Array(cost.byRepo.prefix(4).enumerated()), id: \.element.repo) { idx, r in
                HStack(spacing: 8) {
                    Text(masked ? "Project \(idx + 1)" : r.repo)
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
