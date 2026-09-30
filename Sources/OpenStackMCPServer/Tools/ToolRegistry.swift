import Foundation
import MCP
import OpenStackClient
import Logging

/// Neutron port. Spelled `NetPort` because bare `Port` resolves to NIO's
/// `VsockAddress.Port` in every file that imports `OpenStackClient` (NIOCore is
/// publicly imported by Hummingbird, so both are in scope).
public typealias NetPort = OSPort

/// The identity context for a single MCP session.
public struct RequestIdentity: Sendable {
    public let vt: ValidatedToken
    public let whoami: Whoami
    /// The cloud name this session is bound to. Used to scope resource URIs
    /// (`openstack://{cloud}/{region}/{resource}/{id}`) so a client can only
    /// read the cloud it is authenticated against.
    public let cloudName: String

    public init(vt: ValidatedToken, whoami: Whoami, cloudName: String) {
        self.vt = vt
        self.whoami = whoami
        self.cloudName = cloudName
    }
}

/// The tool registry: maps the 15 MCP tools to OpenStack client calls.
///
/// The registry is scope-aware: a read-only token gets 9 tools,
/// a write-scoped token gets all 15.
public struct ToolRegistry: Sendable {
    public let client: OpenStackClient
    public let catalog: ResourceCatalog
    public let policy: Policy
    public let identity: RequestIdentity
    public let logger: Logger

    public init(
        client: OpenStackClient,
        catalog: ResourceCatalog,
        policy: Policy = Policy(),
        identity: RequestIdentity,
        logger: Logger = Logger(label: "openstack-mcp")
    ) {
        self.client = client
        self.catalog = policy.effective(catalog)
        self.policy = policy
        self.identity = identity
        self.logger = logger
    }

    public var hasWrite: Bool {
        identity.vt.scopes.contains(.write)
    }

    /// The session's default region (from whoami), or `RegionOne` when unknown.
    /// Used to render the live-resource URI template in `resources/list`.
    var defaultRegion: String {
        identity.whoami.regions.first ?? "RegionOne"
    }

    /// The tool names visible to the current identity.
    public var visibleToolNames: [String] {
        guard hasWrite else {
            return Array(policy.toolsEnabled())
        }
        return [
            "os_list", "os_get", "os_describe", "os_topology",
            "os_find", "os_whoami", "os_quota", "os_clouds", "os_wait",
            "os_create", "os_update", "os_delete", "os_action",
            "os_attach", "os_detach",
        ]
    }

    /// Build the MCP `Server` with all tool handlers registered.
    public func makeServer() async -> MCP.Server {
        let server = MCP.Server(
            name: "openstack-mcp",
            version: "1.0.0",
            instructions: "OpenStack cloud management via MCP. Use os_describe(resource:) to see the JSON schema for a resource before creating or updating. Use os_find to search by IP or name. Use os_topology to understand connectivity. Mutating operations require write scope.",
            capabilities: .init(
                prompts: .init(),
                resources: .init(),
                tools: .init()
            )
        )

        let registry = self
        let resources = MCPResources(registry: registry)
        let prompts = MCPPrompts(registry: registry)

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: registry.visibleTools())
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await registry.dispatch(params, server: server)
        }

        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: resources.list())
        }

        await server.withMethodHandler(ReadResource.self) { params in
            ReadResource.Result(contents: await resources.read(params.uri))
        }

        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(prompts: prompts.list())
        }

        await server.withMethodHandler(GetPrompt.self) { params in
            let result = prompts.get(params.name, arguments: params.arguments)
            return GetPrompt.Result(
                description: result.description,
                messages: result.messages
            )
        }

        return server
    }

    // MARK: - Tool definitions

    func visibleTools() -> [Tool] {
        let all: [Tool] = [
            Tool(
                name: "os_list",
                description: "List OpenStack resources. Use filters to narrow results. Call os_describe(resource:) first to see available filters.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "region": .object(["type": .string("string")]),
                        "filters": .object(["type": .string("object")]),
                        "fields": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "limit": .object(["type": .string("integer")]),
                        "marker": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("resource")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_get",
                description: "Get a single OpenStack resource by ID or name. Ambiguous names return an error listing candidates.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "id_or_name": .object(["type": .string("string")]),
                        "region": .object(["type": .string("string")]),
                        "fields": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_describe",
                description: "Describe a resource type: verbs, actions, links, create/update schemas, list filters, terminal states.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                    ]),
                    "required": .array([.string("resource")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_topology",
                description: "Show the topology around an anchor resource with optional diagnosis findings.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "id_or_name": .object(["type": .string("string")]),
                        "region": .object(["type": .string("string")]),
                        "depth": .object(["type": .string("integer")]),
                        "diagnosis": .object(["type": .string("boolean")]),
                        "diagnose": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "protocol": .object(["type": .string("string")]),
                                "port": .object(["type": .string("integer")]),
                            ]),
                        ]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_find",
                description: "Search across resources for a value (IP address, name, etc.).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object(["type": .string("string")]),
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "region": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("value")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_whoami",
                description: "Show the current identity: project, domain, roles, scopes, regions, services.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_quota",
                description: "Show resource quotas for the current project.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "service": .object(["type": .string("string"), "enum": .array([.string("compute"), .string("network"), .string("volume"), .string("image")])]),
                        "region": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("service")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_clouds",
                description: "Show the cloud's regions and available services per region.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_wait",
                description: "Wait for a resource to reach a terminal state. Sends progress notifications.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "id": .object(["type": .string("string")]),
                        "region": .object(["type": .string("string")]),
                        "until": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "timeout_seconds": .object(["type": .string("integer")]),
                    ]),
                    "required": .array([.string("resource"), .string("id")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_create",
                description: "Create an OpenStack resource. Call os_describe(resource:) first for the create schema. dry_run validates without creating.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "spec": .object(["type": .string("object")]),
                        "region": .object(["type": .string("string")]),
                        "dry_run": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("resource"), .string("spec")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "os_update",
                description: "Update an OpenStack resource (PATCH). Call os_describe(resource:) first for the update schema.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "id_or_name": .object(["type": .string("string")]),
                        "patch": .object(["type": .string("object")]),
                        "region": .object(["type": .string("string")]),
                        "dry_run": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name"), .string("patch")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "os_delete",
                description: "Delete an OpenStack resource. dry_run:true returns dependent resources that block deletion.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "id_or_name": .object(["type": .string("string")]),
                        "region": .object(["type": .string("string")]),
                        "dry_run": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true)
            ),
            Tool(
                name: "os_action",
                description: "Perform a resource action (reboot, extend, set_bootable, etc). Per-action details in os_describe.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "id_or_name": .object(["type": .string("string")]),
                        "action": .object(["type": .string("string")]),
                        "params": .object(["type": .string("object")]),
                        "region": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name"), .string("action")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true)
            ),
            Tool(
                name: "os_attach",
                description: "Attach a link between two resources (volume, interface, security_group, floating_ip, router_interface, router_gateway).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "link": .object(["type": .string("string"), "enum": .array(linkEnum())]),
                        "source": .object(["type": .string("string")]),
                        "source_type": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "target": .object(["type": .string("string")]),
                        "target_type": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "params": .object(["type": .string("object")]),
                        "region": .object(["type": .string("string")]),
                        "wait": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("link"), .string("source"), .string("source_type"), .string("target"), .string("target_type")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "os_detach",
                description: "Detach a link (reverse of os_attach). Floating IP detach = disassociate, never delete.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "link": .object(["type": .string("string"), "enum": .array(linkEnum())]),
                        "source": .object(["type": .string("string")]),
                        "source_type": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "target": .object(["type": .string("string")]),
                        "target_type": .object(["type": .string("string"), "enum": .array(resourceEnum())]),
                        "region": .object(["type": .string("string")]),
                        "wait": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("link"), .string("source"), .string("source_type"), .string("target"), .string("target_type")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
        ]
        let visible = Set(visibleToolNames)
        return all.filter { visible.contains($0.name) }
    }

    private func resourceEnum() -> [Value] {
        catalog.names.sorted().map { .string($0) }
    }

    private func linkEnum() -> [Value] {
        catalog.allLinks.keys.sorted().map { .string($0) }
    }

    // MARK: - Dispatch

    func dispatch(_ params: CallTool.Parameters, server: MCP.Server) async throws -> CallTool.Result {
        let mutatingTools: Set<String> = ["os_create", "os_update", "os_delete", "os_action", "os_attach", "os_detach"]
        if mutatingTools.contains(params.name) && !hasWrite {
            return CallTool.Result(
                content: [.text(text: errorParagraph(
                    OpenStackError(service: "mcp", status: 403, code: "insufficient_scope", message: "Tool \(params.name) requires write scope"),
                    what: "Calling \(params.name)"
                ), metadata: nil)],
                isError: true
            )
        }

        do {
            switch params.name {
            case "os_list": return try await handleList(params)
            case "os_get": return try await handleGet(params)
            case "os_describe": return try await handleDescribe(params)
            case "os_whoami": return try await handleWhoami(params)
            case "os_clouds": return try await handleClouds(params)
            case "os_quota": return try await handleQuota(params)
            case "os_find": return try await handleFind(params)
            case "os_topology": return try await handleTopology(params)
            case "os_wait": return try await handleWait(params, server: server)
            case "os_create": return try await handleCreate(params)
            case "os_update": return try await handleUpdate(params)
            case "os_delete": return try await handleDelete(params)
            case "os_action": return try await handleAction(params)
            case "os_attach": return try await handleLink(params, attach: true, server: server)
            case "os_detach": return try await handleLink(params, attach: false, server: server)
            default:
                return CallTool.Result(
                    content: [.text(text: "Unknown tool: \(params.name). Valid: \(visibleToolNames.joined(separator: ", "))")],
                    isError: true
                )
            }
        } catch let error as OpenStackError {
            return CallTool.Result(
                content: [.text(text: errorParagraph(error, what: "Calling \(params.name)"), annotations: nil, _meta: nil)],
                isError: true
            )
        } catch let error as AmbiguousNameError {
            return CallTool.Result(
                content: [.text(text: error.description, annotations: nil, _meta: nil)],
                isError: true
            )
        } catch {
            return CallTool.Result(
                content: [.text(text: errorParagraph(
                    OpenStackError(service: "mcp", status: 500, message: error.localizedDescription),
                    what: "Calling \(params.name)"
                ), metadata: nil)],
                isError: true
            )
        }
    }

    // MARK: - Helpers

    private func arg(_ params: CallTool.Parameters, _ name: String) -> Value? { params.arguments?[name] }
    private func argString(_ params: CallTool.Parameters, _ name: String) throws -> String {
        guard let v = arg(params, name), let s = v.stringValue else {
            throw OpenStackError(service: "mcp", status: 400, code: "missingParam", message: "Missing required parameter: \(name)")
        }
        return s
    }
    private func argOptional(_ params: CallTool.Parameters, _ name: String) -> String? { arg(params, name)?.stringValue }
    private func argInt(_ params: CallTool.Parameters, _ name: String) -> Int? { arg(params, name)?.intValue }
    private func argBool(_ params: CallTool.Parameters, _ name: String) -> Bool { arg(params, name)?.boolValue ?? false }
    private func argObject(_ params: CallTool.Parameters, _ name: String) -> [String: Value]? { arg(params, name)?.objectValue }
    private func argStringArray(_ params: CallTool.Parameters, _ name: String) -> [String]? {
        arg(params, name)?.arrayValue?.compactMap { $0.stringValue }
    }

    private func resolveRegion(_ params: CallTool.Parameters) async throws -> String {
        if let region = argOptional(params, "region"), !region.isEmpty { return region }
        return try await client.defaultRegion(identity.vt)
    }

    private func getDescriptor(_ params: CallTool.Parameters) throws -> ResourceDescriptor {
        let resourceName = try argString(params, "resource")
        guard let d = catalog.descriptor(resourceName) else {
            throw OpenStackError(service: "mcp", status: 400, code: "unknownResource",
                message: "Unknown resource: \(resourceName). Valid: \(catalog.names.sorted().joined(separator: ", "))")
        }
        return d
    }

    private func toJSONValue(_ value: Value?) -> JSONValue? {
        guard let value else { return nil }
        return convertValue(value)
    }

    private func convertValue(_ value: Value) -> JSONValue {
        if let s = value.stringValue { return .string(s) }
        if let i = value.intValue { return .integer(i) }
        if let d = value.doubleValue { return .float(d) }
        if let b = value.boolValue { return .bool(b) }
        if let arr = value.arrayValue { return .array(arr.map { convertValue($0) }) }
        if let obj = value.objectValue {
            var result: [String: JSONValue] = [:]
            for (k, v) in obj { result[k] = convertValue(v) }
            return .object(result)
        }
        return .null
    }

    func toValue(_ value: JSONValue) -> Value {
        switch value {
        case .string(let s): return .string(s)
        case .integer(let i): return .int(i)
        case .float(let d): return .double(d)
        case .bool(let b): return .bool(b)
        case .null: return .null
        case .array(let arr): return .array(arr.map { toValue($0) })
        case .object(let obj):
            var result: [String: Value] = [:]
            for (k, v) in obj { result[k] = toValue(v) }
            return .object(result)
        }
    }

    private func resultText(_ obj: [String: JSONValue]) -> (String, Value) {
        let val = toValue(.object(obj))
        let data = (try? JSONEncoder().encode(val)) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? val.description
        return (text, val)
    }

    // MARK: - Read handlers

    private func handleList(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let d = try getDescriptor(params)
        let region = try await resolveRegion(params)
        let vt = identity.vt

        let filtersValue = argObject(params, "filters") ?? [:]
        var filters: [String: String] = [:]
        for (k, v) in filtersValue { filters[k] = v.stringValue ?? "" }
        try checkFilters(descriptor: d, filters: filters)

        var limit = argInt(params, "limit")
        if let l = limit, l > policy.maxListLimit { limit = policy.maxListLimit }

        let resolver = NameResolver(catalog: catalog, client: client)
        let raw = try await resolver.listPublic(vt, descriptor: d, filters: filters, limit: limit, marker: argOptional(params, "marker"), region: region)

        let fields = argStringArray(params, "fields") ?? d.defaultListFields
        var items: [[String: JSONValue]] = []
        if let arr = raw["items"]?.arrayValue {
            for item in arr {
                if let obj = item.objectValue { items.append(project(obj, fields)) }
            }
        }

        let result: [String: JSONValue] = [
            "resource": .string(d.name),
            "region": .string(region),
            "count": .integer(items.count),
            "items": .array(items.map { .object($0) }),
        ]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleGet(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let d = try getDescriptor(params)
        let region = try await resolveRegion(params)
        let idOrName = try argString(params, "id_or_name")
        let vt = identity.vt

        let resolver = NameResolver(catalog: catalog, client: client)
        let (id, raw) = try await resolver.resolve(vt, descriptor: d, idOrName: idOrName, region: region)
        let fields = argStringArray(params, "fields")
        let projected = fields != nil ? project(raw, fields!) : raw

        let result: [String: JSONValue] = [
            "resource": .string(d.name),
            "id": .string(id),
            "data": .object(projected),
        ]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleDescribe(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let d = try getDescriptor(params)

        var actions: [[String: JSONValue]] = []
        for a in d.actions {
            actions.append([
                "name": .string(a.name),
                "destructive": .bool(a.destructive),
                "admin_only": .bool(a.adminOnly),
                "params": .array(a.params.map { p in
                    .object(["name": .string(p.name), "type": .string(p.type), "required": .bool(p.required)])
                }),
            ])
        }

        var links: [[String: JSONValue]] = []
        for l in d.links {
            links.append([
                "kind": .string(l.kind),
                "params": .array(l.params.map { p in
                    .object(["name": .string(p.name), "type": .string(p.type), "required": .bool(p.required)])
                }),
            ])
        }

        let result: [String: JSONValue] = [
            "resource": .string(d.name),
            "service": .string(d.service.rawValue),
            "verbs": .array(d.verbs.sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) }),
            "actions": .array(actions.map { .object($0) }),
            "links": .array(links.map { .object($0) }),
            "id_field": .string(d.idField),
            "name_field": .string(d.nameField ?? ""),
            "terminal_states": .array(d.terminalStates.map { .string($0) }),
            "default_list_fields": .array(d.defaultListFields.map { .string($0) }),
            "list_filters": .array(d.listFilters.sorted().map { .string($0) }),
        ]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleWhoami(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let wm = identity.whoami
        let result: [String: JSONValue] = [
            "project": .object(["id": .string(wm.project.id), "name": .string(wm.project.name ?? "")]),
            "domain": .string(wm.domain.name ?? ""),
            "roles": .array(wm.roles.map { .string($0) }),
            "scopes": .array(wm.scopes.map { .string($0.rawValue) }),
            "regions": .array(wm.regions.map { .string($0) }),
            "services": .object(wm.services.mapValues { .array($0.map { .string($0) }) }),
        ]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleClouds(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let vt = identity.vt
        let regions = await client.regions(vt)
        let result: [String: JSONValue] = [
            "regions": .array(regions.map { .string($0) }),
            "services": .object(identity.whoami.services.mapValues { .array($0.map { .string($0) }) }),
        ]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleQuota(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let service = try argString(params, "service")
        let region = try await resolveRegion(params)
        let vt = identity.vt

        let raw: [String: JSONValue]
        switch service {
        case "compute":
            let r = await client.compute(region: region)
            raw = try NameResolver.encodeObject(try await r.getQuotaSet(vt))
        case "network":
            let r = await client.network(region: region)
            raw = try NameResolver.encodeObject(try await r.getQuota(vt))
        case "volume":
            let r = await client.blockStorage(region: region)
            raw = try NameResolver.encodeObject(try await r.getQuota(vt))
        case "image":
            raw = ["note": .string("Image quotas not supported in phase 1")]
        default:
            throw OpenStackError(service: "mcp", status: 400, message: "Unknown service: \(service)")
        }

        let result: [String: JSONValue] = ["service": .string(service), "region": .string(region), "quota": .object(raw)]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleFind(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let value = try argString(params, "value")
        let region = try await resolveRegion(params)
        let vt = identity.vt
        let resourceFilter = argOptional(params, "resource")
        let lower = value.lowercased()
        var matches: [[String: JSONValue]] = []

        let computeNames = Set(catalog.resources(for: .compute).map { $0.name })
        if resourceFilter == nil || computeNames.contains(resourceFilter ?? "") {
            let r = await client.compute(region: region)
            let servers = try await r.listServers(vt, filters: [:], limit: policy.maxListLimit)
            for server in servers {
                if server.name.lowercased().contains(lower) {
                    matches.append(["resource": .string("server"), "id": .string(server.id), "name": .string(server.name), "matched_field": .string("name")])
                }
            }
        }

        let networkNames = Set(catalog.resources(for: .network).map { $0.name })
        if resourceFilter == nil || networkNames.contains(resourceFilter ?? "") {
            let r = await client.network(region: region)
            let ports = try await r.listPorts(vt, filters: [:], limit: policy.maxListLimit)
            for port in ports {
                for ip in port.fixedIPs where ip.ipAddress.lowercased() == lower {
                    matches.append(["resource": .string("port"), "id": .string(port.id), "name": .string(port.name), "matched_field": .string("fixed_ips")])
                }
            }
        }

        let result: [String: JSONValue] = [
            "query": .string(value),
            "count": .integer(matches.count),
            "matches": .array(matches.map { .object($0) }),
        ]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleTopology(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let resourceName = try argString(params, "resource")
        let idOrName = try argString(params, "id_or_name")
        let region = try await resolveRegion(params)
        let depth = argInt(params, "depth") ?? 1
        let diagnosis = argBool(params, "diagnosis")
        var diagnoseProtocol: String?
        var diagnosePort: Int?
        if let d = argObject(params, "diagnose") {
            diagnoseProtocol = d["protocol"]?.stringValue
            diagnosePort = d["port"]?.intValue
        }
        let vt = identity.vt

        let supportedAnchors = ["server", "network", "router", "floating_ip", "subnet", "port"]
        guard supportedAnchors.contains(resourceName) else {
            throw OpenStackError(service: "mcp", status: 400, code: "unsupportedAnchor",
                message: "Unsupported topology anchor: \(resourceName). Supported: \(supportedAnchors.joined(separator: ", "))")
        }

        // Validate the anchor exists as an id; topology also accepts a name
        // for anchors that support it (the builder resolves names where it can).
        if resourceName == "server" {
            _ = try await client.compute(region: region).getServer(vt, id: idOrName)
        }
        let anchorID = idOrName

        let builder = TopologyBuilder(client: client, catalog: catalog, logger: logger)
        let graph = try await builder.build(
            vt,
            anchorResource: resourceName,
            anchorID: anchorID,
            depth: depth,
            diagnosis: diagnosis,
            diagnose: (diagnoseProtocol, diagnosePort),
            region: region
        )

        var result: [String: JSONValue] = [
            "anchor": .object(["resource": .string(resourceName), "id": .string(anchorID)]),
            "region": .string(region),
            "depth": .integer(depth),
            "nodes": .array(graph.nodes.map { .object($0) }),
            "edges": .array(graph.edges.map { .object($0) }),
        ]
        if let findings = graph.findings {
            result["findings"] = .array(findings.map { .string($0) })
        }
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    func handleWait(_ params: CallTool.Parameters, server: MCP.Server) async throws -> CallTool.Result {
        let resourceName = try argString(params, "resource")
        let id = try argString(params, "id")
        let region = try await resolveRegion(params)
        let until = argStringArray(params, "until")
        let timeoutSeconds = argInt(params, "timeout_seconds") ?? 120
        let vt = identity.vt
        let progressToken = params._meta?.progressToken

        let waiter = Waiter(client: client, catalog: catalog, logger: logger)
        let outcome = try await waiter.wait(
            vt,
            resource: resourceName,
            id: id,
            region: region,
            until: until,
            timeout: TimeInterval(timeoutSeconds),
            progressToken: progressToken,
            server: server
        )

        let (text, val) = resultText(outcome)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    // MARK: - Mutation handlers

    private func handleCreate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let d = try getDescriptor(params)
        let region = try await resolveRegion(params)
        let vt = identity.vt
        let dryRun = argBool(params, "dry_run")

        guard let schema = d.createSchema else {
            throw OpenStackError(service: "mcp", status: 400, message: "Resource \(d.name) does not support create")
        }
        guard let spec = toJSONValue(arg(params, "spec")) else {
            throw OpenStackError(service: "mcp", status: 400, message: "Missing spec parameter")
        }
        let issues = schema.validate(spec)
        guard issues.isEmpty else {
            let desc = issues.map { "  \($0.path): expected \($0.expected), found \($0.found) — \($0.fragment)" }
            throw OpenStackError(service: "mcp", status: 400, code: "schemaValidation",
                message: "Spec validation failed:\n" + desc.joined(separator: "\n"))
        }

        if dryRun {
            let result: [String: JSONValue] = ["dry_run": .bool(true), "resource": .string(d.name), "region": .string(region),
                "message": .string("Spec is valid. Resource would be created in \(region).")]
            let (text, val) = resultText(result)
            return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
        }

        let resolver = NameResolver(catalog: catalog, client: client)
        let raw = try await resolver.createPublic(vt, descriptor: d, body: spec, region: region)
        let result: [String: JSONValue] = ["resource": .string(d.name), "region": .string(region), "data": .object(raw)]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let d = try getDescriptor(params)
        let region = try await resolveRegion(params)
        let idOrName = try argString(params, "id_or_name")
        let vt = identity.vt
        let dryRun = argBool(params, "dry_run")

        guard let schema = d.updateSchema else {
            throw OpenStackError(service: "mcp", status: 400, message: "Resource \(d.name) does not support update")
        }
        guard let patch = toJSONValue(arg(params, "patch")) else {
            throw OpenStackError(service: "mcp", status: 400, message: "Missing patch parameter")
        }
        let issues = schema.validate(patch)
        guard issues.isEmpty else {
            let desc = issues.map { "  \($0.path): expected \($0.expected), found \($0.found) — \($0.fragment)" }
            throw OpenStackError(service: "mcp", status: 400, code: "schemaValidation",
                message: "Patch validation failed:\n" + desc.joined(separator: "\n"))
        }

        let resolver = NameResolver(catalog: catalog, client: client)
        let (id, _) = try await resolver.resolve(vt, descriptor: d, idOrName: idOrName, region: region)

        if dryRun {
            let result: [String: JSONValue] = ["dry_run": .bool(true), "resource": .string(d.name), "id": .string(id),
                "region": .string(region), "message": .string("Patch is valid.")]
            let (text, val) = resultText(result)
            return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
        }

        let raw = try await resolver.updatePublic(vt, descriptor: d, id: id, body: patch, region: region)
        let result: [String: JSONValue] = ["resource": .string(d.name), "id": .string(id), "region": .string(region), "data": .object(raw)]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleDelete(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let d = try getDescriptor(params)
        let region = try await resolveRegion(params)
        let idOrName = try argString(params, "id_or_name")
        let vt = identity.vt
        let dryRun = argBool(params, "dry_run")

        let resolver = NameResolver(catalog: catalog, client: client)
        let (id, _) = try await resolver.resolve(vt, descriptor: d, idOrName: idOrName, region: region)

        if dryRun {
            var dependents: [String] = []
            if d.name == "network" {
                let r = await client.network(region: region)
                let ports = try await r.listPorts(vt, filters: ["network_id": id], limit: 100)
                dependents = ports.map { "port \($0.id)" }
            }
            let result: [String: JSONValue] = [
                "dry_run": .bool(true), "resource": .string(d.name), "id": .string(id), "region": .string(region),
                "dependents": .array(dependents.map { .string($0) }),
                "can_delete": .bool(dependents.isEmpty),
            ]
            let (text, val) = resultText(result)
            return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
        }

        _ = try await resolver.deletePublic(vt, descriptor: d, id: id, region: region)
        let result: [String: JSONValue] = ["resource": .string(d.name), "id": .string(id), "region": .string(region), "deleted": .bool(true)]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleAction(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let d = try getDescriptor(params)
        let region = try await resolveRegion(params)
        let idOrName = try argString(params, "id_or_name")
        let actionName = try argString(params, "action")
        let vt = identity.vt

        guard d.actions.contains(where: { $0.name == actionName }) else {
            throw OpenStackError(service: "mcp", status: 400,
                message: "Unknown action: \(actionName) for \(d.name). Valid: \(d.actions.map(\.name).joined(separator: ", "))")
        }

        let paramsValue = argObject(params, "params") ?? [:]
        var actionParams: [String: JSONValue] = [:]
        for (k, v) in paramsValue { actionParams[k] = toJSONValue(v) ?? .null }

        let resolver = NameResolver(catalog: catalog, client: client)
        let (id, _) = try await resolver.resolve(vt, descriptor: d, idOrName: idOrName, region: region)
        let raw = try await resolver.actionPublic(vt, descriptor: d, id: id, action: actionName, params: actionParams, region: region)

        let result: [String: JSONValue] = ["resource": .string(d.name), "id": .string(id), "action": .string(actionName), "region": .string(region), "data": .object(raw)]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    func handleLink(_ params: CallTool.Parameters, attach: Bool, server: MCP.Server) async throws -> CallTool.Result {
        let link = try argString(params, "link")
        let sourceType = try argString(params, "source_type")
        let source = try argString(params, "source")
        let targetType = try argString(params, "target_type")
        let target = try argString(params, "target")
        let region = try await resolveRegion(params)
        let wait = argBool(params, "wait")
        let vt = identity.vt

        var linkParams: [String: JSONValue] = [:]
        if let p = argObject(params, "params") {
            for (k, v) in p { linkParams[k] = toJSONValue(v) ?? .null }
        }

        // Validate the link against the catalog
        guard catalog.allLinks[link] != nil else {
            throw OpenStackError(service: "mcp", status: 400, code: "unknownLink",
                message: "Unknown link: \(link). Valid: \(catalog.allLinks.keys.sorted().joined(separator: ", "))")
        }

        let executor = LinkExecutor(client: client, catalog: catalog, waiter: Waiter(client: client, catalog: catalog, logger: logger), logger: logger)
        let result: [String: JSONValue]
        if attach {
            result = try await executor.attach(vt, link: link, sourceType: sourceType, source: source, targetType: targetType, target: target, params: linkParams, region: region, wait: wait)
        } else {
            result = try await executor.detach(vt, link: link, sourceType: sourceType, source: source, targetType: targetType, target: target, region: region, wait: wait)
        }

        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }
}
