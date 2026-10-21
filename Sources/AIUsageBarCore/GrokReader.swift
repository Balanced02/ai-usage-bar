import Foundation

/// Reads Grok CLI session ledgers under `<grok home>/sessions/<cwd>/<id>/usage.json`,
/// and the plan limit from the latest billing check in `<grok home>/logs/unified.jsonl`.
///
/// The ledger is what `grok usage` prints: a session total plus one record per turn.
/// `costUsdTicks` is 10^10 ticks per USD, the server's own cost, so this does not
/// reprice tokens. The limit bar is the account's `creditUsagePercent` (0–100) and
/// the period reset (`currentPeriod.end`). Grok writes that when it refreshes billing
/// while the CLI is running. This reader does not call the network and never opens
/// `auth.json`.
public struct GrokReader: Sendable {
    public var grokHome: URL
    /// Ticks per USD in `usage.json` (`costUsdTicks / ticksPerUSD` = dollars).
    public static let ticksPerUSD: Double = 10_000_000_000

    public init(grokHome: URL? = nil) {
        self.grokHome = grokHome
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    public func read(now: Date = Date()) -> ProviderUsage {
        let sessions = grokHome.appendingPathComponent("sessions", isDirectory: true)
        let fm = FileManager.default
        let sessionsExist = fm.fileExists(atPath: sessions.path)
        let billing = Self.billingSnapshot(in: grokHome)

        func card(status: UsageStatus, detail: String?, cost: CostSummary? = nil,
                  tokens: TokenStats? = nil, updated: Date? = nil) -> ProviderUsage {
            let when = [updated, billing?.fetchedAt].compactMap { $0 }.max()
            return ProviderUsage(id: "grok", kind: .grok, displayName: "Grok",
                                 windows: billing?.windows ?? [], tokens: tokens, cost: cost,
                                 isThrottled: billing?.throttled ?? false,
                                 status: status, detail: detail, lastUpdated: when,
                                 sourcePath: sessionsExist ? sessions.path : (status == .notInstalled ? sessions.path : nil))
        }

        /// A plan limit is worth showing even before any session ledger exists.
        func billingOnly() -> ProviderUsage? {
            guard let billing, !billing.windows.isEmpty else { return nil }
            return card(status: .ok, detail: nil, updated: billing.fetchedAt)
        }

        guard sessionsExist else {
            if let only = billingOnly() { return only }
            if fm.fileExists(atPath: grokHome.path) || (isDefaultHome && binaryPresent()) {
                return card(status: .noData, detail: "No session usage yet")
            }
            let detail = isDefaultHome
                ? "Not detected — install the Grok CLI"
                : "No \(sessions.path) found"
            return card(status: .notInstalled, detail: detail)
        }

        let files = usageFiles(in: sessions, modifiedAfter: now.addingTimeInterval(-31 * 24 * 3600))
        guard !files.isEmpty else {
            if let only = billingOnly() { return only }
            return card(status: .noData, detail: "No session usage in the last 30 days")
        }
        guard let summary = Self.aggregate(files: files, now: now) else {
            if let only = billingOnly() { return only }
            return card(status: .error, detail: "Couldn't read session usage")
        }
        guard summary.cost.totalTokens > 0 || summary.cost.monthUSD > 0 else {
            if let only = billingOnly() { return only }
            return card(status: .noData, detail: "No session usage in the last 30 days",
                        updated: summary.updated)
        }
        let detail = "\(Self.compact(summary.cost.last5hTokens)) · 7d \(Self.money(summary.cost.last7dUSD))"
        return card(status: .ok, detail: detail, cost: summary.cost, tokens: summary.tokens,
                    updated: summary.updated)
    }

    // MARK: Discovery

    private var isDefaultHome: Bool {
        let standard = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok").standardizedFileURL.path
        return grokHome.standardizedFileURL.path == standard
    }

    /// True when a Grok CLI binary is on the machine. Used only when the default
    /// home does not exist yet, so a custom root that is missing stays "not found".
    private func binaryPresent() -> Bool {
        let fm = FileManager.default
        let candidates = [
            grokHome.appendingPathComponent("bin/grok").path,
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
        ]
        return candidates.contains { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: Plan limit

    /// Latest account limit the CLI logged. Nil when Grok has not checked billing,
    /// or the newest matching lines have no usable percentage.
    private struct BillingSnapshot {
        var windows: [UsageWindow]
        var fetchedAt: Date?
        var throttled: Bool
    }

    private static func billingSnapshot(in grokHome: URL) -> BillingSnapshot? {
        let file = grokHome.appendingPathComponent("logs/unified.jsonl")
        guard let tail = tail(file, maxBytes: 8 * 1024 * 1024) else { return nil }
        guard var text = String(data: tail.data, encoding: .utf8) else { return nil }
        if tail.truncated, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if let snapshot = parseBillingLine(String(line)) { return snapshot }
        }
        return nil
    }

    /// One `billing: fetched credits config` log line → limit windows.
    /// `creditUsagePercent` is already 0–100 (a logged `1.0` is 1%, not the whole plan).
    private static func parseBillingLine(_ line: String) -> BillingSnapshot? {
        guard line.contains("billing: fetched credits config"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["msg"] as? String) == "billing: fetched credits config" else { return nil }
        let ctx = obj["ctx"] as? [String: Any]
        guard let config = (ctx?["config"] as? [String: Any]) ?? (obj["config"] as? [String: Any]) else {
            return nil
        }

        let period = config["currentPeriod"] as? [String: Any]
        let start = (period?["start"] as? String) ?? (config["billingPeriodStart"] as? String)
        let end = (period?["end"] as? String) ?? (config["billingPeriodEnd"] as? String)
        let startDate = ISODate.parse(start)
        let endDate = ISODate.parse(end)
        let elapsedMinutes: Int? = {
            guard let startDate, let endDate, endDate > startDate else { return nil }
            return Int((endDate.timeIntervalSince(startDate) / 60).rounded())
        }()

        var windows: [UsageWindow] = []
        if let pct = jsonDouble(config["creditUsagePercent"]) {
            let typed = windowKind(periodType: period?["type"] as? String, minutes: elapsedMinutes)
            windows.append(UsageWindow(
                kind: typed.kind,
                usedPercent: pct,
                windowMinutes: elapsedMinutes ?? typed.fallbackMinutes,
                resetsAt: endDate,
                name: typed.name))
        }
        if let cap = jsonDouble(config["onDemandCap"]), cap > 0,
           let used = jsonDouble(config["onDemandUsed"]) {
            windows.append(UsageWindow(
                kind: .other, usedPercent: used / cap * 100, windowMinutes: nil,
                resetsAt: endDate, name: "On-demand"))
        }
        guard !windows.isEmpty else { return nil }
        let throttled = windows.contains { ($0.usedPercent ?? 0) >= 100 }
        return BillingSnapshot(windows: windows, fetchedAt: ISODate.parse(obj["ts"] as? String),
                               throttled: throttled)
    }

    /// Period type string wins (`USAGE_PERIOD_TYPE_WEEKLY` / `_MONTHLY`). Duration
    /// is only a fallback when the type is missing.
    private static func windowKind(periodType: String?, minutes: Int?) -> (kind: WindowKind, name: String?, fallbackMinutes: Int?) {
        let t = periodType?.lowercased() ?? ""
        if t.contains("week") { return (.weekly, nil, 7 * 24 * 60) }
        if t.contains("month") { return (.monthly, nil, 30 * 24 * 60) }
        if t.contains("day") { return (.daily, nil, 24 * 60) }
        if let minutes {
            let kind = WindowKind(minutes: minutes)
            return (kind, kind == .other ? "Limit" : nil, nil)
        }
        return (.other, "Limit", nil)
    }

    private static func jsonDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = value as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }

    private static func tail(_ url: URL, maxBytes: Int) -> (data: Data, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end == 0 { return nil }
        let truncated = end > UInt64(maxBytes)
        let start = truncated ? end - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
            return (data, truncated)
        } catch {
            return nil
        }
    }

    /// `usage.json` files touched inside the window. Two levels only
    /// (`sessions/<cwd>/<id>/usage.json`) — never the worktree or log trees.
    private func usageFiles(in sessions: URL, modifiedAfter cutoff: Date) -> [URL] {
        let fm = FileManager.default
        guard let cwds = try? fm.contentsOfDirectory(
            at: sessions, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var found: [(url: URL, modified: Date)] = []
        for cwd in cwds {
            guard (try? cwd.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let ids = try? fm.contentsOfDirectory(
                    at: cwd, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]) else { continue }
            for id in ids {
                guard (try? id.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let usage = id.appendingPathComponent("usage.json")
                let values = try? usage.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { continue }
                let modified = values?.contentModificationDate ?? .distantPast
                if modified < cutoff { continue }
                found.append((usage, modified))
            }
        }
        found.sort { $0.modified > $1.modified }
        return found.prefix(2_000).map(\.url)
    }

    // MARK: Aggregation

    private struct Summary {
        var cost: CostSummary
        var tokens: TokenStats
        var updated: Date?
    }

    /// Newest ledger per session id wins, so a resumed copy does not double-count
    /// when both copies share an id. Time windows come from turn `endedAt`. A file
    /// with no dated turns falls back to the session total at `updatedAt`.
    private static func aggregate(files: [URL], now: Date) -> Summary? {
        struct Kept {
            var updated: Date
            var ledger: Ledger
            var project: String
        }
        var best: [String: Kept] = [:]
        var parsed = 0
        let decoder = JSONDecoder()
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let ledger = try? decoder.decode(Ledger.self, from: data) else { continue }
            parsed += 1
            let updated = ISODate.parse(ledger.updatedAt) ?? .distantPast
            let id = ledger.sessionId ?? file.deletingLastPathComponent().lastPathComponent
            if let prev = best[id], prev.updated >= updated { continue }
            let project = projectName(sessionDirectoryName: file.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent)
            best[id] = Kept(updated: updated, ledger: ledger, project: project)
        }
        guard parsed > 0 else { return nil }

        let cutoff30 = now.addingTimeInterval(-30 * 24 * 3600)
        let cutoff5h = now.addingTimeInterval(-5 * 3600)
        let cutoff7d = now.addingTimeInterval(-7 * 24 * 3600)
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startOfToday
        let dailyBuckets = 14

        var totalTokens: Int64 = 0
        var input: Int64 = 0, output: Int64 = 0, cached: Int64 = 0, created: Int64 = 0, reasoning: Int64 = 0
        var todayUSD = 0.0, monthUSD = 0.0, monthToDateUSD = 0.0
        var last5hTokens: Int64 = 0, last7dTokens: Int64 = 0
        var last5hUSD = 0.0, last7dUSD = 0.0
        var byModel: [String: (tokens: Int64, usd: Double)] = [:]
        var repoAgg: [String: (tokens: Int64, usd: Double)] = [:]
        var repoModels: [String: [String: (tokens: Int64, usd: Double)]] = [:]
        var repoDaily: [String: [Double]] = [:]
        var latest: Date?

        for kept in best.values {
            if kept.updated > (latest ?? .distantPast) { latest = kept.updated }
            var events: [(Date, Bucket)] = []
            for turn in kept.ledger.turns {
                guard let at = ISODate.parse(turn.endedAt) else { continue }
                events.append((at, turn.usage))
            }
            if events.isEmpty, let session = kept.ledger.session,
               let at = ISODate.parse(kept.ledger.updatedAt) {
                events.append((at, session))
            }
            for (at, bucket) in events where at >= cutoff30 {
                let usd = Self.usd(bucket.costUsdTicks)
                let toks = bucket.totalTokens
                totalTokens += toks
                input += bucket.inputTokens
                output += bucket.outputTokens
                cached += bucket.cachedReadTokens
                created += bucket.cacheCreationTokens
                reasoning += bucket.reasoningTokens
                monthUSD += usd
                if at >= startOfMonth { monthToDateUSD += usd }
                if at >= startOfToday { todayUSD += usd }
                if at >= cutoff5h { last5hTokens += toks; last5hUSD += usd }
                if at >= cutoff7d { last7dTokens += toks; last7dUSD += usd }

                let split = modelSplit(bucket)
                for (name, part) in split {
                    let m = byModel[name] ?? (0, 0)
                    byModel[name] = (m.tokens + part.tokens, m.usd + part.usd)
                    var rm = repoModels[kept.project] ?? [:]
                    let cm = rm[name] ?? (0, 0)
                    rm[name] = (cm.tokens + part.tokens, cm.usd + part.usd)
                    repoModels[kept.project] = rm
                }
                var ra = repoAgg[kept.project] ?? (0, 0)
                ra.tokens += toks
                ra.usd += usd
                repoAgg[kept.project] = ra
                let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: at), to: startOfToday).day ?? 0
                if daysAgo >= 0, daysAgo < dailyBuckets {
                    var arr = repoDaily[kept.project] ?? [Double](repeating: 0, count: dailyBuckets)
                    arr[dailyBuckets - 1 - daysAgo] += usd
                    repoDaily[kept.project] = arr
                }
            }
        }

        let denom = input + created + cached
        let hit = denom > 0 ? Double(cached) / Double(denom) : nil
        let cost = CostSummary(
            todayUSD: todayUSD,
            monthUSD: monthUSD,
            monthToDateUSD: monthToDateUSD,
            totalTokens: Int(totalTokens),
            byModel: byModel.map { ModelCost(model: $0.key, tokens: Int($0.value.tokens), usd: $0.value.usd) }
                .sorted { $0.usd > $1.usd },
            byRepo: repoAgg.map { repo, v in
                RepoCost(repo: repo, tokens: Int(v.tokens), usd: v.usd,
                         byModel: (repoModels[repo] ?? [:])
                             .map { ModelCost(model: $0.key, tokens: Int($0.value.tokens), usd: $0.value.usd) }
                             .sorted { $0.usd > $1.usd },
                         dailyUSD: repoDaily[repo] ?? [Double](repeating: 0, count: dailyBuckets))
            }.sorted { $0.usd > $1.usd },
            cacheHitRatio: hit,
            cacheSavedUSD: 0,
            last5hTokens: Int(last5hTokens), last5hUSD: last5hUSD,
            last7dTokens: Int(last7dTokens), last7dUSD: last7dUSD
        )
        let tokens = TokenStats(totalTokens: Int(totalTokens), inputTokens: Int(input),
                                outputTokens: Int(output), cachedInputTokens: Int(cached),
                                reasoningTokens: Int(reasoning))
        return Summary(cost: cost, tokens: tokens, updated: latest)
    }

    /// Per-model token and dollar split for one turn. Falls back to a single
    /// "Grok" row when the ledger has no `modelUsage`.
    private static func modelSplit(_ bucket: Bucket) -> [(String, (tokens: Int64, usd: Double))] {
        let models = bucket.modelUsage.filter { !$0.key.isEmpty }
        if models.isEmpty {
            return [("Grok", (bucket.totalTokens, usd(bucket.costUsdTicks)))]
        }
        let tickSum = models.values.reduce(Int64(0)) { $0 + $1.costUsdTicks }
        let tokenSum = models.values.reduce(Int64(0)) { $0 + $1.totalTokens }
        return models.map { name, model in
            let partUSD: Double
            if tickSum > 0 {
                partUSD = usd(model.costUsdTicks)
            } else if tokenSum > 0 {
                partUSD = usd(bucket.costUsdTicks) * Double(model.totalTokens) / Double(tokenSum)
            } else {
                partUSD = 0
            }
            return (name, (model.totalTokens, partUSD))
        }
    }

    /// Last path component of the percent-encoded session cwd. The full path is
    /// never kept — it would put the account's home directory on the card.
    static func projectName(sessionDirectoryName: String) -> String {
        let decoded = sessionDirectoryName.removingPercentEncoding ?? sessionDirectoryName
        let name = URL(fileURLWithPath: decoded).lastPathComponent
        if name.isEmpty || name == "/" || name == "." { return "unknown" }
        return name
    }

    private static func usd(_ ticks: Int64) -> Double { Double(ticks) / ticksPerUSD }

    private static func money(_ v: Double) -> String {
        if v >= 100 { return "$\(Int(v.rounded()))" }
        if v >= 10 { return String(format: "$%.1f", v) }
        if v > 0 { return String(format: "$%.2f", v) }
        return "$0"
    }

    private static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM tok", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fk tok", Double(n) / 1_000)
        default: return "\(n) tok"
        }
    }
}

// MARK: - Ledger JSON

private struct FlexInt: Decodable {
    var value: Int64
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int64.self) { value = i; return }
        if let d = try? c.decode(Double.self) { value = Int64(d.rounded()); return }
        if let s = try? c.decode(String.self), let i = Int64(s) { value = i; return }
        value = 0
    }
}

private struct Ledger: Decodable {
    var sessionId: String?
    var updatedAt: String?
    var session: Bucket?
    var turns: [Turn]

    private enum CodingKeys: String, CodingKey {
        case sessionId, updatedAt, session, turns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        session = try c.decodeIfPresent(Bucket.self, forKey: .session)
        turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
    }
}

private struct Turn: Decodable {
    var endedAt: String?
    var usage: Bucket

    private enum CodingKeys: String, CodingKey { case endedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        usage = try Bucket(from: decoder)
    }
}

private struct Bucket: Decodable {
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cachedReadTokens: Int64 = 0
    var cacheCreationTokens: Int64 = 0
    var reasoningTokens: Int64 = 0
    var totalTokens: Int64 = 0
    var costUsdTicks: Int64 = 0
    var modelUsage: [String: Bucket] = [:]

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cachedReadTokens, cacheCreationTokens
        case reasoningTokens, totalTokens, costUsdTicks, modelUsage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = Self.int(c, .inputTokens)
        outputTokens = Self.int(c, .outputTokens)
        cachedReadTokens = Self.int(c, .cachedReadTokens)
        cacheCreationTokens = Self.int(c, .cacheCreationTokens)
        reasoningTokens = Self.int(c, .reasoningTokens)
        totalTokens = Self.int(c, .totalTokens)
        costUsdTicks = Self.int(c, .costUsdTicks)
        modelUsage = (try? c.decode([String: Bucket].self, forKey: .modelUsage)) ?? [:]
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64 {
        (try? c.decode(FlexInt.self, forKey: key))?.value ?? 0
    }
}
