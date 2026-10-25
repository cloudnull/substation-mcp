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
    ///   - `scope:ro:…` / `scope:rw:…` — the access level picked on the login
    ///     form, carried alongside the region prefix (`region:IAD3:scope:ro:<id>`).
    ///     A Keystone bearer's scopes are otherwise re-derived from its roles on
    ///     every request, so without this the form's read-only choice would be
    ///     cosmetic: the page would say read-only while the session kept write.
    ///     `ro` narrows the derived scopes to read; `rw` leaves them alone. It
    ///     can only ever narrow — it never grants write the roles deny.
    public func validate(tokenID: String) async throws -> ValidatedIdentity {
        let (region, scopeRequest, rawTokenID) = Self.splitBearer(tokenID)
        do {
            let vt = try await validator.validate(rawTokenID, region: region)
            // Carry the encoded Token so the serverFactory can rebuild the
            // identity (catalog/regions) without re-validating.
            let raw = AnyTokenPayload(data: try JSONEncoder().encode(vt.token))
            let scopes = scopeRequest == .readOnly
                ? vt.scopes.filter { $0 != .write }
                : vt.scopes
            return ValidatedIdentity(
                tokenID: vt.token.id,
                projectID: vt.token.project.id,
                scopes: scopes.map { $0.rawValue },
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

    /// The access level encoded in a bearer's `scope:` prefix.
    public enum BearerScope: Equatable {
        /// `scope:ro:` — the login form requested read-only.
        case readOnly
        /// `scope:rw:` — the login form requested read + write (the default).
        case readWrite
    }

    /// Parse the optional `region:<REGION>:` and `scope:<ro|rw>:` bearer
    /// prefixes, in either order. Returns `(nil, nil, tokenID)` for a plain
    /// token, and treats an unrecognised prefix as part of the token id (so a
    /// Keystone id that happens to start with `scope:` still validates).
    public static func splitBearer(_ tokenID: String) -> (region: String?, scope: BearerScope?, id: String) {
        var region: String? = nil
        var scope: BearerScope? = nil
        var rest = tokenID
        loop: while true {
            guard let colon = rest.firstIndex(of: ":") else { break }
            let prefix = String(rest[..<colon])
            let remainder = String(rest[rest.index(after: colon)...])
            switch prefix {
            case "region":
                // `region:<REGION>:…` — the region itself never contains ':'.
                guard let second = remainder.firstIndex(of: ":") else { break loop }
                let regionName = String(remainder[..<second])
                let after = String(remainder[remainder.index(after: second)...])
                guard !regionName.isEmpty, !after.isEmpty else { break loop }
                region = regionName
                rest = after
            case "scope":
                // The marker must be followed by a non-empty token payload,
                // otherwise the whole string is the token.
                let marker: String
                if remainder.hasPrefix("ro:") { marker = "ro:" }
                else if remainder.hasPrefix("rw:") { marker = "rw:" }
                else { break loop }
                let after = String(remainder.dropFirst(marker.count))
                guard !after.isEmpty else { break loop }
                scope = marker == "ro:" ? .readOnly : .readWrite
                rest = after
            default:
                break loop
            }
        }
        return (region, scope, rest)
    }

    /// Parse the optional `region:<REGION>:` bearer prefix. Returns
    /// `(nil, tokenID)` for a plain token.
    public static func splitRegion(_ tokenID: String) -> (region: String?, id: String) {
        let (region, _, id) = splitBearer(tokenID)
        return (region, id)
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
