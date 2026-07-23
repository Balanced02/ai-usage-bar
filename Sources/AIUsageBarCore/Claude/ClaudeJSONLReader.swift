import Foundation

/// Rough token activity summed from a profile's session logs. This is an
/// ACTIVITY indicator, not a % of the (opaque, cost-weighted) subscription cap —
/// Anthropic publishes no token quota, so we never render this as a limit %.
public struct ClaudeTokenActivity: Sendable, Hashable {
    public var fiveHourTokens: Int
    public var sevenDayTokens: Int
    public var lastActivity: Date?
}

/// Sums `message.usage` tokens over trailing 5h / 7d wall-clock windows from
/// `<configDir>/projects/**/*.jsonl`, deduped by message id + request id.
public enum ClaudeJSONLReader {
    /// Local activity from a Claude **config dir** (reads its `projects/`).
    public static func activity(configDir: URL, now: Date = Date(),
                                maxFiles: Int = 40) -> ClaudeTokenActivity? {
        activity(for: ClaudeProfile(name: configDir.lastPathComponent, configDir: configDir, isDefault: false),
                 now: now, maxFiles: maxFiles)
    }

    public static func activity(for profile: ClaudeProfile,
                                now: Date = Date(),
                                maxFiles: Int = 40) -> ClaudeTokenActivity? {
        let projects = profile.projectsDir
        guard FileManager.default.fileExists(atPath: projects.path) else { return nil }

        let cutoff7d = now.addingTimeInterval(-7 * 24 * 3600)
        let cutoff5h = now.addingTimeInterval(-5 * 3600)

        let files = recentJSONL(in: projects, modifiedAfter: cutoff7d, limit: maxFiles)
        guard !files.isEmpty else { return nil }

        var seen = Set<String>()
        var fiveH = 0, sevenD = 0
        var last: Date?

        for file in files {
            // Recent messages sit near the end; a generous tail keeps a full
            // 7-day window without reading tens of MB of old turns.
            for raw in TailReader.lastLines(of: file, maxBytes: 4_194_304) {
                guard raw.contains("\"usage\""), raw.contains("\"assistant\""),
                      let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any]
                else { continue }

                guard let ts = ISODate.parse(obj["timestamp"] as? String), ts >= cutoff7d
                else { continue }

                // Dedupe forked/replayed sessions.
                let key = (msg["id"] as? String ?? "") + "|" + (obj["requestId"] as? String ?? "")
                if key != "|", !seen.insert(key).inserted { continue }

                func i(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
                let tokens = i("input_tokens") + i("output_tokens") + i("cache_creation_input_tokens")

                sevenD += tokens
                if ts >= cutoff5h { fiveH += tokens }
                if last == nil || ts > last! { last = ts }
            }
        }

        guard sevenD > 0 else { return nil }
        return ClaudeTokenActivity(fiveHourTokens: fiveH, sevenDayTokens: sevenD, lastActivity: last)
    }

    static func recentJSONL(in dir: URL, modifiedAfter: Date, limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if mod >= modifiedAfter { found.append((url, mod)) }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }
}
