import Foundation

/// A simple linear burn-rate projection for a usage window: compares how much
/// you've used against how far through the window you are, and extrapolates.
public struct WindowProjection: Sendable, Hashable {
    /// How far through the window we are, 0–100.
    public var elapsedPercent: Double
    /// Extrapolated usage at reset if the current rate holds (can exceed 100).
    public var projectedEndPercent: Double
    /// True when you're on track to hit 100% before the window resets.
    public var willExceed: Bool
    /// Seconds from now until you'd hit 100% (only when `willExceed`).
    public var secondsToLimit: TimeInterval?
}

/// Projects a window's trajectory. Returns nil when there isn't enough signal
/// (no reset time, zero usage, already maxed, or too early in the window).
public func windowProjection(_ window: UsageWindow, now: Date = Date()) -> WindowProjection? {
    guard let used = window.usedPercent, used > 0, used < 100,
          let reset = window.resetsAt, let minutes = window.windowMinutes, minutes > 0
    else { return nil }

    let total = Double(minutes) * 60
    let left = reset.timeIntervalSince(now)
    guard left > 0, left <= total + 60 else { return nil }

    let elapsed = total - left
    guard elapsed > 0 else { return nil }

    let e = min(1, elapsed / total)
    let projectedEnd = used / e
    // Time from now until cumulative usage reaches 100% at the current rate.
    let secondsToLimit = elapsed * (100 - used) / used
    // Only trust the projection once we're at least 10% through the window,
    // otherwise early bursts produce wild false alarms.
    let willExceed = e >= 0.10 && secondsToLimit < left

    return WindowProjection(
        elapsedPercent: e * 100,
        projectedEndPercent: projectedEnd,
        willExceed: willExceed,
        secondsToLimit: willExceed ? secondsToLimit : nil
    )
}
