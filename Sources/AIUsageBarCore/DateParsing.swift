import Foundation

/// Tolerant ISO-8601 parsing. Claude's `resets_at` looks like
/// `2026-04-17T00:59:59.951713+00:00` (microseconds + offset); Codex uses
/// `2026-07-12T21:01:02.125Z` (milliseconds). Handle both, with/without fraction.
public enum ISODate {
    // Configured once, never mutated; concurrent `date(from:)` reads are safe on
    // the underlying CFDateFormatter.
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = withFraction.date(from: s) { return d }
        if let d = plain.date(from: s) { return d }
        // ISO8601DateFormatter only accepts millisecond fractions; Claude emits
        // microseconds. Truncate the fractional part to 3 digits and retry.
        if let truncated = truncateFraction(s, toDigits: 3),
           let d = withFraction.date(from: truncated) { return d }
        // Last resort: drop the fractional part entirely.
        if let noFraction = truncateFraction(s, toDigits: 0),
           let d = plain.date(from: noFraction) { return d }
        return nil
    }

    /// Rewrites the `.ffffff` fraction in an ISO string to `digits` places
    /// (0 removes it). Preserves the trailing timezone (`Z` or `±HH:MM`).
    private static func truncateFraction(_ s: String, toDigits digits: Int) -> String? {
        guard let dot = s.firstIndex(of: ".") else { return digits == 0 ? s : nil }
        // Find where the fractional digits end (first non-digit after the dot).
        var end = s.index(after: dot)
        while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
        let head = String(s[s.startIndex..<dot])
        let tz = String(s[end..<s.endIndex])
        if digits == 0 { return head + tz }
        let frac = s[s.index(after: dot)..<end]
        let padded = frac.count >= digits
            ? String(frac.prefix(digits))
            : frac + String(repeating: "0", count: digits - frac.count)
        return head + "." + padded + tz
    }
}
