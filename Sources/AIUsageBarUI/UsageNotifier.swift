import Foundation
import UserNotifications
import AIUsageBarCore

/// Posts native notifications when a window crosses 75% / 90% or is projected to
/// run out before it resets. Seeds silently on first run so launching while
/// already-high doesn't spam you — only genuine crossings notify.
@MainActor
public final class UsageNotifier {
    public var enabled = true

    private var notified = Set<String>()
    private var primed = false
    private var authorized = false

    // UNUserNotificationCenter requires a real bundle; guard for CLI/preview use.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    public init() {}

    public func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    public func evaluate(_ providers: [ProviderUsage]) {
        guard enabled, available else { return }
        for alert in collect(providers) where !notified.contains(alert.key) {
            notified.insert(alert.key)
            if primed { post(alert) }     // don't fire on the seeding pass
        }
        primed = true
    }

    private struct Alert { var key, title, body: String }

    private func collect(_ providers: [ProviderUsage]) -> [Alert] {
        var out: [Alert] = []
        for p in providers {
            for w in p.windows {
                guard let used = w.usedPercent, let reset = w.resetsAt else { continue }
                let base = "\(p.id)|\(w.displayLabel)|\(Int(reset.timeIntervalSince1970))"
                let where_ = "\(p.displayName) · \(w.displayLabel)"
                let reset_ = Theme.resetText(for: w).map { ", \($0)" } ?? ""
                if used >= 90 {
                    out.append(Alert(key: base + "|90", title: "\(where_) at \(Int(used))%",
                                     body: "You're near the limit\(reset_)."))
                } else if used >= 75 {
                    out.append(Alert(key: base + "|75", title: "\(where_) at \(Int(used))%",
                                     body: "Three-quarters used\(reset_)."))
                }
                if let proj = windowProjection(w), proj.willExceed, let secs = proj.secondsToLimit {
                    out.append(Alert(key: base + "|pace", title: "\(where_) burning fast",
                                     body: "On pace to run out in \(short(secs)) — before it resets."))
                }
            }
        }
        return out
    }

    private func post(_ alert: Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func short(_ secs: TimeInterval) -> String {
        let m = max(1, Int(secs / 60))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}
