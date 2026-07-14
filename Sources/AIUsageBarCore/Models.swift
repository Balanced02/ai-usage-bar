import Foundation

/// Which AI coding tool a usage reading belongs to.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case gemini
    case custom   // user-configured providers (grouped under one "Custom" tab)
}

/// The rolling window a usage percentage applies to. Identified by duration so we
/// never depend on the fragile primary/secondary ordering that Codex uses.
public enum WindowKind: String, Codable, Sendable {
    case fiveHour   // ~300 min
    case weekly     // ~10080 min
    case daily      // ~1440 min
    case monthly    // ~43200 min
    case other

    public init(minutes: Int?) {
        switch minutes {
        case .some(let m) where m <= 60 * 6 && m >= 60 * 4: self = .fiveHour
        case .some(let m) where m == 1440: self = .daily
        case .some(let m) where m >= 10000 && m <= 10200: self = .weekly
        case .some(let m) where m >= 40000 && m <= 46000: self = .monthly
        default: self = .other
        }
    }

    /// Short label for the menu bar / dropdown.
    public var shortLabel: String {
        switch self {
        case .fiveHour: return "5H"
        case .weekly: return "7D"
        case .daily: return "24H"
        case .monthly: return "30D"
        case .other: return "—"
        }
    }

    public var longLabel: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .weekly: return "Weekly"
        case .daily: return "Daily"
        case .monthly: return "Monthly"
        case .other: return "Window"
        }
    }
}

/// A single rate-limit window with how much of it is used and when it resets.
public struct UsageWindow: Codable, Sendable, Hashable, Identifiable {
    public var kind: WindowKind
    /// Optional label override (e.g. "Weekly · Opus"); falls back to `kind.longLabel`.
    public var name: String?
    /// 0–100. `nil` when the source can't tell us a percentage.
    public var usedPercent: Double?
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public var id: String {
        (name ?? kind.rawValue) + "-" + (windowMinutes.map(String.init) ?? "?")
    }

    public var displayLabel: String { name ?? kind.longLabel }

    public init(kind: WindowKind, usedPercent: Double?, windowMinutes: Int?,
                resetsAt: Date?, name: String? = nil) {
        self.kind = kind
        self.name = name
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

/// Pay-as-you-go / credit balance, when a source exposes it.
public struct CreditInfo: Codable, Sendable, Hashable {
    public var hasCredits: Bool
    public var unlimited: Bool
    /// Balance is a *string* in Codex's payload (can be "0" or "766.76…").
    public var balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

/// Cumulative token counters, when a source exposes them.
public struct TokenStats: Codable, Sendable, Hashable {
    public var totalTokens: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var reasoningTokens: Int?
    public var contextWindow: Int?

    public init(totalTokens: Int? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
                cachedInputTokens: Int? = nil, reasoningTokens: Int? = nil, contextWindow: Int? = nil) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
        self.contextWindow = contextWindow
    }
}

/// Equivalent-cost + token totals for one model or repo.
public struct ModelCost: Codable, Sendable, Hashable {
    public var model: String
    public var tokens: Int
    public var usd: Double
    public init(model: String, tokens: Int, usd: Double) {
        self.model = model; self.tokens = tokens; self.usd = usd
    }
}

public struct RepoCost: Codable, Sendable, Hashable {
    public var repo: String
    public var tokens: Int
    public var usd: Double
    public var byModel: [ModelCost]     // model mix *within* this project, $-desc
    public var dailyUSD: [Double]       // recent daily equivalent-$ (oldest→newest), for a trend line
    public init(repo: String, tokens: Int, usd: Double,
                byModel: [ModelCost] = [], dailyUSD: [Double] = []) {
        self.repo = repo; self.tokens = tokens; self.usd = usd
        self.byModel = byModel; self.dailyUSD = dailyUSD
    }
}

/// Local cost/token accounting derived from a profile's JSONL logs. On a flat
/// plan this is an *equivalent API cost*, useful for attribution and mix.
public struct CostSummary: Codable, Sendable, Hashable {
    public var todayUSD: Double
    public var monthUSD: Double            // rolling last 30 days
    public var monthToDateUSD: Double      // since the 1st of this calendar month
    public var totalTokens: Int
    public var byModel: [ModelCost]
    public var byRepo: [RepoCost]
    public var cacheHitRatio: Double?      // 0–1
    public var cacheSavedUSD: Double
    // Local rolling-window usage (ccusage-style — from log timestamps, no live API).
    public var last5hTokens: Int
    public var last5hUSD: Double
    public var last7dTokens: Int
    public var last7dUSD: Double

    public init(todayUSD: Double, monthUSD: Double, monthToDateUSD: Double, totalTokens: Int,
                byModel: [ModelCost], byRepo: [RepoCost],
                cacheHitRatio: Double?, cacheSavedUSD: Double,
                last5hTokens: Int = 0, last5hUSD: Double = 0,
                last7dTokens: Int = 0, last7dUSD: Double = 0) {
        self.todayUSD = todayUSD
        self.monthUSD = monthUSD
        self.monthToDateUSD = monthToDateUSD
        self.totalTokens = totalTokens
        self.byModel = byModel
        self.byRepo = byRepo
        self.cacheHitRatio = cacheHitRatio
        self.cacheSavedUSD = cacheSavedUSD
        self.last5hTokens = last5hTokens
        self.last5hUSD = last5hUSD
        self.last7dTokens = last7dTokens
        self.last7dUSD = last7dUSD
    }
}

/// Health of a provider reading.
public enum UsageStatus: String, Codable, Sendable {
    case ok             // fresh data with at least one window
    case noData         // configured but nothing to show yet
    case notConfigured  // no credentials / config found
    case notInstalled   // tool isn't installed on this machine
    case error          // something failed while reading
}

/// One card in the menu: a single account/profile of a single tool.
public struct ProviderUsage: Codable, Sendable, Hashable, Identifiable {
    /// Stable id, e.g. "codex", "claude:personal", "claude:work", "gemini".
    public var id: String
    public var kind: ProviderKind
    /// e.g. "Codex", "Claude — Personal".
    public var displayName: String
    /// Account email / org when known.
    public var accountLabel: String?
    /// Plan tier when known, e.g. "pro", "max".
    public var planType: String?
    public var windows: [UsageWindow]
    public var tokens: TokenStats?
    public var credits: CreditInfo?
    /// Cost/token accounting from local logs (Claude).
    public var cost: CostSummary?
    /// True when a limit is currently being hit (Codex `rate_limit_reached_type`).
    public var isThrottled: Bool
    public var status: UsageStatus
    /// Error text or an informational note.
    public var detail: String?
    public var lastUpdated: Date?
    public var sourcePath: String?

    public init(id: String, kind: ProviderKind, displayName: String, accountLabel: String? = nil,
                planType: String? = nil, windows: [UsageWindow] = [], tokens: TokenStats? = nil,
                credits: CreditInfo? = nil, cost: CostSummary? = nil, isThrottled: Bool = false,
                status: UsageStatus, detail: String? = nil, lastUpdated: Date? = nil, sourcePath: String? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.accountLabel = accountLabel
        self.planType = planType
        self.windows = windows
        self.tokens = tokens
        self.credits = credits
        self.cost = cost
        self.isThrottled = isThrottled
        self.status = status
        self.detail = detail
        self.lastUpdated = lastUpdated
        self.sourcePath = sourcePath
    }

    /// The window we care most about for the compact menu-bar title: the one
    /// closest to its limit; ties broken by the shorter window.
    public var headlineWindow: UsageWindow? {
        windows
            .filter { $0.usedPercent != nil }
            .max { a, b in
                let ap = a.usedPercent ?? -1, bp = b.usedPercent ?? -1
                if ap != bp { return ap < bp }
                return (a.windowMinutes ?? .max) > (b.windowMinutes ?? .max)
            }
    }

    /// Highest percentage across all windows (for threshold coloring).
    public var maxUsedPercent: Double? {
        windows.compactMap { $0.usedPercent }.max()
    }
}

public extension Double {
    /// Rounds a 0–100 percentage for compact display ("2%", "66%", "100%").
    var percentString: String {
        String(Int(self.rounded())) + "%"
    }
}
