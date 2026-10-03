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

/// The tool registry: maps the MCP tools to OpenStack client calls.
///
/// Two families:
/// - **15 verb tools** (the stable, additive-only set: os_list, os_get, …)
/// - **3 task-lifecycle tools** (os_task_submit/status/cancel, the Path C shim
///   for long-running waits; read-scoped)
///
/// The registry is scope-aware: a read-only token gets the 9 read verbs + the 3
/// task tools (12); a write-scoped token gets all 15 verbs + the 3 task tools
/// (18).
public struct ToolRegistry: Sendable {
    /// How write scope is enforced (spec §6.1.2 / P2 per-service scopes).
    public enum ScopeMode: Sendable {
        /// Coarse (default): a token with `openstack:write` may mutate any
        /// service. This is the phase-1 behavior.
        case coarse
        /// Per-service (P2): a token with `openstack:write` may mutate only
        /// services present in its own token catalog.
        case perService
    }

    public let client: OpenStackClient
    public let catalog: ResourceCatalog
    public let policy: Policy
    public let identity: RequestIdentity
    /// The scope-enforcement mode (default `coarse` = phase-1 behavior).
    public let scopeMode: ScopeMode
    public let logger: Logger
    /// Whether to emit one audit log line per mutating tool call (spec §12,
    /// gated by `log.audit`, default true).
    public let auditEnabled: Bool
    /// Per-identity (per-token) sliding-window tool-call rate limiter
    /// (spec §12: `policy.max_calls_per_minute`, default 120/min).
    public let callLimiter: ToolCallLimiter
    /// Server-scoped store for the `os_task_*` shim (MCP Tasks, Path C).
    /// Shared by every per-identity registry on the server; keyed by token id
    /// internally so each token sees only its own tasks. Defaults to the
    /// process-wide shared instance so existing constructions/tests are
    /// unaffected; the serve path passes a server-scoped one.
    public let taskRegistry: TaskRegistry

    public init(
        client: OpenStackClient,
        catalog: ResourceCatalog,
        policy: Policy = Policy(),
        identity: RequestIdentity,
        scopeMode: ScopeMode = .coarse,
        logger: Logger = Logger(label: "substation-mcp"),
        auditEnabled: Bool = true,
        callLimiter: ToolCallLimiter? = nil,
        taskRegistry: TaskRegistry? = nil
    ) {
        self.client = client
        self.catalog = policy.effective(catalog)
        self.policy = policy
        self.identity = identity
        self.scopeMode = scopeMode
        self.logger = logger
        self.auditEnabled = auditEnabled
        // A limiter that never throttles (limit far above any real usage) is
        // the default so existing constructions/tests are unaffected; the
        // serve path passes a real one sized to `policy.maxCallsPerMinute`.
        self.callLimiter = callLimiter ?? ToolCallLimiter(limitPerMinute: .max)
        // A task store that persists for the process lifetime is the default;
        // the serve path passes a server-scoped one so tasks survive the
        // per-identity registry being re-created on each request.
        self.taskRegistry = taskRegistry ?? TaskRegistry.shared
    }

    /// In `perService` mode, the set of catalog service types the token may
    /// write to. In `coarse` mode this is unused.
    private var allowedWriteServices: Set<String> {
        Set(identity.vt.token.catalog.map(\.type))
    }

    /// The per-service scope enforcement for a mutating tool call (P2, spec
    /// §6.1.2). Returns an `insufficient_scope` error when the call targets a
    /// service absent from the token's catalog, or `nil` to allow. In `coarse`
    /// mode this always returns `nil` (phase-1 behavior).
    func serviceScopeError(tool: String, params: CallTool.Parameters) -> OpenStackError? {
        guard scopeMode == .perService else { return nil }

        /// The service for a `resource`/`*_type` argument, when it names a
        /// known catalog resource.
        func serviceFor(_ key: String) -> Service? {
            guard let name = argOptional(params, key) else { return nil }
            return catalog.descriptor(name)?.service
        }

        let targetServices: [Service]
        switch tool {
        case "os_create", "os_update", "os_delete", "os_action":
            targetServices = serviceFor("resource").map { [$0] } ?? []
        case "os_attach", "os_detach":
            targetServices = [serviceFor("source_type"), serviceFor("target_type")].compactMap { $0 }
        default:
            return nil
        }

        let allowed = allowedWriteServices
        let denied = targetServices.filter { !allowed.contains($0.serviceTypeName) }
        guard !denied.isEmpty else { return nil }
        let names = denied.map { "\($0.serviceTypeName):write" }
        return OpenStackError(
            service: "mcp", status: 403, code: "insufficient_scope",
            message: "Tool \(tool) requires \(names.joined(separator: ", ")); the token's catalog does not include \(denied.map(\.serviceTypeName).joined(separator: ", "))"
        )
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
            "os_task_submit", "os_task_status", "os_task_cancel",
            "os_create", "os_update", "os_delete", "os_action",
            "os_attach", "os_detach",
        ]
    }

    /// Build the MCP `Server` with all tool handlers registered.
    public func makeServer() async -> MCP.Server {
        let server = MCP.Server(
            name: "substation-mcp",
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
        let visible = Set(visibleToolNames)
        return AllTools.tools(catalog: catalog).filter { visible.contains($0.name) }
    }

    // MARK: - Dispatch

    func dispatch(_ params: CallTool.Parameters, server: MCP.Server) async throws -> CallTool.Result {
        let mutatingTools: Set<String> = ["os_create", "os_update", "os_delete", "os_action", "os_attach", "os_detach"]
        let isMutating = mutatingTools.contains(params.name)

        // spec §12: per-identity tool-call rate limit. A throttled call is a
        // self-correctable tool error (isError), not a hard HTTP 429.
        guard await callLimiter.allow(tokenID: identity.vt.token.id) else {
            OSMetrics.toolCall(tool: params.name, outcome: "rate_limited")
            return CallTool.Result(
                content: [.text(text: "Rate limit exceeded: too many tool calls this minute (\(policy.maxCallsPerMinute) allowed). Please wait a moment and retry.", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        if isMutating && !hasWrite {
            OSMetrics.toolCall(tool: params.name, outcome: "forbidden")
            return CallTool.Result(
                content: [.text(text: errorParagraph(
                    OpenStackError(service: "mcp", status: 403, code: "insufficient_scope", message: "Tool \(params.name) requires write scope"),
                    what: "Calling \(params.name)"
                ), annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // P2 per-service scopes: a write-scoped token may mutate only services
        // present in its own catalog (no-op in `coarse` mode).
        if isMutating, hasWrite, let scopeErr = serviceScopeError(tool: params.name, params: params) {
            OSMetrics.toolCall(tool: params.name, outcome: "forbidden")
            return CallTool.Result(
                content: [.text(text: errorParagraph(scopeErr, what: "Calling \(params.name)"), annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // spec §12: measure every tool call; audit only the mutating ones.
        let start = DispatchTime.now()

        let outcome: (result: CallTool.Result, requestID: String?)
        do {
            switch params.name {
            case "os_list": outcome = (try await handleList(params), nil)
            case "os_get": outcome = (try await handleGet(params), nil)
            case "os_describe": outcome = (try await handleDescribe(params), nil)
            case "os_whoami": outcome = (try await handleWhoami(params), nil)
            case "os_clouds": outcome = (try await handleClouds(params), nil)
            case "os_quota": outcome = (try await handleQuota(params), nil)
            case "os_find": outcome = (try await handleFind(params), nil)
            case "os_topology": outcome = (try await handleTopology(params), nil)
            case "os_wait": outcome = (try await handleWait(params, server: server), nil)
            case "os_task_submit": outcome = (try await handleTaskSubmit(params), nil)
            case "os_task_status": outcome = (try await handleTaskStatus(params), nil)
            case "os_task_cancel": outcome = (try await handleTaskCancel(params), nil)
            case "os_create": outcome = (try await handleCreate(params), nil)
            case "os_update": outcome = (try await handleUpdate(params), nil)
            case "os_delete": outcome = (try await handleDelete(params), nil)
            case "os_action": outcome = (try await handleAction(params), nil)
            case "os_attach": outcome = (try await handleLink(params, attach: true, server: server), nil)
            case "os_detach": outcome = (try await handleLink(params, attach: false, server: server), nil)
            default:
                outcome = (CallTool.Result(
                    content: [.text(text: "Unknown tool: \(params.name). Valid: \(visibleToolNames.joined(separator: ", "))", annotations: nil, _meta: nil)],
                    isError: true
                ), nil)
            }
        } catch let error as OpenStackError {
            outcome = (CallTool.Result(
                content: [.text(text: errorParagraph(error, what: "Calling \(params.name)"), annotations: nil, _meta: nil)],
                isError: true
            ), error.requestID)
        } catch let error as AmbiguousNameError {
            outcome = (CallTool.Result(
                content: [.text(text: error.description, annotations: nil, _meta: nil)],
                isError: true
            ), nil)
        } catch {
            outcome = (CallTool.Result(
                content: [.text(text: errorParagraph(
                    OpenStackError(service: "mcp", status: 500, message: error.localizedDescription),
                    what: "Calling \(params.name)"
                ), annotations: nil, _meta: nil)],
                isError: true
            ), nil)
        }

        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        let result = outcome.result
        let ok = result.isError != true
        OSMetrics.toolCall(tool: params.name, outcome: ok ? "ok" : "error")
        OSMetrics.toolDuration(tool: params.name, seconds: seconds)

        if isMutating && auditEnabled {
            emitAudit(tool: params.name, outcome: ok ? "ok" : "error", requestID: outcome.requestID)
        }
        return result
    }

    /// Emit one audit record per mutating tool call (spec §12). The line carries
    /// the token id (not the credential), the project id, the tool, the target
    /// resource + id when present, the outcome, and the OpenStack request id.
    private func emitAudit(tool: String, outcome: String, requestID: String?) {
        var meta: [String: Logger.MetadataValue] = [
            "category": .string("audit"),
            "token": .string(identity.vt.token.id),
            "project": .string(identity.whoami.project.id),
            "tool": .string(tool),
            "outcome": .string(outcome)
        ]
        if let cred = identity.whoami.credentialName { meta["app_credential"] = .string(cred) }
        if let rid = requestID { meta["request_id"] = .string(rid) }
        logger.info("audit: \(tool) \(outcome)", metadata: meta)
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
        return await client.defaultRegion(identity.vt)
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
        // spec §12: servers never expose `user_data` (it is accepted on create
        // but must not be echoed back in a read). Strip it at the result
        // formatter, regardless of projection.
        var projected = fields != nil ? project(raw, fields!) : raw
        if d.name == "server" {
            projected["user_data"] = nil
        }

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

    // MARK: - Task shim handlers (MCP Tasks, Path C)

    /// Start a background wait and return a `task_id` immediately.
    private func handleTaskSubmit(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let resourceName = try argString(params, "resource")
        let id = try argString(params, "id")
        let region = try await resolveRegion(params)
        let until = argStringArray(params, "until")
        let timeoutSeconds = argInt(params, "timeout_seconds") ?? 120
        let vt = identity.vt
        let tokenID = vt.token.id
        let taskRegistry = self.taskRegistry

        // Validate up front (same rules os_wait uses) so a bad call fails
        // fast with a 4xx instead of spawning a task that immediately dies.
        guard let descriptor = catalog.descriptor(resourceName) else {
            throw OpenStackError(
                service: "mcp", status: 400, code: "unknownResource",
                message: "Unknown resource: \(resourceName). Valid: \(catalog.names.sorted().joined(separator: ", "))"
            )
        }
        // Validate `until` against known states (mirror Waiter.validStates).
        if let until, !until.isEmpty {
            var known = Set(descriptor.terminalStates)
            known.insert("ERROR"); known.insert("killed")
            let bad = until.filter { !known.contains($0) }
            guard bad.isEmpty else {
                throw OpenStackError(
                    service: "mcp", status: 400, code: "invalidState",
                    message: "Unknown state(s) \(bad.joined(separator: ", ")). Valid states for \(resourceName): \(Array(known).sorted().joined(separator: ", "))"
                )
            }
        }

        let taskID = await taskRegistry.submit(
            tokenID: tokenID, resource: resourceName, resourceID: id, region: region
        )

        // Snapshot the current status so the submit response is informative
        // without blocking on the settle. Best-effort: a fetch failure just
        // means we report no initial status.
        let waiter = Waiter(client: client, catalog: catalog, logger: logger)
        var initialStatus: String?
        do {
            initialStatus = try await waiter.probeStatus(vt, descriptor: descriptor, id: id, region: region)
        } catch {
            initialStatus = nil
        }

        // Spawn the background poll. It writes its terminal state back into the
        // store; cancellation is handled by the store holding the Task handle.
        // `waiter` (a Sendable struct) is captured by value, as is client/
        // catalog/logger — no mutable self is retained.
        let handle = Task { [waiter] in
            let start = Date()
            do {
                let result = try await waiter.wait(
                    vt, resource: resourceName, id: id, region: region,
                    until: until, timeout: TimeInterval(timeoutSeconds),
                    progressToken: nil, server: nil
                )
                let status = result["status"]?.stringValue ?? ""
                await taskRegistry.complete(
                    tokenID: tokenID, taskID: taskID, state: .succeeded,
                    lastStatus: status,
                    elapsedSeconds: (Date().timeIntervalSince(start) * 10).rounded() / 10,
                    polls: result["polls"]?.intValue,
                    result: result, message: nil
                )
            } catch let e as OpenStackError {
                let state: TaskState = e.code == "timeout" ? .timedOut : .failed
                // A 404 "no longer exists" during a wait means the resource
                // vanished; surface that as a "deleted" status. Otherwise the
                // error text (in `message`) is the full detail.
                let lastStatus: String? = (e.status == 404) ? "deleted" : nil
                await taskRegistry.complete(
                    tokenID: tokenID, taskID: taskID, state: state,
                    lastStatus: lastStatus,
                    elapsedSeconds: (Date().timeIntervalSince(start) * 10).rounded() / 10,
                    polls: nil, result: nil, message: e.message
                )
            } catch {
                await taskRegistry.complete(
                    tokenID: tokenID, taskID: taskID, state: .failed,
                    lastStatus: nil,
                    elapsedSeconds: (Date().timeIntervalSince(start) * 10).rounded() / 10,
                    polls: nil, result: nil, message: error.localizedDescription
                )
            }
        }
        await taskRegistry.attachHandle(handle, for: taskID)

        let result: [String: JSONValue] = [
            "task_id": .string(taskID),
            "resource": .string(resourceName),
            "id": .string(id),
            "region": .string(region),
            "state": .string("running"),
            "current_status": .string(initialStatus ?? ""),
            "timeout_seconds": .integer(timeoutSeconds),
            "note": .string("Task started. Poll with os_task_status(task_id); stop with os_task_cancel(task_id)."),
        ]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleTaskStatus(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let taskID = try argString(params, "task_id")
        let tokenID = identity.vt.token.id
        guard let entry = await taskRegistry.status(tokenID: tokenID, taskID: taskID) else {
            throw OpenStackError(service: "mcp", status: 404, code: "unknownTask",
                message: "Unknown task: \(taskID). Tasks are scoped to the presenting token and expire after a short TTL once terminal.")
        }
        var result: [String: JSONValue] = [
            "task_id": .string(entry.taskID),
            "state": .string(entry.state.rawValue),
            "resource": .string(entry.resource),
            "id": .string(entry.resourceID),
            "region": .string(entry.region),
        ]
        if let s = entry.lastStatus { result["status"] = .string(s) }
        if let e = entry.elapsedSeconds { result["elapsedSeconds"] = .float(e) }
        if let p = entry.polls { result["polls"] = .integer(p) }
        if let msg = entry.message { result["message"] = .string(msg) }
        if let r = entry.result { result["result"] = .object(r) }
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleTaskCancel(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let taskID = try argString(params, "task_id")
        let tokenID = identity.vt.token.id
        guard let state = await taskRegistry.cancel(tokenID: tokenID, taskID: taskID) else {
            throw OpenStackError(service: "mcp", status: 404, code: "unknownTask",
                message: "Cannot cancel task: \(taskID). Unknown, foreign to this token, or already terminal.")
        }
        let result: [String: JSONValue] = [
            "task_id": .string(taskID),
            "state": .string(state.rawValue),
            "message": .string("Task cancelled."),
        ]
        let (text, val) = resultText(result)
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
