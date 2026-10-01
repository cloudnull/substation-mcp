import Foundation
import Logging
import OpenStackClient

// MARK: - Login-minted token store (spec §6.1b)

/// A single stored, login-minted token bound to a session.
///
/// This is the **only** server-held credential-adjacent state (the one
/// stateful element the spec mandates for the URL-mode elicitation path).
/// Client-presented tokens are NOT stored here.
public struct StoredToken: Sendable {
    public let token: Token
    public let boundAt: Date

    public init(token: Token, boundAt: Date = Date()) {
        self.token = token
        self.boundAt = boundAt
    }
}

/// Actor-isolated store of login-minted tokens, keyed by session id.
///
/// Each entry's TTL is the token's `expires_at`; entries are evicted (and
/// zeroized) when idle past their expiry or when the session terminates.
/// The serve command wires the adapter's `terminated` callback to
/// ``zeroize(sessionId:)``.
public actor TokenStore {
    private var entries: [String: StoredToken] = [:]
    private let clock: () -> Date
    private let logger: Logger

    /// - Parameters:
    ///   - clock: Injectable clock for tests (defaults to `Date`).
    ///   - logger: Logger.
    public init(clock: @escaping @Sendable () -> Date = { Date() },
                logger: Logger = Logger(label: "token-store")) {
        self.clock = clock
        self.logger = logger
    }

    /// Bind a login-minted token to a session (replaces any prior binding).
    public func bind(sessionId: String, token: Token) {
        entries[sessionId] = StoredToken(token: token)
        logger.debug("Token bound to session", metadata: ["sessionID": "\(sessionId)"])
    }

    /// The token bound to a session, or `nil`.
    public func token(for sessionId: String) -> Token? {
        guard let entry = entries[sessionId] else { return nil }
        return entry.token.expiresAt > clock() ? entry.token : nil
    }

    /// Remove and zeroize a session's token. Idempotent.
    public func zeroize(sessionId: String) {
        if entries.removeValue(forKey: sessionId) != nil {
            logger.debug("Token zeroized for session", metadata: ["sessionID": "\(sessionId)"])
        }
    }

    /// Evict and zeroize all entries whose token has expired. Returns the
    /// session ids evicted.
    @discardableResult
    public func evictExpired(now: Date = Date()) -> [String] {
        let expired = entries.filter { $0.value.token.expiresAt <= now }.map(\.key)
        for id in expired {
            entries.removeValue(forKey: id)
        }
        if !expired.isEmpty {
            logger.debug("Evicted expired tokens", metadata: ["count": "\(expired.count)"])
        }
        return expired
    }

    /// The number of live (non-expired) bindings. For tests + metrics.
    public var count: Int {
        entries.count
    }
}
