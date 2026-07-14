import Foundation

/// Computes an equivalent-cost + token breakdown from a Claude profile's session
/// logs: totals for today / last 30 days, split by model and by repo, plus
/// cache-efficiency. Pure and Sendable so it can run off the main actor.
public enum ClaudeCostReader {
    public static func summary(for profile: ClaudeProfile,
                               now: Date = Date(),
                               maxFiles: Int = 400,
                               maxFileBytes: Int = 40_000_000,
                               cacheDirectory: URL? = nil) -> CostSummary? {
        let projects = profile.projectsDir
        guard FileManager.default.fileExists(atPath: projects.path) else { return nil }
        let cacheDir = cacheDirectory ?? UsageHistory.defaultDirectory()

        let cutoff30 = now.addingTimeInterval(-30 * 24 * 3600)
        let cutoff5h = now.addingTimeInterval(-5 * 3600)
        let cutoff7d = now.addingTimeInterval(-7 * 24 * 3600)
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startOfToday
        let files = ClaudeJSONLReader.recentJSONL(in: projects, modifiedAfter: cutoff30, limit: maxFiles)

        // Skip the (potentially large) full parse when nothing changed since the
        // last compute — the signature is just file paths + mtimes + sizes. The
        // version prefix invalidates the cache when the aggregation logic changes.
        let signature = "v5|" + fileSignature(files)
        let dayKey = Int(startOfToday.timeIntervalSince1970)
        if let cached = loadCache(dir: cacheDir, profileID: profile.id),
           cached.signature == signature, cached.day == dayKey {
            return cached.summary
        }

        let dailyBuckets = 14                    // trailing days kept for the per-project trend line
        var seen = Set<String>()
        var totalTokens = 0
        var todayUSD = 0.0, monthUSD = 0.0, monthToDateUSD = 0.0
        var byModel: [String: (tokens: Int, usd: Double)] = [:]
        var repoAgg: [String: (tokens: Int, usd: Double)] = [:]
        var repoModels: [String: [String: (tokens: Int, usd: Double)]] = [:]   // repo → model → totals
        var repoDaily: [String: [Double]] = [:]                                 // repo → per-day $ (oldest→newest)
        var rawInput = 0, cacheCreation = 0, cacheRead = 0
        var cacheSavedUSD = 0.0
        var last5hTokens = 0, last7dTokens = 0
        var last5hUSD = 0.0, last7dUSD = 0.0
        var repoNames: [String: String] = [:]   // cwd → project name (memoized string parse)

        for file in files {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileBytes { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                guard line.contains("\"usage\""), line.contains("\"assistant\""),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let ts = ISODate.parse(obj["timestamp"] as? String), ts >= cutoff30
                else { continue }

                let key = (msg["id"] as? String ?? "") + "|" + (obj["requestId"] as? String ?? "")
                if key != "|", !seen.insert(key).inserted { continue }

                func i(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
                let input = i("input_tokens"), output = i("output_tokens")
                let cc = i("cache_creation_input_tokens"), cr = i("cache_read_input_tokens")
                let model = msg["model"] as? String
                let usd = Pricing.cost(model: model, input: input, output: output, cacheCreation: cc, cacheRead: cr)
                let toks = input + output + cc + cr

                totalTokens += toks
                monthUSD += usd
                if ts >= startOfMonth { monthToDateUSD += usd }
                if ts >= startOfToday { todayUSD += usd }
                if ts >= cutoff5h { last5hTokens += toks; last5hUSD += usd }
                if ts >= cutoff7d { last7dTokens += toks; last7dUSD += usd }

                let mk = shortModel(model)
                let m = byModel[mk] ?? (0, 0); byModel[mk] = (m.tokens + toks, m.usd + usd)
                let cwd = obj["cwd"] as? String ?? ""
                let rk = repoNames[cwd] ?? { let n = repoName(cwd); repoNames[cwd] = n; return n }()
                var ra = repoAgg[rk] ?? (0, 0); ra.tokens += toks; ra.usd += usd; repoAgg[rk] = ra
                var rm = repoModels[rk] ?? [:]
                let cm = rm[mk] ?? (0, 0); rm[mk] = (cm.tokens + toks, cm.usd + usd); repoModels[rk] = rm
                let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: ts), to: startOfToday).day ?? 0
                if daysAgo >= 0, daysAgo < dailyBuckets {
                    var arr = repoDaily[rk] ?? [Double](repeating: 0, count: dailyBuckets)
                    arr[dailyBuckets - 1 - daysAgo] += usd    // index 0 = oldest, last = today
                    repoDaily[rk] = arr
                }

                rawInput += input; cacheCreation += cc; cacheRead += cr
                let p = Pricing.price(for: model)
                cacheSavedUSD += Double(cr) * (p.input - p.cacheRead) / 1_000_000
            }
        }

        guard totalTokens > 0 else { return nil }
        let denom = rawInput + cacheCreation + cacheRead
        let hit = denom > 0 ? Double(cacheRead) / Double(denom) : nil

        let summary = CostSummary(
            todayUSD: todayUSD,
            monthUSD: monthUSD,
            monthToDateUSD: monthToDateUSD,
            totalTokens: totalTokens,
            byModel: byModel.map { ModelCost(model: $0.key, tokens: $0.value.tokens, usd: $0.value.usd) }
                .sorted { $0.usd > $1.usd },
            byRepo: repoAgg.map { repo, v in
                RepoCost(repo: repo, tokens: v.tokens, usd: v.usd,
                         byModel: (repoModels[repo] ?? [:])
                             .map { ModelCost(model: $0.key, tokens: $0.value.tokens, usd: $0.value.usd) }
                             .sorted { $0.usd > $1.usd },
                         dailyUSD: repoDaily[repo] ?? [Double](repeating: 0, count: dailyBuckets))
            }.sorted { $0.usd > $1.usd },
            cacheHitRatio: hit,
            cacheSavedUSD: cacheSavedUSD,
            last5hTokens: last5hTokens, last5hUSD: last5hUSD,
            last7dTokens: last7dTokens, last7dUSD: last7dUSD
        )
        saveCache(dir: cacheDir, profileID: profile.id, signature: signature, day: dayKey, summary: summary)
        return summary
    }

    // MARK: Persistent cache

    private struct CachedCost: Codable {
        var signature: String
        var day: Int
        var summary: CostSummary
    }

    /// A cheap fingerprint of the input files (paths + mtimes + sizes) — changes
    /// whenever a session file is written, added, or ages out of the 30-day window.
    private static func fileSignature(_ files: [URL]) -> String {
        files.map { url -> String in
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let m = Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            let s = v?.fileSize ?? 0
            return "\(url.path):\(m):\(s)"
        }
        .sorted()
        .joined(separator: "|")
    }

    private static func cacheURL(dir: URL, profileID: String) -> URL {
        let safe = profileID.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return dir.appendingPathComponent("cost-cache-\(safe).json")
    }

    private static func loadCache(dir: URL, profileID: String) -> CachedCost? {
        guard let data = try? Data(contentsOf: cacheURL(dir: dir, profileID: profileID)) else { return nil }
        return try? JSONDecoder().decode(CachedCost.self, from: data)
    }

    private static func saveCache(dir: URL, profileID: String, signature: String, day: Int, summary: CostSummary) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(CachedCost(signature: signature, day: day, summary: summary)) {
            try? data.write(to: cacheURL(dir: dir, profileID: profileID))
        }
    }

    static func shortModel(_ model: String?) -> String {
        guard let m = model?.lowercased() else { return "Other" }
        for name in ["opus", "sonnet", "haiku", "fable"] where m.contains(name) {
            return name.capitalized
        }
        return "Other"
    }

    /// The project name for a working directory — collapsing git worktrees to the
    /// project they belong to, so cost aggregates by project, not by worktree.
    ///
    /// Purely string-based: it must NOT touch the filesystem. `cwd` points into the
    /// user's own project folders (e.g. `~/Documents`), and stat-ing anything there
    /// would trigger a macOS "access your Documents folder" prompt — which a menu-bar
    /// usage app has no business doing. The path markers below cover Claude Code's
    /// `.claude/worktrees/` layout (and similar) without opening a single file.
    static func repoName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        var p = cwd
        for marker in ["/.claude/worktrees/", "/.git/worktrees/", "/worktrees/", "--claude-worktrees"] {
            if let r = p.range(of: marker) {
                p = String(p[..<r.lowerBound])
                for container in ["/_private", "/.claude", "/.git"] where p.hasSuffix(container) {
                    p = String(p.dropLast(container.count))
                }
                break
            }
        }
        let name = (p as NSString).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }
}
