import Foundation

/// Helpers for locating the `claude` binary and its version (for the required
/// `User-Agent: claude-code/<version>` header — a wrong/missing UA makes the
/// usage endpoint return persistent 429s).
public enum ClaudeCLI {
    private static let fallbackVersion = "2.1.205"

    private static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
    }()

    /// First existing `claude` path, if any.
    public static func binaryPath() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Cache the detected version so we don't spawn a process every poll.
    nonisolated(unsafe) private static var cachedVersion: String?

    /// `claude-code/<version>` for the User-Agent header. Detects the installed
    /// version once (via `claude --version`), else falls back to a sane default.
    public static func userAgent() -> String {
        "claude-code/\(version())"
    }

    public static func version() -> String {
        if let v = cachedVersion { return v }
        let detected = detectVersion() ?? fallbackVersion
        cachedVersion = detected
        return detected
    }

    private static func detectVersion() -> String? {
        guard let path = binaryPath() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        // Output looks like "2.1.205 (Claude Code)".
        let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init)
        if let token, token.first?.isNumber == true { return token }
        return nil
    }
}
