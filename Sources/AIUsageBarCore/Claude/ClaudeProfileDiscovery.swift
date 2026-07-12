import Foundation

/// Discovers Claude profiles from the user's shell config.
///
/// The default `claude` uses `~/.claude`; extra profiles are created with a
/// `CLAUDE_CONFIG_DIR=<dir>` alias/export (e.g.
/// `alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work command claude'`).
/// We parse those out of the rc files so the app tracks whatever profiles the
/// user actually has, named after the alias.
public enum ClaudeProfileDiscovery {
    private static let rcFiles = [
        ".zshrc", ".zprofile", ".zshenv",
        ".bashrc", ".bash_profile", ".profile",
        ".config/fish/config.fish",
    ]

    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ClaudeProfile] {
        let fm = FileManager.default
        var profiles: [ClaudeProfile] = []
        var seen = Set<String>()

        // Default profile (~/.claude), if present.
        let defaultDir = home.appendingPathComponent(".claude")
        if fm.fileExists(atPath: defaultDir.path) {
            profiles.append(.defaultProfile(name: "Personal"))
            seen.insert(defaultDir.standardizedFileURL.path)
        }

        // Alias/export-defined profiles from shell rc files.
        for rc in rcFiles {
            let url = home.appendingPathComponent(rc)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                guard line.contains("CLAUDE_CONFIG_DIR"), !isCommented(line) else { continue }
                guard let token = extractConfigDir(line) else { continue }
                let dir = resolve(token, home: home)
                let path = dir.standardizedFileURL.path
                guard fm.fileExists(atPath: dir.path), !seen.contains(path) else { continue }
                seen.insert(path)
                let name = aliasName(line).map(pretty) ?? nameFromDir(dir)
                profiles.append(.custom(name: name, dir: dir.path))
            }
        }

        if profiles.isEmpty { profiles = [.defaultProfile(name: "Personal")] }
        return profiles
    }

    // MARK: Parsing

    private static func isCommented(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("#")
    }

    /// Pulls the path token following `CLAUDE_CONFIG_DIR=`.
    static func extractConfigDir(_ line: String) -> String? {
        guard let r = line.range(of: "CLAUDE_CONFIG_DIR=") else { return nil }
        var rest = Substring(line[r.upperBound...])
        var quote: Character?
        if let f = rest.first, f == "\"" || f == "'" { quote = f; rest = rest.dropFirst() }
        var token = ""
        for ch in rest {
            if let q = quote { if ch == q { break } }
            else if ch == " " || ch == "\t" { break }
            token.append(ch)
        }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return token.isEmpty ? nil : token
    }

    /// Expands `~`, `$HOME`, and `${HOME}` in a config-dir token, using the given
    /// home (so `~` resolves to the intended user, not just the process's).
    static func resolve(_ token: String, home: URL) -> URL {
        var s = token
            .replacingOccurrences(of: "${HOME}", with: home.path)
            .replacingOccurrences(of: "$HOME", with: home.path)
        if s == "~" {
            s = home.path
        } else if s.hasPrefix("~/") {
            s = home.appendingPathComponent(String(s.dropFirst(2))).path
        } else if !s.hasPrefix("/") {
            // Relative path — anchor to home.
            s = home.appendingPathComponent(s).path
        }
        return URL(fileURLWithPath: s)
    }

    /// The alias name from a line like `alias claude-work='…'`.
    static func aliasName(_ line: String) -> String? {
        guard let r = line.range(of: "alias ") else { return nil }
        let after = line[r.upperBound...]
        guard let eq = after.firstIndex(of: "=") else { return nil }
        let name = after[..<eq].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func pretty(_ raw: String) -> String {
        var s = raw
        for prefix in ["claude-", "claude_", "cc-", "cc_"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)); break
        }
        if s.isEmpty || s == "claude" { return "Work" }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private static func nameFromDir(_ url: URL) -> String {
        var b = url.lastPathComponent
        for prefix in [".claude-", ".claude_", ".claude", "claude-", "."] where b.hasPrefix(prefix) {
            b = String(b.dropFirst(prefix.count)); break
        }
        if b.isEmpty { return "Work" }
        return b.prefix(1).uppercased() + b.dropFirst()
    }
}
