import Foundation
import MCP
import OpenStackClient
import Provisioning
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
    /// (spec §12: `policy.max_calls_per_minute`, default 1024/min).
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
            "os_find", "os_whoami", "os_quota", "os_clouds", "os_wait", "os_project_readiness", "os_recommend_flavor",
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
            case "os_project_readiness": outcome = (try await handleProjectReadiness(params), nil)
            case "os_recommend_flavor": outcome = (try await handleRecommendFlavor(params), nil)
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
            // Log unexpected (non-OpenStack) errors so decode failures are
            // visible in pod logs instead of silently wrapping into a 500.
            logger.error("Tool call failed with unexpected error", metadata: [
                "tool": "\(params.name)",
                "error": "\(error)",
            ])
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

    func arg(_ params: CallTool.Parameters, _ name: String) -> Value? { params.arguments?[name] }
    private func argString(_ params: CallTool.Parameters, _ name: String) throws -> String {
        guard let v = arg(params, name), let s = v.stringValue else {
            throw OpenStackError(service: "mcp", status: 400, code: "missingParam", message: "Missing required parameter: \(name)")
        }
        return s
    }
    func argOptional(_ params: CallTool.Parameters, _ name: String) -> String? { arg(params, name)?.stringValue }
    func argInt(_ params: CallTool.Parameters, _ name: String) -> Int? { arg(params, name)?.intValue }
    /// Read the wait timeout in seconds. `timeout_seconds` is the documented
    /// parameter; `timeout` is a convenience alias so a client sending the
    /// shorter name still gets an honored value instead of a silent ignore.
    private func argTimeoutSeconds(_ params: CallTool.Parameters) -> Int {
        argInt(params, "timeout_seconds") ?? argInt(params, "timeout") ?? 120
    }
    private func argBool(_ params: CallTool.Parameters, _ name: String) -> Bool { arg(params, name)?.boolValue ?? false }
    private func argObject(_ params: CallTool.Parameters, _ name: String) -> [String: Value]? { arg(params, name)?.objectValue }
    private func argStringArray(_ params: CallTool.Parameters, _ name: String) -> [String]? {
        arg(params, name)?.arrayValue?.compactMap { $0.stringValue }
    }

    func resolveRegion(_ params: CallTool.Parameters) async throws -> String {
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

    func resultText(_ obj: [String: JSONValue]) -> (String, Value) {
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

        var result: [String: JSONValue] = [
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
        if let cs = d.createSchema {
            result["create_schema"] = cs.jsonValue()
        }
        if let us = d.updateSchema {
            result["update_schema"] = us.jsonValue()
        }
        if let note = d.phase1Note {
            result["note"] = .string(note)
        }
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

        // Per-region capability matrix: volume types, AZs, flavor count, public
        // networks. Each query is best-effort (try?) — a missing service endpoint
        // in a region omits that field rather than failing the whole call.
        var capabilities: [[String: JSONValue]] = []
        for region in regions {
            async let csTask = client.compute(region: region)
            async let bsTask = client.blockStorage(region: region)
            async let nsTask = client.network(region: region)
            let cs = await csTask
            let bs = await bsTask
            let ns = await nsTask

            let vts = try? await bs.listVolumeTypes(vt)
            let azs = try? await cs.listAvailabilityZones(vt)
            let flavors = try? await cs.listFlavors(vt)
            let nets = try? await ns.listNetworks(vt, filters: [:], limit: 200)

            var entry: [String: JSONValue] = ["region": .string(region)]
            // Always emit volume_types (empty array when Cinder /types is unreachable or member role lacks it) so the field doesn't silently vanish from the capability entry.
            entry["volume_types"] = .array((vts ?? []).map { .string($0.name) })
            if let azs, !azs.isEmpty {
                entry["availability_zones"] = .array(azs.map { .string($0.zoneName) })
            }
            if let flavors {
                entry["flavor_count"] = .integer(flavors.count)
            }
            if let nets {
                let publicNames = nets.filter { $0.routerExternal }.map { $0.name }
                if !publicNames.isEmpty {
                    entry["public_networks"] = .array(publicNames.map { .string($0) })
                }
            }
            capabilities.append(entry)
        }

        let result: [String: JSONValue] = [
            "regions": .array(regions.map { .string($0) }),
            "services": .object(identity.whoami.services.mapValues { .array($0.map { .string($0) }) }),
            "capabilities": .array(capabilities.map { .object($0) }),
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

        // Catalog-driven search: for every listable resource that has a name
        // field, match items whose nameField contains the value (case-insensitive).
        // This is what makes os_find work for flavor/network/router/subnet/etc.,
        // not just servers. The port fixed_ips branch below adds IP lookups on
        // top (IPs aren't names and don't flow through nameField).
        var targets = catalog.resources.filter { $0.verbs.contains(.list) && $0.nameField != nil }
        if let filter = resourceFilter {
            // Restrict to the one requested resource when given; fail loudly if
            // it's not a valid, listable, named resource.
            guard let d = catalog.descriptor(filter), d.verbs.contains(.list), d.nameField != nil else {
                throw OpenStackError(service: "mcp", status: 400, code: "invalidResource",
                    message: "Resource '\(filter)' is not searchable by os_find.")
            }
            targets = [d]
        }

        let resolver = NameResolver(catalog: catalog, client: client)
        var matches: [[String: JSONValue]] = []

        // Search each target resource in parallel so a broad find stays fast
        // even though it fans out over many services.
        let found = try await withThrowingTaskGroup(of: [[String: JSONValue]].self) { group in
            for d in targets {
                group.addTask { () -> [[String: JSONValue]] in
                    guard let nameField = d.nameField else { return [] }
                    do {
                        let raw = try await resolver.listPublic(vt, descriptor: d, filters: [:], limit: policy.maxListLimit, marker: nil, region: region)
                        var out: [[String: JSONValue]] = []
                        if let arr = raw["items"]?.arrayValue {
                            for item in arr {
                                guard let obj = item.objectValue else { continue }
                                guard let name = obj[nameField]?.stringValue, name.lowercased().contains(lower) else { continue }
                                let id = obj[d.idField]?.stringValue ?? ""
                                out.append([
                                    "resource": .string(d.name),
                                    "id": .string(id),
                                    "name": .string(name),
                                    "matched_field": .string("name"),
                                ])
                            }
                        }
                        return out
                    } catch {
                        // A single service being absent/denied/down must not sink
                        // the whole find; skip it and report the rest.
                        return []
                    }
                }
            }
            var acc: [[String: JSONValue]] = []
            for try await chunk in group { acc.append(contentsOf: chunk) }
            return acc
        }
        matches.append(contentsOf: found)

        // IP / address lookup against neutron ports (fixed_ips), preserved from
        // the original behavior: os_find(value=<ip>) locates the port holding it.
        // Only run when the filter doesn't narrow us away from network.
        if resourceFilter == nil || resourceFilter == "port" {
            do {
                let r = await client.network(region: region)
                let ports = try await r.listPorts(vt, filters: [:], limit: policy.maxListLimit)
                for port in ports {
                    for ip in port.fixedIPs where ip.ipAddress.lowercased() == lower {
                        matches.append(["resource": .string("port"), "id": .string(port.id), "name": .string(port.name), "matched_field": .string("fixed_ips")])
                    }
                }
            } catch {
                // Port scan is best-effort; ignore on failure.
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

        // Resolve the anchor to a canonical ID. Nova's GET /servers/{id}
        // requires an actual UUID — passing a name returns 404. For servers,
        // we resolve the name via NameResolver (listServers name filter)
        // before building the topology graph. Other anchor types (network,
        // router, etc.) already resolve names inside the TopologyBuilder.
        var anchorID = idOrName
        if resourceName == "server" {
            do {
                // Try exact ID first
                _ = try await client.compute(region: region).getServer(vt, id: idOrName)
            } catch {
                // Not an ID — resolve by name via the NameResolver
                let resolver = NameResolver(catalog: catalog, client: client)
                guard let descriptor = catalog.descriptor("server") else {
                    throw OpenStackError(service: "mcp", status: 500, message: "Server descriptor not found in catalog")
                }
                let resolved = try await resolver.resolve(
                    vt, descriptor: descriptor, idOrName: idOrName, region: region
                )
                anchorID = resolved.id
            }
        }

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
        let timeoutSeconds = argTimeoutSeconds(params)
        // By default a wait that outlives the short sync window hands off to a
        // background task instead of holding the HTTP request open past the
        // client's own request timeout (which would surface as an opaque
        // transport failure). Pass async_on_timeout=false to force a fully
        // synchronous wait (and get a hard timeout error on overrun).
        let allowHandoff = arg(params, "async_on_timeout")?.boolValue ?? true
        let vt = identity.vt
        let progressToken = params._meta?.progressToken

        let waiter = Waiter(client: client, catalog: catalog, logger: logger)
        // Bounded synchronous attempt: settle within this window returns
        // inline; exceed it and (when allowed) hand off to a background task.
        // Keep the window comfortably under common client HTTP timeouts so the
        // slow path is caught before the client gives up.
        let syncGrace = TimeInterval(min(timeoutSeconds, 20))
        do {
            let outcome = try await waiter.wait(
                vt,
                resource: resourceName,
                id: id,
                region: region,
                until: until,
                timeout: syncGrace,
                progressToken: progressToken,
                server: server
            )
            let (text, val) = resultText(outcome)
            return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
        } catch let e as OpenStackError where e.code == "timeout" {
            // Hand off only when allowed; otherwise rethrow the timeout.
            if allowHandoff {
                // Spawn a background task for the FULL requested window.
                let taskID = await spawnBackgroundWait(
                    vt: vt, resourceName: resourceName, id: id, region: region,
                    until: until, timeoutSeconds: timeoutSeconds
                )
                let result: [String: JSONValue] = [
                    "task_id": .string(taskID),
                    "resource": .string(resourceName),
                    "id": .string(id),
                    "region": .string(region),
                    "state": .string("running"),
                    "handed_off": .bool(true),
                    "reason": .string("The resource did not reach its target within \(Int(syncGrace))s of synchronous waiting."),
                    "timeout_seconds": .integer(timeoutSeconds),
                    "note": .string("Continuing in the background. Poll os_task_status(task_id) until state is terminal (succeeded/failed/timed_out); stop with os_task_cancel(task_id). No work was lost."),
                ]
                let (text, val) = resultText(result)
                return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
            }
            // Synchronous forced (async_on_timeout explicitly false): rethrow the
            // original timeout so the caller sees the exact bound they set.
            throw e
        }
    }

    // MARK: - Background wait spawning (shared by os_task_submit + os_wait handoff)

    /// Spawns a background poll for `resource`/`id` via the task registry and
    /// returns the freshly-submitted `task_id`. The poll runs detached: it
    /// writes its terminal state into the task store, so callers can return to
    /// their client immediately and let a slow settle outlive any HTTP request
    /// timeout. Used verbatim by `os_task_submit` and by `os_wait`'s
    /// sync→background handoff.
    private func spawnBackgroundWait(
        vt: ValidatedToken,
        resourceName: String,
        id: String,
        region: String,
        until: [String]?,
        timeoutSeconds: Int
    ) async -> String {
        let tokenID = vt.token.id
        let taskID = await taskRegistry.submit(
            tokenID: tokenID, resource: resourceName, resourceID: id, region: region
        )
        let waiter = Waiter(client: client, catalog: catalog, logger: logger)
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
        return taskID
    }

    // MARK: - Task shim handlers (MCP Tasks, Path C)

    /// Start a background wait and return a `task_id` immediately.
    private func handleTaskSubmit(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let resourceName = try argString(params, "resource")
        let id = try argString(params, "id")
        let region = try await resolveRegion(params)
        let until = argStringArray(params, "until")
        let timeoutSeconds = argTimeoutSeconds(params)
        let vt = identity.vt

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

        let taskID = await spawnBackgroundWait(
            vt: vt, resourceName: resourceName, id: id, region: region,
            until: until, timeoutSeconds: timeoutSeconds
        )

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

        if dryRun && d.name == "server" {
            // Server dry run: validate all prerequisites (network, flavor,
            // image, keypair, volume quota) without calling Nova. Returns a
            // structured {valid, errors, warnings} result so the caller can
            // fix every problem in one pass.
            let resolver = NameResolver(catalog: catalog, client: client)
            let validation = try await resolver.createPublic(vt, descriptor: d, body: spec, region: region, dryRun: true)
            var result: [String: JSONValue] = ["dry_run": .bool(true), "resource": .string(d.name), "region": .string(region)]
            for (k, v) in validation { result[k] = v }
            // For a server with a `provisioning` block, surface the rendered
            // cloud-init so the caller can preview the exact user_data Nova
            // would receive, plus the correlation sha.
            if case .object(let obj) = spec, case .object(let provObj)? = obj["provisioning"] {
                if obj["user_data"] != nil {
                    throw OpenStackError(service: "compute", status: 400, code: "provisioningConflict",
                        message: "Server create: `user_data` and `provisioning` are mutually exclusive. Provide exactly one.")
                }
                do {
                    let specP = try ProvisioningSpec.from(dict: NameResolver.anyDictionary(provObj))
                    guard !specP.isEmpty else {
                        throw OpenStackError(service: "compute", status: 400, code: "provisioningEmpty",
                            message: "Provisioning spec is empty (dry run).")
                    }
                    let distro: Distro
                    let imageRef = obj["image"]?.stringValue ?? obj["imageID"]?.stringValue
                    let img: Image?
                    if let imageRef {
                        let ri = await client.image(region: region)
                        if let byId = try? await ri.getImage(vt, id: imageRef) {
                            img = byId
                        } else {
                            let items = (try? await ri.listImages(vt)) ?? []
                            let lower = imageRef.lowercased()
                            img = items.first { $0.id == imageRef || $0.name.lowercased() == lower }
                        }
                    } else {
                        img = nil
                    }
                    if let img {
                        distro = Distro.detect(name: img.name, tags: img.tags.isEmpty ? nil : img.tags,
                                               properties: img.properties.isEmpty ? nil : img.properties)
                    } else {
                        distro = .unknown
                    }
                    let yaml = try CloudInitRenderer.render(spec: specP, distro: distro)
                    result["provisioning_sha"] = .string(specP.sha)
                    result["provisioning_distro"] = .string("\(distro.name)/\(distro.family.rawValue)")
                    result["rendered_user_data"] = .string(yaml)
                    result["rendered_user_data_base64"] = .string(Data(yaml.utf8).base64EncodedString())
                } catch let e as Provisioning.CloudInitRenderer.RenderError {
                    throw OpenStackError(service: "compute", status: 400, code: "provisioningRender",
                        message: e.description)
                } catch let e as Provisioning.RenderDecodingError {
                    throw OpenStackError(service: "compute", status: 400, code: "provisioningInvalid",
                        message: e.description)
                }
            }
            let (text, val) = resultText(result)
            return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
        }

        if dryRun {
            var result: [String: JSONValue] = ["dry_run": .bool(true), "resource": .string(d.name), "region": .string(region),
                "message": .string("Spec is valid. Resource would be created in \(region).")]
            let (text, val) = resultText(result)
            return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
        }
        let resolver = NameResolver(catalog: catalog, client: client)
        let raw = try await resolver.createPublic(vt, descriptor: d, body: spec, region: region, dryRun: dryRun)
        var result: [String: JSONValue] = ["resource": .string(d.name), "region": .string(region), "data": .object(raw)]
        if let nextSteps = Self.nextStepsForCreate(resource: d.name, spec: spec, data: raw) {
            result["next_steps"] = .array(nextSteps.map { .string($0) })
        }
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

        var out = result
        if attach, let nextSteps = Self.nextStepsForAttach(link: link) {
            out["next_steps"] = .array(nextSteps.map { .string($0) })
        }

        let (text, val) = resultText(out)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    // MARK: - Next-step hints

    /// Contextual follow-up instructions for a successful `os_create`, keyed by
    /// resource type. Returns `nil` when the resource has no known next steps so
    /// the field is omitted entirely from the response. Placeholders like
    /// `<id>` are filled from the create result where available; the LLM harness
    /// substitutes them with the values in `data`.
    private static func nextStepsForCreate(resource: String, spec: JSONValue, data: [String: JSONValue]) -> [String]? {
        switch resource {
        case "network":
            return [
                "Create a subnet on this network: os_create(subnet, {name, network_id: <this network's id>, cidr})",
                "Create a router: os_create(router, {name, external_gateway_info})"
            ]
        case "subnet":
            return [
                "Attach to router: os_attach(link:router_interface, source=<router>, target=<subnet-id>)"
            ]
        case "router":
            return [
                "Attach private subnet: os_attach(link:router_interface, source=<router-id>, target=<subnet>)"
            ]
        case "server":
            var steps = ["Wait for ACTIVE: os_wait(server, <id>)"]
            if case .object(let obj) = spec, case .object(let provObj)? = obj["provisioning"], !provObj.isEmpty {
                steps.append("Verify provisioning: os_action(server, <name>, provisioning_status)")
            }
            return steps
        case "volume":
            if case .object(let obj) = spec, obj["imageRef"] != nil {
                return ["Use as boot volume: os_create(server, {volumes: [{volume_id: <id>, boot: true}]})"]
            }
            return nil
        case "floating_ip":
            return [
                "Associate with server: os_attach(link:floating_ip, source=<fip-id>, target=<server>)"
            ]
        case "keypair":
            let name = data["name"]?.stringValue ?? "<name>"
            return [
                "Reference in server create: os_create(server, {key_name: \"\(name)\"})"
            ]
        case "security_group":
            return [
                "Add rules: os_create(security_group_rule, {security_group_id: <id>, direction: ingress, ...})"
            ]
        default:
            return nil
        }
    }

    /// Contextual follow-up instructions for a successful `os_attach`, keyed by
    /// link kind. Returns `nil` when the link has no known next step.
    private static func nextStepsForAttach(link: String) -> [String]? {
        switch link {
        case "router_interface":
            return [
                "Router interface attached. If this connects a private network, you can now create servers on it: os_create(server, {networks: [{network: <name>}]})"
            ]
        case "floating_ip":
            return [
                "Server now has public IP. Connect via SSH if needed."
            ]
        case "volume":
            return [
                "Volume is available inside the server. The requested device is advisory on KVM — check the response's 'device' field (actual assigned path) and 'device_note'; use os_get(volume) -> attachments[].device if you need the authoritative target."
            ]
        default:
            return nil
        }
    }
}
