import Foundation
import HummingbirdMCP
import Logging
import OpenStackClient

// MARK: - App token validator (Task 18)

/// Wraps the Task 5 `TokenValidator` to satisfy the adapter's `TokenValidating`
/// seam.
///
/// The adapter (Task 17) depends only on the OpenStack-free `TokenValidating`
/// protocol and `ValidatedIdentity`. This type bridges the two: it validates a
/// presented Keystone token id, and returns a `ValidatedIdentity` whose `raw`
/// payload carries the JSON-encoded `Token` so the `serverFactory` can rebuild
/// a `RequestIdentity` (catalog/regions) without a second Keystone
/// round-trip.
public struct AppTokenValidator: TokenValidating {
    private let validator: TokenValidator
    private let logger: Logger

    /// - Parameters:
    ///   - validator: The Task 5 `TokenValidator` (caches by token id, §7.1).
    ///   - logger: Logger.
    public init(
        validator: TokenValidator,
        logger: Logger = Logger(label: "app-token-validator")
    ) {
        self.validator = validator
        self.logger = logger
    }

    /// Validate a bearer token id. Throws (→ 401) when the token is invalid or
    /// expired. Audience/scope enforcement is handled separately by the
    /// adapter's `ScopeAuthorizer` + `WriteToolGate`.
    public func validate(tokenID: String) async throws -> ValidatedIdentity {
        do {
            let vt = try await validator.validate(tokenID)
            // Carry the encoded Token so the serverFactory can rebuild the
            // identity (catalog/regions) without re-validating.
            let raw = AnyTokenPayload(data: try JSONEncoder().encode(vt.token))
            return ValidatedIdentity(
                tokenID: vt.token.id,
                projectID: vt.token.project.id,
                scopes: vt.scopes.map { $0.rawValue },
                raw: raw
            )
        } catch {
            logger.debug("Token validation failed", metadata: [
                "tokenID": "\(tokenID)",
                "error": "\(error)",
            ])
            throw error
        }
    }
}

/// Rebuild a `ValidatedToken` from the `raw` payload an `AppTokenValidator`
/// attached. The payload is a `JSONEncoder`-encoded `Token`.
public func validatedToken(fromRaw payload: AnyTokenPayload?, scopes: [TokenScope]) throws -> ValidatedToken {
    guard let payload else {
        throw TokenValidationError(message: "No token payload attached")
    }
    let token = try JSONDecoder().decode(Token.self, from: payload.data)
    return ValidatedToken(token: token, scopes: scopes)
}
