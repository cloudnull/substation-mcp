import Foundation
import Logging

/// Per-identity (per-token) sliding-window tool-call rate limiter (spec §12:
/// `policy.max_calls_per_minute`, default 120). A session that exceeds the
/// budget within a 60-second window is throttled: the next call returns a
/// tool-level error (isError) rather than a hard HTTP 429, so the MCP client
/// sees a structured, self-correctable message.
///
/// Keyed by token id, so two sessions presenting the same token share one
/// budget, and two different tokens are limited independently.
public actor ToolCallLimiter {
    private let limitPerMinute: Int
    private let clock: @Sendable () -> Date
    private var windows: [String: (start: Date, count: Int)] = [:]
    private let logger: Logger

    public init(limitPerMinute: Int, clock: @escaping @Sendable () -> Date = { Date() }, logger: Logger = Logger(label: "tool-limiter")) {
        self.limitPerMinute = limitPerMinute
        self.clock = clock
        self.logger = logger
    }

    /// Attempt to record a tool call for `tokenID`. Returns `true` when the
    /// call is allowed (and recorded), `false` when the budget for this window
    /// is exhausted (throttled).
    public func allow(tokenID: String) -> Bool {
        let now = clock()
        var entry = windows[tokenID]
        // Reset the window if it is older than 60s.
        if let e = entry, now.timeIntervalSince(e.start) > 60 {
            entry = nil
        }
        if entry == nil {
            entry = (start: now, count: 0)
        }
        if entry!.count >= limitPerMinute {
            windows[tokenID] = entry
            logger.warning("Tool-call rate limit exceeded", metadata: ["tokenID": "\(tokenID)"])
            return false
        }
        entry = (start: entry!.start, count: entry!.count + 1)
        windows[tokenID] = entry
        // Opportunistic sweep of fully-expired windows (cheap at this scale).
        for (key, e) in windows where now.timeIntervalSince(e.start) > 60 {
            windows[key] = nil
        }
        return true
    }
}
