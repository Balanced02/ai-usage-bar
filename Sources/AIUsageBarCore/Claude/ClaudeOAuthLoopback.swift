import Foundation
import Darwin

/// A one-shot localhost HTTP listener that captures the OAuth redirect.
///
/// Binds `127.0.0.1` on an OS-assigned ephemeral port (loopback only — nothing is
/// reachable off-machine), hands back its `redirectURI` for the authorize URL, and
/// resolves once the browser hits `/callback?code=…&state=…`. This is the RFC 8252
/// native-app pattern and exactly what the Claude Code CLI does with this client id,
/// so the OAuth server's redirect allowlist accepts our dynamic-port loopback.
public final class ClaudeOAuthLoopback: @unchecked Sendable {
    public let port: UInt16
    public var redirectURI: String { "http://localhost:\(port)/callback" }

    private let fd: Int32
    private let lock = NSLock()
    private var cont: CheckedContinuation<(code: String, state: String?), Error>?
    private var closed = false

    public init() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw ClaudeOAuthError.transport("socket() failed") }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // loopback only
        addr.sin_port = 0                                 // ephemeral

        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(s); throw ClaudeOAuthError.transport("bind() failed") }
        guard Darwin.listen(s, 1) == 0 else { close(s); throw ClaudeOAuthError.transport("listen() failed") }

        var named = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &named) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        self.fd = s
        self.port = UInt16(bigEndian: named.sin_port)
    }

    /// Closes the socket. Also unblocks a pending `accept()` so `waitForCallback`
    /// can finish. Safe to call multiple times.
    public func stop() {
        lock.lock(); let alreadyClosed = closed; closed = true; lock.unlock()
        if !alreadyClosed { close(fd) }
    }

    /// Accepts connections until one is a GET to `/callback` carrying a `code`, then
    /// returns `(code, state)`. Ignores incidental requests (favicon). Times out —
    /// closing the socket — after `timeout` seconds; an `?error=` callback throws.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> (code: String, state: String?) {
        try await withCheckedThrowingContinuation { c in
            lock.lock(); cont = c; lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.stop()
                self.resume(.failure(ClaudeOAuthError.transport("timed out waiting for sign-in")))
            }
        }
    }

    // MARK: - Private

    private func resume(_ result: Result<(code: String, state: String?), Error>) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        guard let c else { return }
        switch result {
        case .success(let v): c.resume(returning: v)
        case .failure(let e): c.resume(throwing: e)
        }
    }

    private func acceptLoop() {
        while true {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &addr, &len)
            if client < 0 {
                resume(.failure(ClaudeOAuthError.cancelled))   // socket closed (stop/timeout)
                return
            }
            // Bound the read: a peer that connects but never sends (a speculative
            // browser preconnect, a port probe) must not wedge this serial loop and
            // starve the real redirect sitting in the backlog. On timeout recv
            // returns -1 → empty request → parse() .ignore → we close and continue.
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let request = Self.readRequest(client)
            switch Self.parse(request) {
            case .code(let code, let state):
                Self.respond(client, ok: true)
                close(client); stop()
                resume(.success((code, state)))
                return
            case .error(let err):
                Self.respond(client, ok: false)
                close(client); stop()
                resume(.failure(ClaudeOAuthError.http(400, "authorization failed: \(err)")))
                return
            case .ignore:
                Self.respond(client, ok: false)   // favicon etc. — keep waiting
                close(client)
            }
        }
    }

    private static func readRequest(_ client: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = recv(client, &buf, buf.count, 0)
        guard n > 0 else { return "" }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }

    enum Parsed: Equatable { case code(String, String?), error(String), ignore }

    /// Parses the request line `GET /callback?code=…&state=… HTTP/1.1`.
    static func parse(_ request: String) -> Parsed {
        guard let firstLine = request.split(separator: "\r\n", omittingEmptySubsequences: false).first,
              case let tokens = firstLine.split(separator: " "), tokens.count >= 2 else { return .ignore }
        let target = String(tokens[1])   // "/callback?code=..&state=.."
        guard let comps = URLComponents(string: "http://localhost\(target)"),
              comps.path == "/callback" else { return .ignore }
        let items = comps.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value { return .error(err) }
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return .code(code, items.first(where: { $0.name == "state" })?.value)
        }
        return .ignore
    }

    private static func respond(_ client: Int32, ok: Bool) {
        let html = ok ? successHTML : "<!doctype html><title>404</title>Not found."
        let status = ok ? "200 OK" : "404 Not Found"
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        let bytes = Array(response.utf8)
        _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
    }

    private static let successHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>AI Usage Bar</title>
    <style>
      html{color-scheme:light dark}
      body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;
           height:100vh;margin:0;background:#f5f4fb;color:#1f2230}
      @media(prefers-color-scheme:dark){body{background:#16161d;color:#e8e8ef}}
      .card{text-align:center;padding:40px 48px}
      .check{width:56px;height:56px;border-radius:50%;background:#8b7bf2;color:#fff;
             display:grid;place-items:center;margin:0 auto 18px;font-size:30px}
      h1{font-size:20px;margin:0 0 6px} p{opacity:.65;margin:0}
    </style></head><body><div class="card">
      <div class="check">✓</div>
      <h1>Signed in to Claude</h1>
      <p>You can close this tab and return to AI Usage Bar.</p>
    </div></body></html>
    """
}
