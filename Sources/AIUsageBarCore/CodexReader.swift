import Foundation

/// Reads Codex usage from `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// Each rollout line is a JSON event. The interesting ones are:
///   { "timestamp": ISO8601, "type": "event_msg",
///     "payload": { "type": "token_count",
///                  "info": { total_token_usage, last_token_usage, model_context_window },
///                  "rate_limits": { plan_type, primary, secondary, ... } } }
///
/// The `rate_limits.primary`/`secondary` windows are identified by
/// `window_minutes` (300 → 5h, 10080 → weekly); either may be null. We take the
/// snapshot with the newest event `timestamp` across the most recently active
/// sessions — file order alone is not reliable.
public struct CodexReader: Sendable {
    public var codexHome: URL

    public init(codexHome: URL? = nil) {
        if let codexHome {
            self.codexHome = codexHome
        } else if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            self.codexHome = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            self.codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
        }
    }

    // MARK: Decodable shapes

    private struct Line: Decodable {
        let timestamp: String?
        let payload: Payload?
    }
    private struct Payload: Decodable {
        let type: String?
        let info: Info?
        let rate_limits: RateLimits?
    }
    private struct Info: Decodable {
        let total_token_usage: TokenUsage?
        let model_context_window: Int?
    }
    private struct TokenUsage: Decodable {
        let input_tokens: Int?
        let cached_input_tokens: Int?
        let output_tokens: Int?
        let reasoning_output_tokens: Int?
        let total_tokens: Int?
    }
    private struct RateLimits: Decodable {
        let plan_type: String?
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
        let rate_limit_reached_type: String?
    }
    private struct Window: Decodable {
        let used_percent: Double?
        let window_minutes: Int?
        let resets_at: Double?
    }
    private struct Credits: Decodable {
        let has_credits: Bool?
        let unlimited: Bool?
        // Balance can arrive as a JSON string ("0", "766.76") or, defensively, a number.
        let balance: FlexibleString?
    }

    private struct Snapshot {
        var timestamp: Date
        var rateLimits: RateLimits
        var info: Info?
    }

    // MARK: Public API

    public func read() -> ProviderUsage {
        let sessions = codexHome.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessions.path) else {
            return ProviderUsage(id: "codex", kind: .codex, displayName: "Codex",
                                 status: .notInstalled,
                                 detail: "No ~/.codex/sessions found",
                                 sourcePath: sessions.path)
        }

        let files = recentRolloutFiles(in: sessions, limit: 12)
        guard !files.isEmpty else {
            return ProviderUsage(id: "codex", kind: .codex, displayName: "Codex",
                                 status: .noData, detail: "No recent rollout files",
                                 sourcePath: sessions.path)
        }

        var best: Snapshot?
        var bestFile: URL?
        for file in files {
            guard let snap = latestSnapshot(in: file) else { continue }
            if best == nil || snap.timestamp > best!.timestamp {
                best = snap
                bestFile = file
            }
        }

        guard let snap = best else {
            return ProviderUsage(id: "codex", kind: .codex, displayName: "Codex",
                                 status: .noData, detail: "No rate-limit data in recent sessions",
                                 sourcePath: sessions.path)
        }

        var windows: [UsageWindow] = []
        for w in [snap.rateLimits.primary, snap.rateLimits.secondary].compactMap({ $0 }) {
            // Skip empty window objects.
            guard w.window_minutes != nil || w.used_percent != nil else { continue }
            windows.append(UsageWindow(
                kind: WindowKind(minutes: w.window_minutes),
                usedPercent: w.used_percent,
                windowMinutes: w.window_minutes,
                resetsAt: w.resets_at.map { Date(timeIntervalSince1970: $0) }
            ))
        }
        // Sort shortest window first for a stable display order.
        windows.sort { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }

        let tu = snap.info?.total_token_usage
        let tokens = TokenStats(
            totalTokens: tu?.total_tokens,
            inputTokens: tu?.input_tokens,
            outputTokens: tu?.output_tokens,
            cachedInputTokens: tu?.cached_input_tokens,
            reasoningTokens: tu?.reasoning_output_tokens,
            contextWindow: snap.info?.model_context_window
        )

        let credits = snap.rateLimits.credits.map {
            CreditInfo(hasCredits: $0.has_credits ?? false,
                       unlimited: $0.unlimited ?? false,
                       balance: $0.balance?.value)
        }

        return ProviderUsage(
            id: "codex",
            kind: .codex,
            displayName: "Codex",
            accountLabel: nil,
            planType: snap.rateLimits.plan_type,
            windows: windows,
            tokens: tokens,
            credits: credits,
            isThrottled: snap.rateLimits.rate_limit_reached_type != nil,
            status: windows.isEmpty ? .noData : .ok,
            detail: nil,
            lastUpdated: snap.timestamp,
            sourcePath: bestFile?.path
        )
    }

    // MARK: Helpers

    /// The most-recently-modified rollout files, newest first.
    private func recentRolloutFiles(in sessions: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [(URL, Date)] = []
        for case let url as URL in en {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            found.append((url, mod))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    private func parseDate(_ s: String?) -> Date? {
        ISODate.parse(s)
    }

    /// Scans the tail of one rollout file for the last token_count event that
    /// carries rate_limits, and returns its snapshot.
    private func latestSnapshot(in file: URL) -> Snapshot? {
        let lines = TailReader.lastLines(of: file)
        let decoder = JSONDecoder()
        for raw in lines.reversed() {
            guard raw.contains("token_count"), raw.contains("rate_limits"),
                  let data = raw.data(using: .utf8),
                  let line = try? decoder.decode(Line.self, from: data),
                  line.payload?.type == "token_count",
                  let rl = line.payload?.rate_limits,
                  rl.primary != nil || rl.secondary != nil,
                  let ts = parseDate(line.timestamp)
            else { continue }
            return Snapshot(timestamp: ts, rateLimits: rl, info: line.payload?.info)
        }
        return nil
    }
}
