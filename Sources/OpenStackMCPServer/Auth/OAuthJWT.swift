import Crypto
import Foundation

// MARK: - Stateless OAuth 2.1 JWT primitives
//
// Authorization codes and access tokens are short-lived HS256 JWTs signed
// with the OAuth server secret. No in-memory state is kept: each token is
// self-contained and can be verified by any instance that knows the secret.
// The MCP access tokens are prefixed with `stst.at.` so the MCP gate can
// distinguish them from raw Keystone bearer tokens without parsing.

/// base64url helpers per RFC 4648 §5 (no padding), used for the JWT header,
/// payload, signature, PKCE S256 code challenges, and the deterministic DCR
/// `client_id` derivation.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }
}

/// SHA-256 helper (used for PKCE S256 and DCR client_id derivation).
public func sha256Hex(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// HMAC-SHA256 of `message` under `secret`, as base64url.
public func hmacSHA256Base64URL(key: String, message: String) -> String {
    let k = SymmetricKey(data: Data(key.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: k)
    return Base64URL.encode(Data(mac))
}

/// A tiny `Any`-tagged Codable value for JWT claims.
///
/// Only the shapes the JWT payloads actually use (String / Int / Bool /
/// [String] / nil) are modelled; everything else decodes as `.null` so we
/// never crash on unknown claim types.
public enum AnyCodableValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([AnyCodableValue])
    case null

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var int: Int?       { if case .int(let i)   = self { return i } else { return nil } }
    public var bool: Bool?     { if case .bool(let b)  = self { return b } else { return nil } }
    public var array: [AnyCodableValue]? { if case .array(let a) = self { return a } else { return nil } }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let i = try? c.decode(Int.self)    { self = .int(i); return }
        if let b = try? c.decode(Bool.self)   { self = .bool(b); return }
        if let a = try? c.decode([AnyCodableValue].self) { self = .array(a); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i):    try c.encode(i)
        case .bool(let b):   try c.encode(b)
        case .array(let a):  try c.encode(a)
        case .null:          try c.encodeNil()
        }
    }

    /// The Foundation JSON-serializable form of this claim value.
    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i):    return i
        case .bool(let b):   return b
        case .array(let a):  return a.map { $0.jsonValue }
        case .null:          return NSNull()
        }
    }
}

/// A verified HS256 JWT.
///
/// Carries the raw JSON claims so callers can reach into non-standard fields
/// (`osk`, `prj`, `sco`, `challenge`, ...) while still exposing the standard
/// ones (`iss`, `aud`, `exp`, `iat`, `jti`, `sub`) for convenience.
public struct VerifiedJWT: Sendable, Equatable {
    public let header: [String: AnyCodableValue]
    public let payload: [String: AnyCodableValue]
    public let rawClaims: [String: AnyCodableValue]

    public subscript(key: String) -> AnyCodableValue? {
        rawClaims[key]
    }

    public var issuer: String?    { string("iss") }
    public var subject: String?   { string("sub") }
    public var audience: [String] {
        if let arr = payload["aud"]?.array { return arr.compactMap { $0.string } }
        if let s = payload["aud"]?.string   { return [s] }
        return []
    }
    public var issuedAt: Int?     { int("iat") }
    public var expiresAt: Int?    { int("exp") }
    public var jti: String?       { string("jti") }

    public func string(_ key: String) -> String? { rawClaims[key]?.string }
    public func int(_ key: String) -> Int?       { rawClaims[key]?.int }

    /// Whether the token is expired at `now` (unix seconds). A JWT without an
    /// `exp` claim is treated as valid for the lifetime of the process.
    public func isExpired(now: Int) -> Bool {
        guard let exp = expiresAt else { return false }
        return now >= exp
    }

    init(header: [String: AnyCodableValue], payload: [String: AnyCodableValue]) {
        self.header = header
        self.payload = payload
        self.rawClaims = payload
    }
}

// MARK: - HS256 JWT sign + verify

public enum OAuthJWTError: Error, Equatable, Sendable {
    case malformed
    case badAlgorithm
    case badSignature
    case expired(now: Int, exp: Int)
    case wrongIssuer(expected: String, actual: String?)
    case emptyClaims
}

/// Sign an HS256 JWT. Returns nil if the claims are not JSON-serializable.
///
/// - Parameters:
///   - header: The JWT `header` object (defaults to `{"alg":"HS256","typ":"JWT"}`).
///   - claims: The JWT `payload` object.
///   - secret: The shared secret.
public func signJWT(
    header: [String: AnyCodableValue] = ["alg": .string("HS256"), "typ": .string("JWT")],
    claims: [String: AnyCodableValue],
    secret: String
) -> String? {
    guard
        let headerJSON = try? JSONSerialization.data(withJSONObject: header.mapValues { $0.jsonValue }),
        let claimsJSON = try? JSONSerialization.data(withJSONObject: claims.mapValues { $0.jsonValue })
    else { return nil }
    let signingInput = Base64URL.encode(headerJSON) + "." + Base64URL.encode(claimsJSON)
    let sig = hmacSHA256Base64URL(key: secret, message: signingInput)
    return signingInput + "." + sig
}

/// Verify an HS256 JWT signed under `secret`. Returns the parsed claims, or
/// throws on any verification failure.
///
/// - Parameters:
///   - token: The compact JWT (no `stst.` prefix).
///   - secret: The shared secret.
///   - now: The current unix timestamp (inject for tests).
///   - expectedIssuer: When non-nil, `iss` must match exactly.
public func verifyJWT(
    _ token: String,
    secret: String,
    now: Int = Int(Date().timeIntervalSince1970),
    expectedIssuer: String? = nil
) throws -> VerifiedJWT {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { throw OAuthJWTError.malformed }
    let headB64 = String(parts[0])
    let payB64  = String(parts[1])
    let sigB64  = String(parts[2])
    guard
        let headData = Base64URL.decode(headB64),
        let payData  = Base64URL.decode(payB64)
    else { throw OAuthJWTError.malformed }
    guard
        let headerDict = try? JSONSerialization.jsonObject(with: headData) as? [String: Any],
        let payloadDict = try? JSONSerialization.jsonObject(with: payData) as? [String: Any]
    else { throw OAuthJWTError.malformed }
    let headerClaims = headerDict.mapValues(AnyCodableValue.init(describing:))
    let payloadClaims = payloadDict.mapValues(AnyCodableValue.init(describing:))
    guard let alg = headerClaims["alg"]?.string, alg == "HS256" else {
        throw OAuthJWTError.badAlgorithm
    }
    let expectedSig = hmacSHA256Base64URL(key: secret, message: headB64 + "." + payB64)
    guard constantTimeEquals(sigB64, expectedSig) else { throw OAuthJWTError.badSignature }
    if let exp = payloadClaims["exp"]?.int, now >= exp {
        throw OAuthJWTError.expired(now: now, exp: exp)
    }
    if let expectedIssuer, expectedIssuer != payloadClaims["iss"]?.string {
        throw OAuthJWTError.wrongIssuer(expected: expectedIssuer, actual: payloadClaims["iss"]?.string)
    }
    guard !payloadClaims.isEmpty else { throw OAuthJWTError.emptyClaims }
    return VerifiedJWT(header: headerClaims, payload: payloadClaims)
}

// MARK: - OAuth access token

/// A verified `stst.at.`-prefixed OAuth access token.
///
/// Carries the embedded Keystone token id (used by the MCP gate to delegate
/// to the existing `TokenValidator` if the raw payload is missing) plus the
/// project and scopes so the MCP gate can build a `ValidatedIdentity` without
/// a second Keystone round-trip.
public struct OAuthAccessToken: Sendable, Equatable {
    public let tokenID: String    // embedded Keystone token id (osk)
    public let projectID: String  // prj
    public let scopes: [String]   // sco (space-separated in the JWT)
    public let expiresAt: Int
    public let clientID: String?  // oauth client_id (when issued to one)
    public let issuer: String

    public init(tokenID: String, projectID: String, scopes: [String],
                expiresAt: Int, clientID: String?, issuer: String) {
        self.tokenID = tokenID
        self.projectID = projectID
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.clientID = clientID
        self.issuer = issuer
    }
}

/// The wire prefix for an OAuth access token: `stst.at.<compact-jwt>`.
public let OAuthAccessTokenPrefix = "stst.at."

extension VerifiedJWT {
    /// Parse a verified `stst.at.` access token into its claim shape, or
    /// return nil if the required claims are missing.
    public func asOAuthAccessToken() -> OAuthAccessToken? {
        guard
            let osk = string("osk"), !osk.isEmpty,
            let prj = string("prj"), !prj.isEmpty,
            let exp = int("exp")
        else { return nil }
        let sco = string("sco") ?? ""
        let scopes = sco.split(whereSeparator: { $0 == " " }).map(String.init)
        return OAuthAccessToken(
            tokenID: osk,
            projectID: prj,
            scopes: scopes,
            expiresAt: exp,
            clientID: string("client_id"),
            issuer: issuer ?? ""
        )
    }
}

// MARK: - PKCE S256

/// The PKCE S256 code challenge: base64url(SHA256(verifier)).
public func pkceS256Challenge(_ verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Base64URL.encode(Data(digest))
}

/// Constant-time compare for the token endpoint.
@inline(__always)
public func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aa = Array(a.utf8), bb = Array(b.utf8)
    guard aa.count == bb.count, !aa.isEmpty else { return false }
    var diff: UInt8 = 0
    for i in 0..<aa.count { diff |= aa[i] ^ bb[i] }
    return diff == 0
}

// MARK: - AnyCodableValue bridging from Foundation JSON

extension AnyCodableValue {
    /// Bridge a Foundation `JSONSerialization` `Any` value into a
    /// `AnyCodableValue`. Order matters: `Bool` must be matched before
    /// `Int` because of the NSNumber bridging on macOS.
    init(describing value: Any) {
        switch value {
        case let b as Bool:
            self = .bool(b)
        case let s as String:
            self = .string(s)
        case let i as Int:
            self = .int(i)
        case let a as [Any]:
            self = .array(a.map(AnyCodableValue.init(describing:)))
        default:
            self = .null
        }
    }
}
