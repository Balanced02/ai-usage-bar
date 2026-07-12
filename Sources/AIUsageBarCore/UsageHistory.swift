import Foundation

/// One recorded usage reading: a window's % at a point in time.
public struct UsageSample: Codable, Sendable {
    public var t: Double     // epoch seconds
    public var key: String   // "<providerId>|<window label>"
    public var pct: Double
}

/// A small on-disk timeseries of usage readings, powering sparklines and trends.
/// Appends at most one sample per key per interval, prunes to a rolling window,
/// and stores as JSONL in Application Support. Used from the main actor only.
public final class UsageHistory {
    private var samples: [UsageSample] = []
    private var lastByKey: [String: Double] = [:]
    private let fileURL: URL
    private let minInterval: TimeInterval
    private let maxAge: TimeInterval

    public init(directory: URL? = nil, minInterval: TimeInterval = 300, maxAge: TimeInterval = 30 * 24 * 3600) {
        self.minInterval = minInterval
        self.maxAge = maxAge
        let dir = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.jsonl")
        load()
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AIUsageBar")
    }

    public static func key(providerId: String, windowLabel: String) -> String {
        providerId + "|" + windowLabel
    }

    // MARK: Recording

    public func record(_ providers: [ProviderUsage], now: Date = Date()) {
        let t = now.timeIntervalSince1970
        var fresh: [UsageSample] = []
        for provider in providers {
            for window in provider.windows {
                guard let pct = window.usedPercent else { continue }
                let key = Self.key(providerId: provider.id, windowLabel: window.name ?? window.kind.shortLabel)
                if let last = lastByKey[key], t - last < minInterval { continue }
                let sample = UsageSample(t: t, key: key, pct: pct)
                samples.append(sample)
                fresh.append(sample)
                lastByKey[key] = t
            }
        }
        if !fresh.isEmpty { append(fresh) }
    }

    // MARK: Query

    /// Recent values for a key, oldest → newest, thinned to `maxPoints`.
    public func series(forKey key: String, since: Date? = nil, maxPoints: Int = 48) -> [Double] {
        let cutoff = since?.timeIntervalSince1970 ?? 0
        let values = samples.filter { $0.key == key && $0.t >= cutoff }.map(\.pct)
        guard values.count > maxPoints else { return values }
        let stride = Double(values.count) / Double(maxPoints)
        return (0..<maxPoints).map { values[min(values.count - 1, Int(Double($0) * stride))] }
    }

    // MARK: Persistence

    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        let cutoff = Date().timeIntervalSince1970 - maxAge
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let sample = try? decoder.decode(UsageSample.self, from: data),
                  sample.t >= cutoff else { continue }
            samples.append(sample)
            lastByKey[sample.key] = max(lastByKey[sample.key] ?? 0, sample.t)
        }
        // Rewrite the file if we dropped aged-out rows on load.
        if samples.count > 0 { rewrite() }
    }

    private func append(_ new: [UsageSample]) {
        let encoder = JSONEncoder()
        var text = ""
        for sample in new {
            if let data = try? encoder.encode(sample), let line = String(data: data, encoding: .utf8) {
                text += line + "\n"
            }
        }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    private func rewrite() {
        let encoder = JSONEncoder()
        let text = samples.compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        try? (text + "\n").data(using: .utf8)?.write(to: fileURL)
    }
}
