import Foundation

/// The five OpenStack services covered in phase 1.
public enum Service: String, Sendable, CaseIterable, Codable {
    case identity
    case compute
    case network
    case blockStorage
    case image
    case objectStorage
    case keyManager
    case loadBalancer
    case dns
    case containerInfra
    case orchestration
    case sharev2
}

extension Service {
    /// The Keystone catalog `service_type` that this service resolves to in a
    /// token's catalog. Used by P2 per-service scopes: a token may mutate a
    /// service only if its own catalog contains this type.
    ///
    /// Note this is the *catalog* type, which for block storage is `volumev3`
    /// (the Cinder v3 service type real clouds advertise), NOT the v2 `volume`
    /// alias.
    public var serviceTypeName: String {
        switch self {
        case .identity: "identity"
        case .compute: "compute"
        case .network: "network"
        case .blockStorage: "volumev3"
        case .image: "image"
        case .objectStorage: "object-store"
        case .keyManager: "key-manager"
        case .loadBalancer: "load-balancer"
        case .dns: "dns"
        case .containerInfra: "container-infra"
        case .orchestration: "orchestration"
        case .sharev2: "sharev2"
        }
    }

    /// Every per-service scope name, for PRM advertisement (`<type>:write`).
    public static var allServiceScopeNames: [String] {
        allCases.map { "\($0.serviceTypeName):write" }
    }
}

/// The five resource verbs.
public enum Verb: String, Sendable, CaseIterable, Codable {
    case list
    case get
    case create
    case update
    case delete
}

/// A single parameter for an action or link.
public struct ParamSpec: Sendable {
    public let name: String
    public let type: String
    public let required: Bool
    public let enumValues: [String]?
    public let description: String?

    public init(name: String, type: String = "string", required: Bool = false, enumValues: [String]? = nil, description: String? = nil) {
        self.name = name
        self.type = type
        self.required = required
        self.enumValues = enumValues
        self.description = description
    }
}

/// A resource-level action (e.g. `server.reboot`, `volume.extend`).
public struct ActionSpec: Sendable {
    public let name: String
    public let destructive: Bool
    public let adminOnly: Bool
    public let params: [ParamSpec]

    public init(name: String, destructive: Bool = false, adminOnly: Bool = false, params: [ParamSpec] = []) {
        self.name = name
        self.destructive = destructive
        self.adminOnly = adminOnly
        self.params = params
    }
}

/// A reference to a resource by name and optional id/name value.
public struct ResourceRef: Hashable, Sendable {
    public let resource: String
    public let idOrName: String?

    public init(resource: String, idOrName: String? = nil) {
        self.resource = resource
        self.idOrName = idOrName
    }
}

/// A link between two resources (e.g. attach a volume to a server).
public struct LinkSpec: Sendable {
    public let kind: String
    public let source: ResourceRef
    public let target: ResourceRef
    public let params: [ParamSpec]
    public let preconditions: [String]

    public init(kind: String, source: ResourceRef, target: ResourceRef, params: [ParamSpec] = [], preconditions: [String] = []) {
        self.kind = kind
        self.source = source
        self.target = target
        self.params = params
        self.preconditions = preconditions
    }
}

/// A request to the dispatch layer.
public struct DispatchRequest: Sendable {
    public let region: String
    public let filters: [String: String]
    public let limit: Int?
    public let marker: String?
    public let id: String?
    public let body: [String: JSONValue]?
    public let fresh: Bool

    public init(
        region: String,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil,
        id: String? = nil,
        body: [String: JSONValue]? = nil,
        fresh: Bool = false
    ) {
        self.region = region
        self.filters = filters
        self.limit = limit
        self.marker = marker
        self.id = id
        self.body = body
        self.fresh = fresh
    }
}

/// The dispatch seam: closures mapping verbs/actions/links to client calls.
///
/// The MCP layer calls these closures with a raw request and receives raw
/// decoded JSON back. This keeps the catalog declarative while the MCP layer
/// never touches client types directly (Task 13 handles formatting).
public struct ServiceDispatch: Sendable {
    public let list: (@Sendable (DispatchRequest) async throws -> [String: JSONValue])?
    public let get: (@Sendable (DispatchRequest) async throws -> [String: JSONValue])?
    public let create: (@Sendable (DispatchRequest) async throws -> [String: JSONValue])?
    public let update: (@Sendable (DispatchRequest) async throws -> [String: JSONValue])?
    public let delete: (@Sendable (DispatchRequest) async throws -> [String: JSONValue])?
    public let action: (@Sendable (DispatchRequest, String, [String: JSONValue]) async throws -> [String: JSONValue])?
    public let link: (@Sendable (DispatchRequest, String, [String: JSONValue]) async throws -> [String: JSONValue])?

    public init(
        list: (@Sendable (DispatchRequest) async throws -> [String: JSONValue])? = nil,
        get: (@Sendable (DispatchRequest) async throws -> [String: JSONValue])? = nil,
        create: (@Sendable (DispatchRequest) async throws -> [String: JSONValue])? = nil,
        update: (@Sendable (DispatchRequest) async throws -> [String: JSONValue])? = nil,
        delete: (@Sendable (DispatchRequest) async throws -> [String: JSONValue])? = nil,
        action: (@Sendable (DispatchRequest, String, [String: JSONValue]) async throws -> [String: JSONValue])? = nil,
        link: (@Sendable (DispatchRequest, String, [String: JSONValue]) async throws -> [String: JSONValue])? = nil
    ) {
        self.list = list
        self.get = get
        self.create = create
        self.update = update
        self.delete = delete
        self.action = action
        self.link = link
    }
}

/// A complete descriptor for one OpenStack resource.
///
/// This is a class (not a struct) because it contains `ServiceDispatch`
/// (closures) and `JSONSchema` (recursive).
public final class ResourceDescriptor: @unchecked Sendable {
    public let name: String
    public let service: Service
    public let verbs: Set<Verb>
    public let actions: [ActionSpec]
    public let links: [LinkSpec]
    public let createSchema: JSONSchema?
    public let updateSchema: JSONSchema?
    public let listFilters: Set<String>
    public let idField: String
    public let nameField: String?
    public let statusField: String?
    public let terminalStates: [String]
    public let defaultListFields: [String]
    public let destructiveHints: [String]
    public let dispatch: ServiceDispatch

    public init(
        name: String,
        service: Service,
        verbs: Set<Verb>,
        actions: [ActionSpec] = [],
        links: [LinkSpec] = [],
        createSchema: JSONSchema? = nil,
        updateSchema: JSONSchema? = nil,
        listFilters: Set<String> = [],
        idField: String = "id",
        nameField: String? = "name",
        statusField: String? = nil,
        terminalStates: [String] = [],
        defaultListFields: [String] = ["id", "name"],
        destructiveHints: [String] = [],
        dispatch: ServiceDispatch = ServiceDispatch()
    ) {
        self.name = name
        self.service = service
        self.verbs = verbs
        self.actions = actions
        self.links = links
        self.createSchema = createSchema
        self.updateSchema = updateSchema
        self.listFilters = listFilters
        self.idField = idField
        self.nameField = nameField
        self.statusField = statusField
        self.terminalStates = terminalStates
        self.defaultListFields = defaultListFields
        self.destructiveHints = destructiveHints
        self.dispatch = dispatch
    }
}
