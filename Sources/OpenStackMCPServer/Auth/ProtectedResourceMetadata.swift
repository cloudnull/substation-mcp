import Foundation

// MARK: - Auth profile (spec §6.0)

/// The deployment's auth profile, selected by config (`auth.profile`).
public enum AuthProfile: String, Sendable {
    /// P1 — Keystone v3 token is the bearer; Keystone is the authorization server.
    case keystoneToken = "keystone_token"
    /// P2 — an OAuth 2.1 AS fronts it. Phase 1 ships metadata indirection only.
    case oauth = "oauth"
}

/// The RFC 9728 Protected Resource Metadata document served at
/// `/.well-known/oauth-protected-resource` (and `.../v1`).
///
/// - P1: `authorization_servers` names the Keystone URL.
/// - P2: names the AS URL (phase 2).
public struct ProtectedResourceMetadata: Codable, Sendable {
    /// The canonical identifier of this resource server.
    public let resource: String
    /// The authorization servers that can issue tokens for this resource.
    public let authorizationServers: [String]
    /// The scopes this resource server enforces.
    public let scopesSupported: [String]

    public init(resource: String, authorizationServers: [String], scopesSupported: [String]) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }

    /// Build the PRM document for a deployment.
    ///
    /// - Parameters:
    ///   - publicURL: The canonical public base URL (e.g. `https://mcp.example.com`),
    ///     used as the `resource` identifier. When `nil`, falls back to `keystoneURL`.
    ///   - authProfile: The deployment's auth profile.
    ///   - keystoneURL: The Keystone base URL (P1 `authorization_servers`).
    ///   - authServerURL: The OAuth AS URL (P2 `authorization_servers`).
    public static func document(
        publicURL: String?,
        authProfile: AuthProfile,
        keystoneURL: URL?,
        authServerURL: URL? = nil,
        scopesSupported: [String]? = nil
    ) -> ProtectedResourceMetadata {
        let resource = publicURL ?? keystoneURL?.absoluteString ?? ""
        let servers: [String]
        switch authProfile {
        case .keystoneToken:
            servers = keystoneURL.map { [$0.absoluteString] } ?? []
        case .oauth:
            servers = authServerURL.map { [$0.absoluteString] }
                ?? keystoneURL.map { [$0.absoluteString] }
                ?? []
        }
        return ProtectedResourceMetadata(
            resource: resource,
            authorizationServers: servers,
            scopesSupported: scopesSupported ?? ["openstack:read", "openstack:write"]
        )
    }

    /// The PRM document encoded as JSON (for the adapter's PRM closure).
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

extension ProtectedResourceMetadata {
    // Use snake_case wire keys per RFC 9728.
    private enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}
