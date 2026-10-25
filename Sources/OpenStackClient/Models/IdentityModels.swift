import Foundation

/// A reference to an identity (user, project, or domain).
public struct IdentityRef: Sendable, Codable, Equatable {
    public let id: String
    public let name: String?
    public let domain: String?

    public init(id: String, name: String? = nil, domain: String? = nil) {
        self.id = id
        self.name = name
        self.domain = domain
    }
}

/// A validated Keystone token with its catalog and identity context.
public struct Token: Sendable, Codable {
    public let id: String
    public let expiresAt: Date
    public let project: IdentityRef
    public let domain: IdentityRef
    public let user: IdentityRef
    public let roles: [String]
    public let catalog: [CatalogEntry]
    /// OS-FEDERATION block from the token (`methods: ["mapped"]`). Present only
    /// when the token was issued via Keystone federation (unscoped WebSSO token
    /// or a scoped token exchanged from one). Used by the login path to verify
    /// a pasted/exchanged token really came from the configured IdP.
    public let fedInfo: FedInfo?

    public init(
        id: String,
        expiresAt: Date,
        project: IdentityRef,
        domain: IdentityRef,
        user: IdentityRef,
        roles: [String],
        catalog: [CatalogEntry],
        fedInfo: FedInfo? = nil
    ) {
        self.id = id
        self.expiresAt = expiresAt
        self.project = project
        self.domain = domain
        self.user = user
        self.roles = roles
        self.catalog = catalog
        self.fedInfo = fedInfo
    }
}

/// The `user.OS-FEDERATION` block carried by a Keystone federation token.
public struct FedInfo: Sendable, Codable, Equatable {
    public let identityProvider: String?
    public let protocolName: String?
    public let groups: [String]?

    public init(identityProvider: String?, protocolName: String?, groups: [String]?) {
        self.identityProvider = identityProvider
        self.protocolName = protocolName
        self.groups = groups
    }
}
/// A single entry in the Keystone service catalog.
public struct CatalogEntry: Sendable, Codable, Equatable {
    public let type: String
    public let name: String
    public let endpoints: [CatalogEndpoint]

    public init(type: String, name: String, endpoints: [CatalogEndpoint]) {
        self.type = type
        self.name = name
        self.endpoints = endpoints
    }
}

/// An endpoint in the service catalog.
public struct CatalogEndpoint: Sendable, Codable, Equatable {
    public let region: String
    public let interface: String
    public let url: URL

    public init(region: String, interface: String, url: URL) {
        self.region = region
        self.interface = interface
        self.url = url
    }
}

/// Token scope: read or write access to OpenStack resources.
public enum TokenScope: String, Sendable, Codable, CaseIterable {
    case read = "openstack:read"
    case write = "openstack:write"
}

/// Policy for deriving scopes from roles.
public struct PolicyRoles: Sendable, Codable {
    /// Roles that grant `openstack:write`. Default: `["admin", "member"]` —
    /// `member` because public clouds gate ordinary project writes on it, not
    /// on a literal `admin`. See `Policy.defaultWriteRoles` (server side),
    /// which is the value production wiring passes in.
    public static let defaultWriteRoles: [String] = ["admin", "member"]

    /// Roles that grant `openstack:write`.
    public var writeRoles: [String]

    public init(writeRoles: [String] = PolicyRoles.defaultWriteRoles) {
        self.writeRoles = writeRoles
    }
}

/// A validated token with derived scopes.
public struct ValidatedToken: Sendable {
    public let token: Token
    public let scopes: [TokenScope]

    public init(token: Token, scopes: [TokenScope]) {
        self.token = token
        self.scopes = scopes
    }
}

/// Scope derivation: pure function, unit-testable without a cloud.
/// - `read` is granted to any authenticated project token.
/// - `write` is granted when roles include a mutating role (default: "admin").
/// - `requested` (the access level picked on the login / authorize form) can
///   only ever NARROW the result: `["openstack:read"]` drops `write` even for
///   an admin, and an unknown or empty request leaves the role-derived set
///   alone. It can never widen it — a member asking for write still gets read.
public func deriveScopes(roles: [String], policy: PolicyRoles = PolicyRoles(), requested: [String] = []) -> [TokenScope] {
    var scopes: [TokenScope] = [.read]
    for role in roles {
        if policy.writeRoles.contains(role) {
            if !scopes.contains(.write) {
                scopes.append(.write)
            }
            break
        }
    }
    if requested.contains(TokenScope.read.rawValue) && !requested.contains(TokenScope.write.rawValue) {
        scopes.removeAll { $0 == .write }
    }
    return scopes
}

/// Method for minting a token at the login page.
public struct MintMethod: Sendable {
    public var kind: Kind
    public var appCredID: String?
    public var appCredSecret: [Int8]?
    public var userID: String?
    public var domain: String?
    public var password: String?
    public var projectName: String?
    /// The token id for `federationToken` mints (an unscoped or project-scoped
    /// federation token obtained outside substation, e.g. pasted from a portal
    /// session). Reused verbatim as the `methods:["token"]` exchange input.
    public var fedTokenID: String?
    /// True when the presented federation token is already project-scoped —
    /// the minter must not add a scope block in that case (Keystone rejects a
    /// re-scope of a scoped token with 400). Unscoped tokens get an optional
    /// `projectName` scope applied.
    public var fedTokenIsScoped: Bool

    public enum Kind: Sendable {
        case applicationCredential
        case password
        case federationToken
    }

    public static func applicationCredential(id: String, secret: [Int8]) -> MintMethod {
        MintMethod(kind: .applicationCredential, appCredID: id, appCredSecret: secret, userID: nil, domain: nil, password: nil, projectName: nil, fedTokenID: nil, fedTokenIsScoped: false)
    }

    public static func password(userID: String, domain: String?, password: String, projectName: String?) -> MintMethod {
        MintMethod(kind: .password, appCredID: nil, appCredSecret: nil, userID: userID, domain: domain, password: password, projectName: projectName, fedTokenID: nil, fedTokenIsScoped: false)
    }

    /// Exchange / present a Keystone federation token (`methods: ["token"]`).
    /// Used both by the WebSSO callback (unscoped → project-scoped exchange)
    /// and by the paste-token form field (already-scoped tokens pass through;
    /// unscoped ones are project-scoped here).
    public static func federationToken(tokenID: String, isScoped: Bool, projectName: String? = nil) -> MintMethod {
        MintMethod(kind: .federationToken, appCredID: nil, appCredSecret: nil, userID: nil, domain: nil, password: nil, projectName: projectName, fedTokenID: tokenID, fedTokenIsScoped: isScoped)
    }
}

/// Whoami response: the identity context of a validated token.
public struct Whoami: Sendable {
    public let project: IdentityRef
    public let domain: IdentityRef
    public let roles: [String]
    public let scopes: [TokenScope]
    public let expiresAt: Date
    public let credentialName: String?
    public let unrestricted: Bool?
    public let accessRules: [[String: String]]?
    public let regions: [String]
    public let services: [String: [String]]

    public init(
        project: IdentityRef,
        domain: IdentityRef,
        roles: [String],
        scopes: [TokenScope],
        expiresAt: Date,
        credentialName: String? = nil,
        unrestricted: Bool? = nil,
        accessRules: [[String: String]]? = nil,
        regions: [String] = [],
        services: [String: [String]] = [:]
    ) {
        self.project = project
        self.domain = domain
        self.roles = roles
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.credentialName = credentialName
        self.unrestricted = unrestricted
        self.accessRules = accessRules
        self.regions = regions
        self.services = services
    }
}
