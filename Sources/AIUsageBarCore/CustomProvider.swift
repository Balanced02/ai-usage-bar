import Foundation

/// A user-configured provider: point it at a folder of JSONL logs plus dot-paths
/// to the rate-limit fields, and it surfaces a usage window like the built-ins —
/// no code. Lets you add OpenRouter, LiteLLM, a proxy, or any future tool.
public struct CustomProviderConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String            // e.g. "OpenRouter"
    public var folder: URL             // scanned for *.jsonl; newest file, last matching line wins
    public var percentPath: String     // dot-path to used-percent 0–100, e.g. "rate_limit.used_percent"
    public var resetPath: String?      // dot-path to reset time (unix seconds, ms, or ISO-8601)
    public var windowLabel: String     // "Daily", "Monthly", …

    public init(id: UUID = UUID(), name: String, folder: URL,
                percentPath: String, resetPath: String? = nil, windowLabel: String = "Usage") {
        self.id = id
        self.name = name
        self.folder = folder.standardizedFileURL
        self.percentPath = percentPath
        self.resetPath = resetPath
        self.windowLabel = windowLabel
    }
}

public struct CustomProvider: Sendable {
    public let config: CustomProviderConfig
    public init(config: CustomProviderConfig) { self.config = config }

    public var id: String { "custom:\(config.id.uuidString)" }

    public func read() -> ProviderUsage {
        var card = ProviderUsage(id: id, kind: .custom, displayName: config.name,
                                 status: .noData, sourcePath: config.folder.path)

        guard FileManager.default.fileExists(atPath: config.folder.path) else {
            card.status = .notInstalled; card.detail = "Folder not found"; return card
        }
        guard let file = newestJSONL(in: config.folder) else {
            card.detail = "No .jsonl logs found"; return card
        }

        for raw in TailReader.lastLines(of: file).reversed() {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pct = Self.number(Self.value(at: config.percentPath, in: obj))
            else { continue }
            let reset = config.resetPath.flatMap { Self.date(Self.value(at: $0, in: obj)) }
            card.windows = [UsageWindow(kind: .other, usedPercent: pct, windowMinutes: nil,
                                        resetsAt: reset, name: config.windowLabel)]
            card.status = .ok
            card.lastUpdated = Date()
            return card
        }
        card.detail = "No '\(config.percentPath)' field in \(file.lastPathComponent)"
        return card
    }

    private func newestJSONL(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return nil }
        var best: (url: URL, date: Date)?
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || m > best!.date { best = (url, m) }
        }
        return best?.url
    }

    // MARK: Dot-path resolution

    /// Resolves "rate_limit.primary.used_percent" into nested JSON.
    static func value(at path: String, in obj: [String: Any]) -> Any? {
        var current: Any? = obj
        for key in path.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(key)]
        }
        return current
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func date(_ v: Any?) -> Date? {
        if let n = number(v) {
            return Date(timeIntervalSince1970: n > 1_000_000_000_000 ? n / 1000 : n)  // ms vs s
        }
        if let s = v as? String { return ISODate.parse(s) }
        return nil
    }
}
