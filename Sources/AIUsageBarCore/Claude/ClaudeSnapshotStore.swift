import Foundation

/// A per-account snapshot of the last live usage, persisted to disk so a relaunch can
/// show the previous 5H/7D % **instantly** (marked stale) instead of an empty
/// "Loading…" card while the ~seconds-slow usage endpoint responds.
public struct ClaudeUsageSnapshot: Codable, Sendable, Hashable {
    public var windows: [UsageWindow]
    public var planType: String?
    public var detail: String?
    public var updatedAt: Date

    public init(windows: [UsageWindow], planType: String?, detail: String?, updatedAt: Date) {
        self.windows = windows
        self.planType = planType
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

public enum ClaudeSnapshotStore {
    private static var fileURL: URL {
        UsageHistory.defaultDirectory().appendingPathComponent("claude-snapshots.json")
    }

    /// Snapshots keyed by card id (`claude:<accountKey>`).
    public static func load() -> [String: ClaudeUsageSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: ClaudeUsageSnapshot].self, from: data)
        else { return [:] }
        return dict
    }

    /// The snapshots worth keeping from a set of cards: only Claude cards that actually
    /// carry live windows (so a degraded/error refresh doesn't overwrite good data).
    public static func snapshots(from cards: [ProviderUsage], now: Date) -> [String: ClaudeUsageSnapshot] {
        var out: [String: ClaudeUsageSnapshot] = [:]
        for card in cards where card.kind == .claude && card.status == .ok && !card.windows.isEmpty {
            out[card.id] = ClaudeUsageSnapshot(windows: card.windows, planType: card.planType,
                                               detail: card.detail, updatedAt: card.lastUpdated ?? now)
        }
        return out
    }

    /// Persist live windows, merged over the existing file so an account absent from
    /// (or degraded in) this refresh keeps its last good snapshot.
    public static func persist(cards: [ProviderUsage], now: Date = Date()) {
        let fresh = snapshots(from: cards, now: now)
        guard !fresh.isEmpty else { return }   // never wipe good snapshots on an all-degraded refresh
        var all = load()
        for (k, v) in fresh { all[k] = v }
        try? FileManager.default.createDirectory(at: UsageHistory.defaultDirectory(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: fileURL) }
    }
}
