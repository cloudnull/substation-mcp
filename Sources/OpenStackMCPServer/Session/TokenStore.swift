import Foundation
import Logging
import OpenStackClient

// MARK: - Login-minted token store (spec §6.1b) — NO-OP STUB (WS-A)

/// `TokenStore` used to hold login-minted tokens server-side, keyed by session
/// id, for the URL-mode elicitation path. As of Workstream A (Option 2) the
/// server stores **no** token: `/v1/login` mints a token and *displays* it on
/// the completion page, but never binds it to a session. The primary login path
/// is the client-side mint (app-cred or password → Keystone), and every
/// subsequent request re-validates its own bearer token per-request (spec §6.0).
///
/// The actor is retained as a no-op stub — its methods do nothing — so existing
/// callers and test sites that construct `TokenStore()` still compile. There is
/// no server-held credential-adjacent state anymore.
public actor TokenStore {
    public init(clock: @escaping @Sendable () -> Date = { Date() },
                logger: Logger = Logger(label: "token-store")) {}

    /// No-op: the server no longer binds minted tokens to sessions.
    public func bind(sessionId: String, token: Token) {}

    /// No-op: the server holds no token, so there is nothing to return.
    public func token(for sessionId: String) -> Token? { nil }

    /// No-op: the server holds no token, so there is nothing to zeroize.
    public func zeroize(sessionId: String) {}

    /// No-op: nothing to evict; always returns an empty list.
    @discardableResult
    public func evictExpired(now: Date = Date()) -> [String] { [] }

    /// Always 0: the server holds no live bindings.
    public var count: Int { 0 }
}
