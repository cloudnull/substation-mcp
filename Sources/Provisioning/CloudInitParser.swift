import Foundation

/// Parses cloud-init provisioning markers out of serial-console output.
///
/// The renderer embeds `OSMCP_PROVISION_BEGIN <sha>` as the first runcmd line
/// and `OSMCP_PROVISION_END <sha> ok=<0|1>` as the last. Reading the serial
/// console is the *only* in-band inspection channel these clouds expose, so
/// this is how we verify that provisioning actually landed — and the `sha`
/// correlation token lets us tie a transcript back to the exact spec that
/// produced it.
public enum CloudInitParser {
    /// The provisioning outcome, as observed from the console.
    public struct Result: Sendable, Equatable, Codable {
        public enum Status: String, Sendable, Equatable, Codable {
            /// Both BEGIN and END seen; `ok=1` at END.
            case succeeded
            /// END seen with `ok=0` — a step reported failure.
            case failed
            /// BEGIN seen but END not yet — still running (or console was
            /// truncated before the END line).
            case pending
            /// No provisioning markers found (server not provisioned through
            /// osmcp, console truncated, or a sha mismatch) — we cannot
            /// distinguish "not yet" from "never".
            case unknown
        }

        /// True once BEGIN has been observed.
        public var started: Bool
        /// True once END has been observed (regardless of ok).
        public var ended: Bool
        /// True once END has been observed with ok=1.
        public var finished: Bool
        /// The correlation token, if any marker carried one.
        public var sha: String?
        /// A best-effort reason string for logs/diagnostics.
        public var detail: String?

        public init(started: Bool, ended: Bool = false, finished: Bool = false, sha: String? = nil, detail: String? = nil) {
            self.started = started
            self.ended = ended
            self.finished = finished
            self.sha = sha
            self.detail = detail
        }

        public var status: Status {
            if finished { return .succeeded }
            if started, ended { return .failed }
            if started { return .pending }
            return .unknown
        }
    }

    /// Scan `console` (raw serial-console text, any length) for markers and
    /// produce a `Result`. The scan is linear and idempotent: re-parsing a
    /// longer console only ever moves the status forward
    /// (unknown → pending → succeeded/failed), never back.
    public static func parse(_ console: String, expectedSha: String? = nil) -> Result {
        var started = false
        var ended = false
        var finished = false
        var sha: String?
        var detail: String?

        for rawLine in console.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // BEGIN marker.
            if let t = matchMarker(line, token: "OSMCP_PROVISION_BEGIN") {
                started = true
                sha = t
                detail = "provisioning started"
                continue
            }

            // END marker: `OSMCP_PROVISION_END <sha> ok=<0|1>`.
            if line.contains("OSMCP_PROVISION_END") {
                let (t, ok) = matchEnd(line)
                if let t { sha = t }
                ended = true
                if ok {
                    finished = true
                    detail = "provisioning completed ok"
                } else {
                    detail = "provisioning reported a failing step (ok=0)"
                }
            }
        }

        // Correlation: if the caller knows which sha to expect and we saw a
        // *different* sha, treat it as unknown (this console is not ours).
        if let expectedSha, let sha, expectedSha != sha {
            return Result(started: false, sha: sha,
                          detail: "console sha \(sha) does not match expected \(expectedSha)")
        }

        return Result(started: started, ended: ended, finished: finished, sha: sha, detail: detail)
    }

    /// Extract the trailing token from a line containing `token <...>`.
    private static func matchMarker(_ line: String, token: String) -> String? {
        guard line.contains(token) else { return nil }
        let rest = line
        // token is the 2nd-from-last word; the sha is the last word.
        let parts = rest.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let sha = String(parts.last!)
        return sha
    }

    /// Extract (sha, ok) from an END marker line.
    private static func matchEnd(_ line: String) -> (String?, Bool) {
        guard line.contains("OSMCP_PROVISION_END") else { return (nil, false) }
        let parts = line.split(separator: " ")
        var sha: String?
        var ok = false
        for p in parts {
            let s = String(p)
            if s.hasPrefix("ok=") {
                ok = (s.dropFirst(3) == "1")
            } else if s != "OSMCP_PROVISION_END" {
                sha = s
            }
        }
        return (sha, ok)
    }
}
