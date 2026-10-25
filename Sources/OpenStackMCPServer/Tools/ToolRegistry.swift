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
    /// The region preference selected during login (multi-region clouds).
    public let region: String?
    /// The cloud name this session is bound to. Used to scope resource URIs
    /// (`openstack://{cloud}/{region}/{resource}/{id}`) so a client can only
    /// read the cloud it is authenticated against.
    public let cloudName: String

    public init(vt: ValidatedToken, whoami: Whoami, region: String? = nil, cloudName: String) {
        self.vt = vt
        self.whoami = whoami
        self.region = region
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
    /// Roles treated as cloud-admin for `adminOnly` action enforcement
    /// (`policy.write_roles`, default `[admin]`). Empty = enforcement off
    /// (tests/legacy constructions keep the advisory-only behavior).
    public let writeRoles: [String]

    public init(
        client: OpenStackClient,
        catalog: ResourceCatalog,
        policy: Policy = Policy(),
        identity: RequestIdentity,
        scopeMode: ScopeMode = .coarse,
        logger: Logger = Logger(label: "substation-mcp"),
        auditEnabled: Bool = true,
        callLimiter: ToolCallLimiter? = nil,
        taskRegistry: TaskRegistry? = nil,
        writeRoles: [String] = []
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
        self.writeRoles = writeRoles
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
            "os_task_submit", "os_task_status", "os_task_cancel", "os_evacuation_plan",
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
            case "os_evacuation_plan": outcome = (try await handleEvacuationPlan(params), nil)
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

    /// Read the resource identifier for get/update/delete/action.
    ///
    /// The documented parameter is `id_or_name`, but `id`/`name` are what
    /// callers actually reach for; a wrong key used to cost a full round-trip
    /// on a `missingParam` error. Accept the aliases and name the canonical key
    /// in the error so the caller self-corrects.
    private func argIDOrName(_ params: CallTool.Parameters) throws -> String {
        for key in ["id_or_name", "id", "name", "uuid"] {
            if let s = arg(params, key)?.stringValue, !s.isEmpty { return s }
        }
        throw OpenStackError(
            service: "mcp", status: 400, code: "missingParam",
            message: "Missing required parameter: id_or_name (aliases id, name also accepted)"
        )
    }
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
        if let pref = identity.region, !pref.isEmpty { return pref }
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
        let idOrName = try argIDOrName(params)
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
        // Say WHY write is absent. Without this the only signal a read-only
        // session gets is that os_create is missing from tools/list, so an
        // agent concludes the server is broken instead of understanding that
        // its token carries no role in policy.write_roles. os_whoami is
        // read-only, so it is reachable from exactly the sessions that need
        // the explanation.
        var whoami: [String: JSONValue] = result
        if wm.scopes.contains(.write) {
            whoami["write_access"] = .string(
                "granted: token roles [\(wm.roles.joined(separator: ", "))] include a write role"
            )
        } else {
            whoami["write_access"] = .string(
                "read-only: none of the token roles [\(wm.roles.joined(separator: ", "))] is a write role. "
                + "Write roles on this deployment: [\(writeRoles.joined(separator: ", "))]. "
                + "To enable writes, re-authenticate with a credential carrying one of those roles, "
                + "or have the operator add this role to policy.write_roles. "
                + "If you asked for read-only on the sign-in page, this is that choice taking effect."
            )
        }
        let (text, val) = resultText(whoami)
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
            // Always emit volume_types (empty array when Cinder GET /v3/{project_id}/types is unreachable) so the field doesn't silently vanish from the capability entry. The list is member-readable, so a member token gets real names here — the names an agent should validate a volume_type_recommendation against.
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

    // MARK: - os_evacuation_plan

    /// Read-only evacuation planner for a hypervisor (the "evacuate host X"
    /// entry point). Joins, per instance on the host: flavor disk shape
    /// (disk/ephemeral/swap), inline volume attachments (BFOV + data disks),
    /// and task_state — then recommends the correct Nova action per instance
    /// and lists candidate targets by spare capacity. Classification rules are
    /// pinned to what a Nova 2.1-pinned cloud can actually report (live-
    /// validated IAD3): `os-extended-volumes:volumes_attached` non-empty ⇒
    /// boot-from-volume; `flavor.ephemeral > 0` ⇒ local ephemeral disk ⇒ cold
    /// BLOCK migration; nothing local ⇒ plain live migration.
    private func handleEvacuationPlan(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let host = try argString(params, "host")
        let region = try await resolveRegion(params)
        let hostDown = argBool(params, "host_down")
        let vt = identity.vt
        let compute = await client.compute(region: region)

        // 1. The source host must exist (also validates the hostname).
        let source = try await compute.getHypervisor(vt, host: host)

        // 2. Instances on the host.
        let refs = try await compute.hypervisorServers(vt, id: host)

        // 3. Per-instance classification. Flavor lookups cached per region.
        var entries: [[String: JSONValue]] = []
        var totals: [String: Int] = ["total": refs.count, "live_migrate": 0,
                                     "migrate_block": 0, "evacuate": 0, "blocked": 0]
        var flavorCache: [String: Flavor] = [:]
        for ref in refs {
            var entry: [String: JSONValue] = ["id": .string(ref.uuid), "name": .string(ref.name)]
            let server: NovaServer?
            do {
                server = try await compute.getServer(vt, id: ref.uuid)
            } catch let e as OpenStackError where e.status == 404 {
                entry["classification"] = .string("gone")
                entry["recommended_action"] = .string("none")
                entry["note"] = .string("Instance no longer exists (deleted or migrated already).")
                entries.append(entry)
                continue
            }
            guard let server else { continue }
            entry["status"] = .string(server.status)
            if let ts = server.taskState { entry["task_state"] = .string(ts) }

            let flavorID = server.flavor.id
            var flavor: Flavor? = flavorCache[flavorID]
            if flavor == nil {
                flavor = try? await compute.getFlavor(vt, id: flavorID)
                if let flavor { flavorCache[flavorID] = flavor }
            }
            let diskGB = flavor?.disk ?? 0
            let ephemeralGB = flavor?.ephemeral ?? 0
            let swapMB = flavor?.swap ?? 0
            let attached = server.volumesAttached ?? []
            let isBFOV = !attached.isEmpty
            entry["flavor"] = .object([
                "id": .string(flavorID),
                "disk_gb": .integer(diskGB),
                "ephemeral_gb": .integer(ephemeralGB),
                "swap_mb": .integer(swapMB),
            ])
            entry["root"] = .string(isBFOV ? "volume" : (diskGB > 0 ? "local" : "unknown"))
            entry["volumes_attached"] = .array(attached.map { a in
                JSONValue.object(["id": .string(a.id),
                                  "delete_on_termination": a.deleteOnTermination.map { JSONValue.bool($0) } ?? .null])
            })
            if server.srvAttrHost == nil && server.srvAttrHypervisor == nil {
                entry["host_attribution"] = .string("unavailable")
            }
            if let hv = server.srvAttrHypervisor { entry["hypervisor_hostname"] = .string(hv) }

            // Recommendation.
            let hasLocal = !isBFOV && (diskGB > 0 || ephemeralGB > 0)
            var action: String
            var actionParams: [String: JSONValue] = [:]
            var note: String?
            if server.status == "ERROR" {
                action = "investigate"
                note = "Instance is ERROR — migration will fail; inspect os_get(server) fault before moving it."
            } else if server.taskState != nil {
                action = "wait"
                note = "A task is in flight (\(server.taskState!)) — os_wait(server, until:[\"settled\"]) before acting."
            } else if hostDown {
                action = "evacuate"
                if hasLocal {
                    actionParams["on_shared_storage"] = .bool(false)
                    note = "Host down + local disks: block evacuation (copies the disk from rescue/shared storage; if the local disk is unrecoverable the instance must be rebuilt from its image/snapshot)."
                } else {
                    actionParams["on_shared_storage"] = .bool(true)
                }
            } else if hasLocal {
                action = "migrate"
                actionParams["block_migration"] = .bool(true)
                actionParams["disk_over_commit"] = .bool(false)
                note = "Cold BLOCK migration: instance has local disks (root local \(diskGB)GB, ephemeral \(ephemeralGB)GB, swap \(swapMB)MB). Requires a brief downtime; target must have local_gb spare ≥ disk+ephemeral."
            } else {
                action = "live_migrate"
                note = isBFOV ? "Boot-from-volume, no local disks: zero-downtime live migration." : nil
            }
            entry["recommended_action"] = .string(action)
            if !actionParams.isEmpty { entry["recommended_params"] = .object(actionParams) }
            if let note { entry["note"] = .string(note) }
            switch action {
            case "live_migrate": totals["live_migrate", default: 0] += 1
            case "migrate": totals["migrate_block", default: 0] += 1
            case "evacuate": totals["evacuate", default: 0] += 1
            default: totals["blocked", default: 0] += 1
            }
            entries.append(entry)
        }

        // 4. Target capacity: other hosts with spare, ranked by spare local
        //    disk then spare ram. Block migrations need local_gb spare.
        //    Server-group awareness: an instance in a (hard or soft)
        //    anti-affinity group may not land on a host already running a
        //    sibling. On clouds that never emit OS-EXT-SRV-ATTR the sibling
        //    host is unknown, so the constraint is reported per instance
        //    instead of silently dropped.
        let groups = (try? await compute.listServerGroups(vt)) ?? []
        let affinityByMember = Dictionary(uniqueKeysWithValues:
            groups.flatMap { g in g.members.map { ($0, g) } })
        struct Target { let host: String; let vcpuSpare: Int; let ramSpare: Int; let diskSpare: Int; let state: String }
        var targets: [Target] = []
        var hostMembers: [String: [String]] = [:]
        if let all = try? await compute.listHypervisors(vt) {
            for h in all {
                if h.hypervisorHostname != host {
                    let vcpuSpare = (h.vcpus ?? 0) - (h.vcpusUsed ?? 0)
                    let ramSpare = (h.memoryMB ?? 0) - (h.memoryMBUsed ?? 0)
                    let diskSpare = (h.localGB ?? 0) - (h.localGBUsed ?? 0)
                    targets.append(Target(host: h.hypervisorHostname, vcpuSpare: vcpuSpare,
                                          ramSpare: ramSpare, diskSpare: diskSpare,
                                          state: "\(h.state)/\(h.status)"))
                }
                for s in h.servers ?? [] { hostMembers[h.hypervisorHostname, default: []].append(s.uuid) }
            }
        }
        targets.sort { ($0.diskSpare, $0.ramSpare) > ($1.diskSpare, $1.ramSpare) }
        let targetOut = targets.prefix(10).map { t -> JSONValue in
            .object(["hypervisor_hostname": .string(t.host), "state": .string(t.state),
                     "vcpu_spare": .integer(t.vcpuSpare), "memory_mb_spare": .integer(t.ramSpare),
                     "local_gb_spare": .integer(t.diskSpare)])
        }
        // Per-instance anti-affinity constraint (only for members of a group).
        for i in entries.indices {
            guard let id = entries[i]["id"]?.stringValue, let g = affinityByMember[id] else { continue }
            entries[i]["server_group"] = .object([
                "id": .string(g.id), "name": .string(g.name), "policy": .string(g.policy),
            ])
            let siblings = g.members.filter { $0 != id }
            let siblingHosts = Set(siblings.flatMap { s in
                hostMembers.filter { $0.value.contains(s) }.map { $0.key }
            })
            if siblings.isEmpty {
                entries[i]["anti_affinity"] = .string("none: sole member of group '\(g.name)' (\(g.policy))")
            } else if siblingHosts.isEmpty {
                entries[i]["anti_affinity"] = .string("group '\(g.name)' (\(g.policy)): \(siblings.count) sibling(s) whose hosts are unattributable (cloud omits OS-EXT-SRV-ATTR) — omit host and let Nova enforce anti-affinity via placement")
            } else {
                entries[i]["anti_affinity"] = .string("group '\(g.name)' (\(g.policy)): avoid hosts running siblings: \(siblingHosts.sorted().joined(separator: ", "))")
            }
        }

        var result: [String: JSONValue] = [
            "tool": .string("os_evacuation_plan"),
            "region": .string(region),
            "host": .string(host),
            "host_state": .string("\(source.state)/\(source.status)"),
            "instances": .array(entries.map { JSONValue.object($0) }),
            "summary": .object(totals.mapValues { JSONValue.integer($0) }),
            "candidate_targets": .array(targetOut),
            "procedure": .array([
                .string("1. Fence the source: os_action(hypervisor, \"\(host)\", set_state, params:{enabled:false}) — stops NEW placements; running VMs unaffected."),
                .string("2. For each instance, execute recommended_action via os_action(server, ...) (omit host unless a specific target is required; Nova schedules via placement)."),
                .string("3. Confirm each move: os_wait(server, id, until:[\"settled\"]) — ACTIVE alone is NOT completion; settled = task_state null."),
                .string("4. Final check: os_action(hypervisor, \"\(host)\", \"servers\") must return an empty list; then re-enable the host (set_state enabled:true) or leave fenced."),
            ]),
        ]
        if let disabled = source.service?.disabledReason { result["host_disabled_reason"] = .string(disabled) }
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleTopology(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let resourceName = try argString(params, "resource")
        let idOrName = try argIDOrName(params)
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
        // `id` is the documented key; `id_or_name`/`name`/`uuid` are the
        // aliases every other identifier-taking tool already accepts.
        let idOrName = try argIDOrName(params)
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

        // Resolve the identifier BEFORE polling. os_wait polls by id only, so
        // a server name used to produce a 404 on the very first poll, which
        // the loop then reported as "Resource server probe-01 no longer
        // exists (last status: unknown)" about a server that was in BUILD.
        // `last status: unknown` was the tell: there was never a status,
        // because there was never a lookup that could return one. A name that
        // matches nothing must fail as a resolution error, and the poll loop
        // must only ever see a real id.
        guard let descriptor = catalog.descriptor(resourceName) else {
            throw OpenStackError(
                service: "mcp", status: 400, code: "unknownResource",
                message: "Unknown resource: \(resourceName). Valid: \(catalog.names.sorted().joined(separator: ", "))"
            )
        }
        let resolver = NameResolver(catalog: catalog, client: client)
        let id = try await resolver.resolveID(vt, descriptor: descriptor,
                                              idOrName: idOrName, region: region)

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
        // Same identifier handling as os_wait: aliases accepted, and the value
        // is RESOLVED before anything polls it. A name used to reach the poll
        // loop verbatim, where the first 404 was recorded as lastStatus
        // "deleted" — a live server reported as deleted because an identifier
        // was never looked up.
        let idOrName = try argIDOrName(params)
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

        // Resolve after the resource/until checks so a bad `until` still fails
        // first and no lookup is spent on a malformed call.
        let resolver = NameResolver(catalog: catalog, client: client)
        let id = try await resolver.resolveID(vt, descriptor: descriptor,
                                              idOrName: idOrName, region: region)

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
                            // Name fallback for distro detection. High limit:
                            // Glance's default page truncates a public catalogue
                            // to ~25 images, so a name beyond it would mis-detect
                            // as `.unknown` and render the wrong cloud-init.
                            let items = (try? await ri.listImages(vt, limit: 500)) ?? []
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
            let result: [String: JSONValue] = ["dry_run": .bool(true), "resource": .string(d.name), "region": .string(region),
                "message": .string("Spec is valid. Resource would be created in \(region).")]
            let (text, val) = resultText(result)
            return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
        }
        let resolver = NameResolver(catalog: catalog, client: client)
        let raw = try await resolver.createPublic(vt, descriptor: d, body: spec, region: region, dryRun: dryRun)
        var result: [String: JSONValue] = ["resource": .string(d.name), "region": .string(region), "data": .object(raw)]
        if let nextSteps = nextStepsForCreate(resource: d.name, spec: spec, data: raw) {
            result["next_steps"] = .array(nextSteps.map { .string($0) })
        }
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleUpdate(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let d = try getDescriptor(params)
        let region = try await resolveRegion(params)
        let idOrName = try argIDOrName(params)
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
        let idOrName = try argIDOrName(params)
        let vt = identity.vt
        let dryRun = argBool(params, "dry_run")
        // `cascade` is honored only by the Octavia load balancer (the one
        // resource whose children block a plain delete). Other resources ignore
        // it; the schema documents it as load_balancer-only.
        let cascade = argBool(params, "cascade")

        let resolver = NameResolver(catalog: catalog, client: client)
        let (id, _) = try await resolver.resolve(vt, descriptor: d, idOrName: idOrName, region: region)

        if dryRun {
            // Walk real child dependents so can_delete reflects what a Neutron/Cinder
            // hard-delete would actually block on (ISSUE #1). Previously only `network`
            // checked its ports, and every other resource reported can_delete:true even
            // when it still had children — an under-report that green-lit a delete that
            // then 409'd RouterInUse / InUse.
            var dependents: [String] = []
            var hint: String?
            switch d.name {
            case "network":
                let r = await client.network(region: region)
                let ports = try await r.listPorts(vt, filters: ["network_id": id], limit: 200)
                dependents += ports.map { "port \($0.id)" }
                if !dependents.isEmpty {
                    hint = "Detach/remove the ports first (os_detach interface, or delete the attached server)."
                }
            case "subnet":
                // A subnet is blocked by any port whose fixed IP sits on it — including
                // router-interface ports (device_owner network:router_interface). Neutron
                // refuses to delete a subnet in use this way, so count them.
                let r = await client.network(region: region)
                let ports = try await r.listPorts(vt, filters: [:], limit: 500)
                let onSubnet = ports.filter { p in
                    p.fixedIPs.contains(where: { $0.subnetID == id })
                }
                for p in onSubnet {
                    let label = (p.deviceOwner ?? "").hasPrefix("network:router_interface")
                        ? "router-interface port \(p.id)" : "port \(p.id)"
                    dependents.append(label)
                }
                if !dependents.isEmpty {
                    hint = "Delete the ports/router interfaces first (os_detach router_interface, or delete attached servers), then retry."
                }
            case "router":
                // A router is blocked while it has non-gateway interface ports
                // (device_owner network:router_interface, device_id == router). The
                // external gateway is not a blocker — Neutron clears it on delete.
                let r = await client.network(region: region)
                let ports = try await r.listPorts(vt, filters: [:], limit: 500)
                let ifPorts = ports.filter { p in
                    (p.deviceOwner ?? "") == "network:router_interface" && p.deviceID == id
                }
                dependents = ifPorts.map { "router-interface port \($0.id)" }
                if !dependents.isEmpty {
                    hint = "Remove its subnets first: os_detach(link:router_interface, source=\(id), target=<subnet>) for each, then delete the router."
                }
            default:
                break
            }
            var result: [String: JSONValue] = [
                "dry_run": .bool(true), "resource": .string(d.name), "id": .string(id), "region": .string(region),
                "dependents": .array(dependents.map { .string($0) }),
                "can_delete": .bool(dependents.isEmpty),
            ]
            if let hint { result["hint"] = .string(hint) }
            let (text, val) = resultText(result)
            return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
        }

        _ = try await resolver.deletePublic(vt, descriptor: d, id: id, region: region, cascade: cascade)
        let result: [String: JSONValue] = ["resource": .string(d.name), "id": .string(id), "region": .string(region), "deleted": .bool(true)]
        let (text, val) = resultText(result)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: val)
    }

    private func handleAction(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let d = try getDescriptor(params)
        let region = try await resolveRegion(params)
        let idOrName = try argIDOrName(params)
        let actionName = try argString(params, "action")
        let vt = identity.vt

        guard let spec = d.actions.first(where: { $0.name == actionName }) else {
            throw OpenStackError(service: "mcp", status: 400,
                message: "Unknown action: \(actionName) for \(d.name). Valid: \(d.actions.map(\.name).joined(separator: ", "))")
        }
        // adminOnly is ENFORCED, not advisory: the caller's token must carry a
        // write role (policy.write_roles, default [admin]) — the same role set
        // that grants `openstack:write`. Without it the call is refused here
        // with a clear code instead of surfacing Nova's 403 PolicyNotAuthorized
        // (which many clouds return with an unhelpful message).
        if spec.adminOnly, !writeRoles.isEmpty {
            let roles = identity.vt.token.roles.map { $0.lowercased() }
            let allowed = writeRoles.map { $0.lowercased() }
            guard Set(roles).isDisjoint(with: Set(allowed)) == false else {
                throw OpenStackError(service: "mcp", status: 403, code: "insufficient_scope",
                    message: "Action \(d.name).\(actionName) is admin-only: requires one of the write roles (\(writeRoles.joined(separator: ", "))); token roles: \(identity.vt.token.roles.joined(separator: ", "))",
                    hint: "Re-authenticate with a cloud-admin credential, or extend policy.write_roles if this role is legitimately an operator on this cloud.")
            }
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

    /// A follow-up tool call recommended by a `next_steps` hint.
    ///
    /// The hint line is RENDERED from this struct rather than hand-written, so
    /// the arguments it shows are the arguments the target tool's published
    /// `inputSchema` marks as `required` (`AllTools.requiredArguments`).
    /// Hand-written argument lists drifted: the floating_ip create hint said
    /// `os_attach(link:floating_ip, source:…, target:…)` and an agent that
    /// copied it verbatim failed twice with `missingParam: source_type` /
    /// `missingParam: target_type`, because `os_attach` requires all five.
    struct NextStepCall: Sendable {
        /// Leading prose, e.g. "Associate with a server:".
        let lead: String
        /// Target tool name, e.g. "os_attach".
        let tool: String
        /// Argument values keyed by argument name. Only the names that are
        /// `required` on the target tool are rendered; a value of `nil` means
        /// the caller must substitute it (rendered `<NAME>`), a non-nil value
        /// is the real value taken from the just-created resource.
        let values: [String: String?]
        /// Trailing prose appended after the call, e.g. a caveat.
        let note: String?

        init(_ lead: String, _ tool: String, _ values: [String: String?], note: String? = nil) {
            self.lead = lead
            self.tool = tool
            self.values = values
            self.note = note
        }
    }

    /// Render one hint line: `lead tool(k1: v1, k2: <K2 "what to supply">)`.
    ///
    /// Three properties, all asserted by `NextStepsHintCompletenessTests`:
    /// - every `required` argument of `tool` appears in the line, in the
    ///   schema's own order — a hint can never under-specify the call it
    ///   recommends, which was the reported defect;
    /// - the line never mentions an argument the tool does not require, so a
    ///   hint cannot contradict the schema either;
    /// - an argument the caller must still supply is rendered with the schema's
    ///   own `description` inside the placeholder, so the hint says what belongs
    ///   there instead of leaving a bare uppercase word to guess at.
    private static func renderNextStep(_ call: NextStepCall,
                                       required: [String: [ToolRequiredArgument]]) -> String {
        let requiredArgs = (required[call.tool] ?? []).sorted { $0.order < $1.order }
        // Anything the hint declares that the schema does not require is still
        // rendered (appended after the required ones) rather than silently
        // dropped; the completeness test flags it as a contradiction.
        let extra = call.values.keys.sorted().filter { key in
            !requiredArgs.contains { $0.name == key }
        }
        let ordered = requiredArgs.map(\.name) + extra
        let args = ordered.map { key -> String in
            if let value = call.values[key] ?? nil { return "\(key): \(value)" }
            let description = requiredArgs.first { $0.name == key }?.description
            if let description, !description.isEmpty {
                return "\(key): <\(key.uppercased()) \"\(description)\">"
            }
            return "\(key): <\(key.uppercased())>"
        }
        var line = "\(call.lead) \(call.tool)(\(args.joined(separator: ", ")))"
        if let note = call.note, !note.isEmpty { line += " — \(note)" }
        return line
    }

    /// The identifier of a freshly created resource, or `nil` when the create
    /// response carried no `id` (some resources are keyed by `name`).
    private static func createdID(_ data: [String: JSONValue]) -> String? {
        data["id"]?.stringValue
    }

    /// Contextual follow-up instructions for a successful `os_create`, keyed by
    /// resource type. Returns `nil` when the resource has no known next steps so
    /// the field is omitted entirely from the response.
    ///
    /// Where the created resource's own id/name is known it is substituted into
    /// the hint, so the recommended call is directly executable; anything the
    /// caller must supply is rendered as its uppercase `<NAME>` placeholder.
    private func nextStepsForCreate(resource: String, spec: JSONValue, data: [String: JSONValue]) -> [String]? {
        let calls: [NextStepCall]?
        let id = Self.createdID(data)
        switch resource {
        case "network":
            calls = [
                NextStepCall("Create a subnet on this network:", "os_create",
                             ["resource": "subnet", "spec": Self.specLiteral([
                                ("network_id", .string(id ?? "<NETWORK_ID>")), ("cidr", .string("<CIDR>"))])],
                             note: "os_describe(resource: subnet) for the optional fields (enable_dhcp is what a server needs to get an address)."),
                NextStepCall("Create a router:", "os_create",
                             ["resource": "router",
                              "spec": Self.specLiteral([
                                ("name", .string("<ROUTER_NAME>")),
                                ("external_gateway_info", .object(["network_id": .string("<EXTERNAL_NETWORK_ID>")]))
                              ])],
                             note: "external_gateway_info.network_id must be an external (router:external) network — os_list(network) and check that field."),
            ]
        case "subnet":
            calls = [
                NextStepCall("Attach it to a router:", "os_attach",
                             ["link": "router_interface", "source_type": "router",
                              "target": id, "target_type": "subnet"]),
            ]
        case "router":
            calls = [
                NextStepCall("Attach a private subnet:", "os_attach",
                             ["link": "router_interface", "source": id, "source_type": "router"]),
                NextStepCall("Give it a gateway on the external network:", "os_attach",
                             ["link": "router_gateway", "source": id, "source_type": "router",
                              "target_type": "network"]),
            ]
        case "server":
            var steps = [NextStepCall("Wait for ACTIVE:", "os_wait", ["resource": "server", "id": id])]
            if case .object(let obj) = spec, case .object(let provObj)? = obj["provisioning"], !provObj.isEmpty {
                steps.append(NextStepCall("Verify provisioning:", "os_action",
                                          ["resource": "server", "id_or_name": id,
                                           "action": "provisioning_status"]))
            }
            calls = steps
        // No `volume` hint. `NameResolver.createPublic` builds a
        // `CreateVolumeSpec` from name/size/volume_type only, so a volume create
        // can never carry `imageRef` — the old hint's branch was unreachable,
        // and what it produced (`os_create(server, {volumes: [{volume_id,
        // boot}]})`) named a field the server create path reads as a quota
        // count, not a device list.
        case "floating_ip":
            // `target_type: server` is the hint's own choice (the link also
            // accepts a bare port); every other argument comes from the schema,
            // and `target` is rendered as the schema's own description of it.
            calls = [
                NextStepCall("Associate with a server:", "os_attach",
                             ["link": "floating_ip", "source": id, "source_type": "floating_ip",
                              "target_type": "server"]),
            ]
        case "keypair":
            let name = data["name"]?.stringValue ?? "<NAME>"
            let kpSpec = Self.specLiteral([
                ("name", .string("<SERVER_NAME>")),
                ("flavor", .string("<FLAVOR_ID_OR_NAME>")),
                ("image", .string("<IMAGE_ID_OR_NAME>")),
                ("key_name", .string(name)),
                ("networks", .array([.object(["network": .string("<NETWORK_ID_OR_NAME>")])])),
            ])
            calls = [
                NextStepCall("Reference it when creating a server:", "os_create",
                             ["resource": "server", "spec": kpSpec]),
            ]
        case "security_group":
            calls = [
                NextStepCall("Add a rule:", "os_create",
                             ["resource": "security_group_rule", "spec": Self.specLiteral([
                                ("security_group_id", .string(id ?? "<SECURITY_GROUP_ID>")), ("direction", .string("ingress")),
                                ("protocol", .string("tcp")), ("port_range_min", .integer(443)), ("port_range_max", .integer(443)),
                                ("remote_ip_prefix", .string("0.0.0.0/0"))])],
                             note: "repeat per port/protocol you need to open."),
            ]
        default:
            calls = nil
        }
        guard let calls else { return nil }
        let required = AllTools.requiredArguments(catalog: catalog)
        return calls.map { Self.renderNextStep($0, required: required) }
    }

    /// Serialize a spec literal for a hint, substituting the real values of the
    /// just-created resource. Placeholders (`"<CIDR>"`) render bare so they read
    /// as "fill me in"; concrete strings are quoted.
    ///
    /// Built on `JSONValue` rather than `Any` so a hint literal is checked by
    /// the compiler against the same value type the create path validates, and
    /// so field order stays as written.
    private static func specLiteral(_ fields: [(String, JSONValue)]) -> String {
        "{" + fields.map { "\($0.0): \(hintValue($0.1))" }.joined(separator: ", ") + "}"
    }

    private static func hintValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s.hasPrefix("<") ? s : "'\(s)'"
        case .integer(let i): return "\(i)"
        case .float(let d): return "\(d)"
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[\(items.map(hintValue).joined(separator: ", "))]"
        case .object(let obj):
            return "{" + obj.keys.sorted().compactMap { k -> String? in
                guard let v = obj[k] else { return nil }
                return "\(k): \(hintValue(v))"
            }.joined(separator: ", ") + "}"
        }
    }

    /// Contextual follow-up instructions for a successful `os_attach`, keyed by
    /// link kind. Returns `nil` when the link has no known next step.
    ///
    /// These are prose only — none of them recommends a tool call, so none of
    /// them can drift from a schema. The `os_create` hints are the ones that
    /// name calls, and those are rendered by `renderNextStep`.
    private static func nextStepsForAttach(link: String) -> [String]? {
        switch link {
        case "router_interface":
            return [
                "Router interface attached. The subnet is now routed through this router; servers on its network get an address only if the subnet has DHCP enabled and the router also has a gateway on the external network (os_attach(link: router_gateway))."
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
