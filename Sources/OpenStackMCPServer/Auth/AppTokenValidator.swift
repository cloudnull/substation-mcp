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
    ///
    /// Accepted forms:
    ///   - `<keystone-token-id>` — the classic bearer.
    ///   - `region:<REGION>:<keystone-token-id>` — URL-mode login result: the
    ///     token was minted against `<REGION>`'s Keystone; validate it there
    ///     and carry the region as the session's region preference.
    public func validate(tokenID: String) async throws -> ValidatedIdentity {
        let (region, rawTokenID) = Self.splitRegion(tokenID)
        do {
            let vt = try await validator.validate(rawTokenID, region: region)
            // Carry the encoded Token so the serverFactory can rebuild the
            // identity (catalog/regions) without re-validating.
            let raw = AnyTokenPayload(data: try JSONEncoder().encode(vt.token))
            return ValidatedIdentity(
                tokenID: vt.token.id,
                projectID: vt.token.project.id,
                scopes: vt.scopes.map { $0.rawValue },
                region: region,
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

    /// Parse the optional `region:<REGION>:` bearer prefix. Returns
    /// `(nil, tokenID)` for a plain token.
    public static func splitRegion(_ tokenID: String) -> (region: String?, id: String) {
        guard tokenID.hasPrefix("region:") else { return (nil, tokenID) }
        let parts = tokenID.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty else { return (nil, tokenID) }
        return (String(parts[1]), String(parts[2]))
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
