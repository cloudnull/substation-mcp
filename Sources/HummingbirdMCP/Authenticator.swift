import Foundation
import Logging
import MCP

/// The MCP SDK `Server` (an actor), re-exported under an unambiguous name.
///
/// Callers that import `OpenStackClient` (whose `OpenStackClient` type shadows
/// the `MCP` module name) or `Hummingbird` cannot spell `MCP.Server` without an
/// `import MCP`, and importing `MCP` collides `Transport` with the OpenStack
/// client's. This alias lets them name the server type directly.
public typealias MCPServer = MCP.Server

/// The validated identity for a single MCP request.
///
/// This is the adapter's notion of "who made this request". The OpenStack
/// `AppTokenValidator` (Task 18) wraps the Task 5 `TokenValidator` + scope
/// derivation and produces one of these; the adapter depends only on this
/// type so it stays OpenStack-free.
public struct ValidatedIdentity: Sendable {
    /// The token id presented in the `Authorization` header.
    public let tokenID: String
    /// The project this token is scoped to.
    public let projectID: String
    /// The scopes granted to the token (e.g. `openstack:read`, `openstack:write`).
    public let scopes: [String]
    /// An opaque, `Sendable` payload the caller can use to build the per-request
    /// MCP server (e.g. a decoded OpenStack `Token`). `nil` when the caller only
    /// needs the fields above.
    public let raw: AnyTokenPayload?

    public init(tokenID: String, projectID: String, scopes: [String], raw: AnyTokenPayload? = nil) {
        self.tokenID = tokenID
        self.projectID = projectID
        self.scopes = scopes
        self.raw = raw
    }
}

/// An opaque, `Sendable` token payload carried in ``ValidatedIdentity/raw``.
///
/// The adapter never inspects it; it is handed to the `serverFactory` so the
/// OpenStack side can attach the decoded token to the session.
public struct AnyTokenPayload: Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

/// The seam the adapter uses to validate a bearer token on **every** request.
///
/// Implementations must be cheap to call repeatedly (the OpenStack validator
/// caches by token id, spec §7.1). Throwing means "invalid token" (→ 401).
public protocol TokenValidating: Sendable {
    /// Validate a bearer token id and return the identity it resolves to.
    /// - Throws: an error meaning the token is invalid (surfaced as 401).
    func validate(tokenID: String) async throws -> ValidatedIdentity
}

/// A validation failure that should be surfaced as a 401.
public struct TokenValidationError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(message: String) {
        self.message = message
    }
    public var description: String { message }
}

/// Result of authorizing a request before the MCP session is consulted.
///
/// The adapter enforces *audience* (token valid but project not served) and
/// *scope* (a write-gated tool called without `openstack:write`) as HTTP-level
/// 403s per spec §7.1. A valid token with a known project passes.
public enum AuthorizationDecision: Sendable {
    /// The token is valid; the request may proceed.
    case allow(ValidatedIdentity)
    /// The token is valid but lacks the scope this request requires.
    case insufficientScope(required: String)
    /// The token is valid but its project is not served by this deployment.
    case audienceMismatch
}

/// Decides how a request is authorized, given the validated identity and the
/// required scope for the request (write tools need `openstack:write`).
///
/// The OpenStack `AppTokenValidator` supplies `servedProjects`; an empty set
/// means "serve all projects".
public struct ScopeAuthorizer: Sendable {
    public let servedProjects: Set<String>

    public init(servedProjects: Set<String> = []) {
        self.servedProjects = servedProjects
    }

    /// `requiredScope` is `nil` for read-only requests, or `"openstack:write"` for mutating ones.
    public func authorize(_ identity: ValidatedIdentity, requiredScope: String?) -> AuthorizationDecision {
        if !servedProjects.isEmpty, !servedProjects.contains(identity.projectID) {
            return .audienceMismatch
        }
        if let required = requiredScope, !identity.scopes.contains(required) {
            return .insufficientScope(required: required)
        }
        return .allow(identity)
    }
}

/// The set of tool names that require the `openstack:write` scope.
///
/// The adapter uses this to decide, per `tools/call`, whether the caller must
/// hold `openstack:write`. Task 18 wires this to the real OpenStack mutating
/// tool names (the `os_*` write tools) so the gate stays in sync with the
/// server's policy.
public struct WriteToolGate: Sendable {
    public let toolNames: Set<String>

    /// Default (tests / no-OpenStack) gate: empty, so no tool is write-gated.
    public init(toolNames: Set<String> = []) {
        self.toolNames = toolNames
    }

    /// Whether a `tools/call` of `toolName` requires `openstack:write`.
    public func requiresWrite(_ toolName: String) -> Bool {
        toolNames.contains(toolName)
    }
}
