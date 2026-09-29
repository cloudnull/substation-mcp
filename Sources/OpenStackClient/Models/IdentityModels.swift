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

    public init(
        id: String,
        expiresAt: Date,
        project: IdentityRef,
        domain: IdentityRef,
        user: IdentityRef,
        roles: [String],
        catalog: [CatalogEntry]
    ) {
        self.id = id
        self.expiresAt = expiresAt
        self.project = project
        self.domain = domain
        self.user = user
        self.roles = roles
        self.catalog = catalog
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
    /// Roles that grant write access. Default: ["admin"].
    public var writeRoles: [String]

    public init(writeRoles: [String] = ["admin"]) {
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
public func deriveScopes(roles: [String], policy: PolicyRoles = PolicyRoles()) -> [TokenScope] {
    var scopes: [TokenScope] = [.read]
    for role in roles {
        if policy.writeRoles.contains(role) {
            if !scopes.contains(.write) {
                scopes.append(.write)
            }
            break
        }
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

    public enum Kind: Sendable {
        case applicationCredential
        case password
    }

    public static func applicationCredential(id: String, secret: [Int8]) -> MintMethod {
        var m = MintMethod(kind: .applicationCredential, appCredID: id, appCredSecret: secret, userID: nil, domain: nil, password: nil, projectName: nil)
        return m
    }

    public static func password(userID: String, domain: String?, password: String, projectName: String?) -> MintMethod {
        var m = MintMethod(kind: .password, appCredID: nil, appCredSecret: nil, userID: userID, domain: domain, password: password, projectName: projectName)
        return m
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
