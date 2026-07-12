import Foundation

/// Best-effort Gemini reader. gemini-cli persists no Codex-style quota file, so
/// this reports a detection state and (when installed) the static plan cap —
/// never a fabricated live %.
public struct GeminiReader: Sendable {
    public var geminiHome: URL
    public init(geminiHome: URL? = nil) {
        self.geminiHome = geminiHome
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    }

    private func binaryPresent() -> Bool {
        let fm = FileManager.default
        if ["\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/gemini",
            "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"].contains(where: { fm.isExecutableFile(atPath: $0) }) {
            return true
        }
        return false
    }

    public func read() -> ProviderUsage {
        let fm = FileManager.default
        let hasHome = fm.fileExists(atPath: geminiHome.path)
        let hasBin = binaryPresent()

        func card(status: UsageStatus, detail: String?, plan: String? = nil,
                  tokens: TokenStats? = nil) -> ProviderUsage {
            ProviderUsage(id: "gemini", kind: .gemini, displayName: "Gemini", planType: plan,
                          tokens: tokens, status: status, detail: detail,
                          lastUpdated: hasHome ? Date() : nil,
                          sourcePath: hasHome ? geminiHome.path : nil)
        }

        guard hasHome || hasBin else {
            return card(status: .notInstalled, detail: "Not detected — install gemini-cli")
        }

        // Determine auth tier from settings.json to show the static plan cap.
        let authType = readAuthType()
        let plan: String?
        let cap: String?
        switch authType {
        case let s? where s.contains("oauth"):
            plan = "Google login"; cap = "Cap: 60/min · 1,000/day"
        case let s? where s.contains("api"):
            plan = "API key"; cap = "Cap: ~250/day (Flash)"
        default:
            plan = nil; cap = "Plan cap unknown"
        }

        // Best-effort session activity from telemetry (off by default).
        if let act = telemetryActivity() {
            return card(status: .ok,
                        detail: "\(cap ?? "") · session ≈\(ClaudeReader.compact(act)) tok",
                        plan: plan, tokens: TokenStats(totalTokens: act))
        }
        return card(status: .noData,
                    detail: "\(cap ?? "") · enable gemini telemetry to track usage",
                    plan: plan)
    }

    private func readAuthType() -> String? {
        let url = geminiHome.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Auth type can live at top level or under "security"/"selectedAuthType".
        if let s = root["selectedAuthType"] as? String { return s }
        if let sec = root["security"] as? [String: Any],
           let auth = sec["auth"] as? [String: Any],
           let s = auth["selectedType"] as? String { return s }
        return nil
    }

    /// Sums token fields from telemetry.log if the user enabled file telemetry.
    private func telemetryActivity() -> Int? {
        let url = geminiHome.appendingPathComponent("telemetry.log")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var total = 0
        for raw in TailReader.lastLines(of: url, maxBytes: 2_097_152) {
            guard raw.contains("token"),
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for key in ["total_token_count", "input_token_count", "output_token_count"] {
                if let n = (obj[key] as? NSNumber)?.intValue { total += n }
            }
        }
        return total > 0 ? total : nil
    }
}
