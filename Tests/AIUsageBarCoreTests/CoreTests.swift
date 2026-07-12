import XCTest
@testable import AIUsageBarCore

final class CoreTests: XCTestCase {

    func testWindowKindClassification() {
        XCTAssertEqual(WindowKind(minutes: 300), .fiveHour)
        XCTAssertEqual(WindowKind(minutes: 10080), .weekly)
        XCTAssertEqual(WindowKind(minutes: 1440), .daily)
        XCTAssertEqual(WindowKind(minutes: 43200), .monthly)
        XCTAssertEqual(WindowKind(minutes: nil), .other)
    }

    func testFlexibleStringDecoding() throws {
        struct Box: Decodable { let v: FlexibleString }
        func decode(_ json: String) throws -> String? {
            try JSONDecoder().decode(Box.self, from: Data(json.utf8)).v.value
        }
        XCTAssertEqual(try decode(#"{"v":"0"}"#), "0")
        XCTAssertEqual(try decode(#"{"v":"766.76"}"#), "766.76")
        XCTAssertEqual(try decode(#"{"v":5}"#), "5")
        XCTAssertEqual(try decode(#"{"v":12.5}"#), "12.5")
        XCTAssertEqual(try decode(#"{"v":null}"#), nil)
    }

    func testISODateParsing() {
        // Claude style: microseconds + offset.
        XCTAssertNotNil(ISODate.parse("2026-04-17T00:59:59.951713+00:00"))
        // Codex style: milliseconds + Z.
        XCTAssertNotNil(ISODate.parse("2026-07-12T21:01:02.125Z"))
        // No fraction.
        XCTAssertNotNil(ISODate.parse("2026-07-12T21:01:02Z"))
        XCTAssertNil(ISODate.parse(nil))
        XCTAssertNil(ISODate.parse(""))
    }

    func testCodexReaderPicksLatestAndClassifiesWindows() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("codex-test-\(UUID().uuidString)")
        let dayDir = tmp.appendingPathComponent("sessions/2026/07/12")
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)

        // Older event: 5h=20%, weekly=10%.
        // Newer event: 5h=80%, weekly=40%, with credits + plan.
        let older = tokenCountLine(ts: "2026-07-12T10:00:00.000Z", p5h: 20, wk: 10, credits: nil, plan: "pro")
        let newer = tokenCountLine(ts: "2026-07-12T20:00:00.000Z", p5h: 80, wk: 40, credits: "12.5", plan: "pro")
        let file = dayDir.appendingPathComponent("rollout-2026-07-12T10-00-00-abc.jsonl")
        try (older + "\n" + newer + "\n").write(to: file, atomically: true, encoding: .utf8)

        let usage = CodexReader(codexHome: tmp).read()
        XCTAssertEqual(usage.status, .ok)
        XCTAssertEqual(usage.planType, "pro")
        XCTAssertEqual(usage.credits?.balance, "12.5")

        let fiveH = usage.windows.first { $0.kind == .fiveHour }
        let weekly = usage.windows.first { $0.kind == .weekly }
        XCTAssertEqual(fiveH?.usedPercent, 80)          // newest snapshot won
        XCTAssertEqual(weekly?.usedPercent, 40)
        XCTAssertEqual(usage.headlineWindow?.kind, .fiveHour) // higher % is headline

        try? fm.removeItem(at: tmp)
    }

    func testCodexReaderHandlesNullSecondary() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("codex-test-\(UUID().uuidString)")
        let dayDir = tmp.appendingPathComponent("sessions/2026/07/12")
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)

        // Weekly-only variant: primary=weekly, secondary=null.
        let line = #"{"timestamp":"2026-07-12T20:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":123}},"rate_limits":{"plan_type":"pro","primary":{"used_percent":2.0,"window_minutes":10080,"resets_at":1784488331},"secondary":null,"rate_limit_reached_type":null}}}"#
        let file = dayDir.appendingPathComponent("rollout-2026-07-12T20-00-00-def.jsonl")
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)

        let usage = CodexReader(codexHome: tmp).read()
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows.first?.kind, .weekly)
        XCTAssertEqual(usage.tokens?.totalTokens, 123)

        try? fm.removeItem(at: tmp)
    }

    func testProfileDiscoveryParsing() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertEqual(
            ClaudeProfileDiscovery.extractConfigDir("alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work command claude'"),
            "~/.claude-work")
        XCTAssertEqual(
            ClaudeProfileDiscovery.extractConfigDir(#"export CLAUDE_CONFIG_DIR="$HOME/.claude-x""#),
            "$HOME/.claude-x")
        XCTAssertEqual(
            ClaudeProfileDiscovery.aliasName("alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'"),
            "claude-work")
        XCTAssertEqual(
            ClaudeProfileDiscovery.resolve("$HOME/.claude-work", home: home).path, "/Users/x/.claude-work")
        XCTAssertEqual(
            ClaudeProfileDiscovery.resolve("~/.claude-work", home: home).path, "/Users/x/.claude-work")
    }

    func testProfileDiscoveryFromRcFile() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".claude-work"), withIntermediateDirectories: true)
        try "alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work command claude'\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let profiles = ClaudeProfileDiscovery.discover(home: home)
        XCTAssertEqual(profiles.map(\.name), ["Personal", "Work"])
        XCTAssertTrue(profiles[0].isDefault)
        XCTAssertEqual(profiles[1].configDir.lastPathComponent, ".claude-work")

        try? fm.removeItem(at: home)
    }

    // Builds a token_count rollout line like the ones Codex writes.
    private func tokenCountLine(ts: String, p5h: Double, wk: Double, credits: String?, plan: String) -> String {
        let creditsJSON = credits.map { #"{"has_credits":true,"unlimited":false,"balance":"\#($0)"}"# } ?? "null"
        return """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150},"model_context_window":200000},"rate_limits":{"limit_id":"codex","plan_type":"\(plan)","primary":{"used_percent":\(p5h),"window_minutes":300,"resets_at":1784488331},"secondary":{"used_percent":\(wk),"window_minutes":10080,"resets_at":1784900000},"credits":\(creditsJSON),"rate_limit_reached_type":null}}}
        """
    }
}
