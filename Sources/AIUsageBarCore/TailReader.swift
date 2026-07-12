import Foundation

/// Reads the tail of a (potentially very large) append-only file efficiently.
///
/// Codex rollout files can be tens of MB, and the current rate-limit snapshot is
/// always near the end. We seek to the last `maxBytes` and return complete lines,
/// so a poll costs a few small reads instead of gigabytes.
public enum TailReader {
    public static func lastLines(of url: URL, maxBytes: Int = 1_048_576) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let end: UInt64
        do { end = try handle.seekToEnd() } catch { return [] }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        do { try handle.seek(toOffset: start) } catch { return [] }

        let data: Data
        do { data = try handle.readToEnd() ?? Data() } catch { return [] }

        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // If we seeked into the middle of the file, the first "line" is a partial
        // fragment — drop it so we only decode complete JSON objects.
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines
    }
}
