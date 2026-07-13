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
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startOfToday
        let files = ClaudeJSONLReader.recentJSONL(in: projects, modifiedAfter: cutoff30, limit: maxFiles)

        // Skip the (potentially large) full parse when nothing changed since the
        // last compute — the signature is just file paths + mtimes + sizes.
        let signature = fileSignature(files)
        let dayKey = Int(startOfToday.timeIntervalSince1970)
        if let cached = loadCache(dir: cacheDir, profileID: profile.id),
           cached.signature == signature, cached.day == dayKey {
            return cached.summary
        }

        var seen = Set<String>()
        var totalTokens = 0
        var todayUSD = 0.0, monthUSD = 0.0, monthToDateUSD = 0.0
        var byModel: [String: (tokens: Int, usd: Double)] = [:]
        var byRepo: [String: (tokens: Int, usd: Double)] = [:]
        var rawInput = 0, cacheCreation = 0, cacheRead = 0
        var cacheSavedUSD = 0.0

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

                let mk = shortModel(model)
                let m = byModel[mk] ?? (0, 0); byModel[mk] = (m.tokens + toks, m.usd + usd)
                let rk = repoName(obj["cwd"] as? String)
                let r = byRepo[rk] ?? (0, 0); byRepo[rk] = (r.tokens + toks, r.usd + usd)

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
            byRepo: byRepo.map { RepoCost(repo: $0.key, tokens: $0.value.tokens, usd: $0.value.usd) }
                .sorted { $0.usd > $1.usd },
            cacheHitRatio: hit,
            cacheSavedUSD: cacheSavedUSD
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

    /// Collapse worktrees and take the repo folder name from a cwd path.
    static func repoName(_ cwd: String?) -> String {
        guard var p = cwd, !p.isEmpty else { return "unknown" }
        if let r = p.range(of: "--claude-worktrees") { p = String(p[..<r.lowerBound]) }
        let name = (p as NSString).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }
}
