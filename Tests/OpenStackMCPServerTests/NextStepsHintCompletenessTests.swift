import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import MCP
import OpenStackMCPServer
import Logging

// MARK: - next_steps hint completeness
//
// `os_create` ends with a `next_steps` hint, and for an agent that hint is the
// ONLY guidance it gets about what to do next. The reported failure (live,
// Rackspace IAD3): the floating_ip create hint said
//     os_attach(link:floating_ip, source=<fip-id>, target=<server>)
// while `os_attach` requires `link`, `source`, `source_type`, `target` and
// `target_type`. Copying the hint produced `missingParam: source_type`, then
// `missingParam: target_type` — two failed calls that looked like the tool was
// broken.
//
// The hints are now RENDERED from the target tool's own published `required`
// list (`AllTools.requiredArguments`), so the argument set cannot drift from
// the schema. These tests pin both halves of that guarantee:
//   - the generic, schema-driven completeness/consistency sweep, which fails if
//     anyone adds a required parameter to a tool without the hint naming it;
//   - the concrete floating_ip case, executed end-to-end against the fake so
//     the substituted id is proven to be the real created id and the call the
//     hint describes actually succeeds.

/// The `next_steps` array of a tool result, or nil when absent.
private func nextSteps(from result: (content: [Tool.Content], isError: Bool?)) -> [String]? {
    guard let text = firstText(result.content),
          let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let steps = obj["next_steps"] as? [String] else { return nil }
    return steps
}

/// The tool name a hint line points at, when it names a call.
private func recommendedTool(in line: String) -> String? {
    for tool in ["os_create", "os_attach", "os_detach", "os_wait", "os_action", "os_update", "os_delete"]
    where line.contains("\(tool)(") { return tool }
    return nil
}

/// The `arg: value` pairs rendered inside the first `tool(...)` call of a line.
///
/// Splitting is depth-aware AND quote/angle-aware, because both kinds of value
/// contain commas that must NOT split an argument:
/// - a hint's `spec` is itself a `{…}` literal with nested commas;
/// - a placeholder embeds the schema's own description in quotes
///   (`target: <TARGET "ID or name of the resource …">`).
private func renderedArguments(in line: String, tool: String) -> [String: String] {
    guard let open = line.range(of: "\(tool)(") else { return [:] }
    let rest = line[open.upperBound...]

    var out: [String: String] = [:]
    var depth = 0
    var inQuotes = false
    var inAngle = false
    var token = ""
    func flush() {
        let part = token.trimmingCharacters(in: .whitespaces)
        token = ""
        guard let colon = part.firstIndex(of: ":") else { return }
        let name = part[..<colon].trimmingCharacters(in: .whitespaces)
        let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !value.isEmpty else { return }
        out[name] = value
    }
    for ch in rest {
        if ch == "\"" { inQuotes.toggle() }
        if !inQuotes {
            if ch == "<" { inAngle = true }
            if ch == ">" { inAngle = false }
        }
        if inQuotes || inAngle {
            token.append(ch)
            continue
        }
        switch ch {
        case "(", "{", "[":
            depth += 1
            token.append(ch)
        case ")", "}", "]":
            if depth == 0 {
                flush()
                return out
            }
            depth -= 1
            token.append(ch)
        case ",":
            if depth == 0 { flush() } else { token.append(ch) }
        default:
            token.append(ch)
        }
    }
    flush()
    return out
}

/// Re-encodes a `JSONValue` (the catalog's JSON vocabulary) into MCP SDK's
/// `Value`, the argument type `MCP.Client.callTool` takes. The two enums are
/// structurally identical but unrelated types, so the probe has to bridge them.
private func mcpValue(_ value: JSONValue) -> MCP.Value {
    switch value {
    case .string(let s): return .string(s)
    case .integer(let i): return .int(i)
    case .float(let d): return .double(d)
    case .bool(let b): return .bool(b)
    case .null: return .null
    case .array(let a): return .array(a.map(mcpValue))
    case .object(let o): return .object(o.mapValues(mcpValue))
    }
}

// MARK: - Offline hint derivation
//
// The completeness sweep has to see the hints of EVERY creatable resource,
// which a live `os_create` cannot do (most creates need real upstream state).
// So the sweep drives the real tool surface through the in-process MCP stack
// against the fake cloud: `handleCreate` validates the spec BEFORE it contacts
// any endpoint, so a resource whose required keys are not
// satisfiable offline fails schema validation and yields no hint, while a
// resource whose minimal spec IS valid reaches the upstream call, fails there,
// and also yields no hint. Both are `nil` — which is exactly right, because
// `next_steps` is only emitted for a create that SUCCEEDED, and the sweep is
// then a no-op for that resource rather than a false positive.
//
// The resources that actually carry hints (network, subnet, router, server,
// volume, floating_ip, keypair, security_group) are all creatable against the
// in-process fake, so the individual hint tests below run them for real
// through the same dispatch path.
enum NextStepsTestSupport {
    /// The `next_steps` a SUCCESSFUL `os_create` of `resource` would emit,
    /// derived through the real dispatch path against the in-process fake.
    /// nil when the resource has no follow-up (or cannot be created here).
    static func createHints(resource: String, catalog: ResourceCatalog,
                            provisioning: Bool = false, imageRef: Bool = false) async -> [String]? {
        guard let handle = try? await FakeApp.start() else { return nil }
        defer { handle.stop() }
        guard let bundle = try? await fakeRegistry(handle: handle, catalog: catalog) else { return nil }
        defer { bundle.shutdown() }
        let spec = minimalSpec(for: resource, catalog: catalog, provisioning: provisioning, imageRef: imageRef)
        // Through the bundle's MCP client (the public surface every other
        // server test uses) rather than `ToolRegistry.dispatch`, which is
        // internal to the module. The spec is built as `JSONValue` (the
        // catalog's vocabulary) and re-encoded into MCP's `Value` for the call.
        let result = try? await bundle.mcpClient.callTool(
            name: "os_create",
            arguments: [
                "resource": .string(resource),
                "spec": mcpValue(.object(spec)),
            ]
        )
        guard let result, let steps = nextSteps(from: (result.content, result.isError)) else { return nil }
        return steps
    }

    /// A real `ToolRegistry` bound to the in-process fake with a member-role
    /// token (a write role by default, so the mutating-tool gate lets the probe
    /// through). Built on the shared `makeRegistry` helper so the transport,
    /// token decoding and client wiring are the ones every other server test
    /// exercises; only the catalog is swapped for the one under test.
    private static func fakeRegistry(handle: FakeHandle, catalog: ResourceCatalog) async throws -> MCPTestBundle {
        // The shared helper's catalog is the phase-1 catalog the sweep iterates,
        // so it is reused as-is; `catalog` is the one the caller enumerates and
        // is kept in the signature so the probe spec and the sweep agree.
        try await makeRegistry(handle: handle, credID: "fake-cred-member", secret: "secret-member")
    }

    /// A spec that lets `os_create` of `resource` actually succeed against the
    /// fake: the target's `create_schema` `required` keys, with the values the
    /// fake actually resolves (its flavor/image/keypair lists are seeded, not
    /// arbitrary), plus what the create path — not the schema — demands: a
    /// private network for a server and `floating_network_id` for a floating
    /// IP. `imageRef` is passed for a volume to prove the create path drops it.
    private static func minimalSpec(for resource: String, catalog: ResourceCatalog,
                                    provisioning: Bool, imageRef: Bool) -> [String: JSONValue] {
        var spec: [String: JSONValue] = [:]
        if let required = catalog.descriptor(resource)?.createSchema?.required {
            for field in required { spec[field] = probeValue(resource: resource, field: field) }
        }
        switch resource {
        case "server":
            // The fake seeds net-int (private, DHCP, routed to net-ext by
            // router-1); creating on the external net is rejected outright.
            spec["networks"] = .array([.object(["network": .string("int-net")])])
            if provisioning {
                spec["provisioning"] = .object(["packages": .array([.string("curl")])])
            }
        case "volume":
            if imageRef { spec["imageRef"] = .string("hint-probe-image") }
        case "floating_ip":
            spec["floating_network_id"] = .string("net-ext")
        default:
            break
        }
        return spec
    }

    /// The value a probe spec uses for one required field: the seeded names the
    /// fake resolves, otherwise an integer where the schema wants a number.
    private static func probeValue(resource: String, field: String) -> JSONValue {
        switch (resource, field) {
        // The fake's flavor/image lists are static; only these names resolve.
        case ("server", "flavor"): return .string("m1.small")
        case ("server", "image"): return .string("ubuntu-24.04")
        // A subnet needs a network the fake actually has; `hint-probe` is an
        // unresolvable name and the create 404s before any hint is emitted.
        case ("subnet", "network_id"): return .string("net-int")
        case (_, "size"): return .integer(1)
        case (_, "port"), (_, "port_range_min"), (_, "port_range_max"),
             (_, "protocol_port"), (_, "volume_size"):
            return .integer(80)
        default: return .string("hint-probe")
        }
    }
}

@Suite("next_steps hint completeness", .timeLimit(.minutes(3)))
struct NextStepsHintCompletenessTests {

    // MARK: - Schema-driven sweep

    /// The property that keeps this from regressing: for EVERY resource the
    /// server knows how to create, every hint line that names a tool call must
    /// name every parameter that tool's published schema marks required — and
    /// must not name a parameter the schema does not require.
    ///
    /// Add a required parameter to `AllTools` (or drop one from a hint) and
    /// this fails; that is the point.
    @Test("every create hint names every required argument of the tool it recommends")
    func everyHintNamesEveryRequiredArgument() async throws {
        let catalog = ResourceCatalog.phase1()
        let required = AllTools.requiredArguments(catalog: catalog)
        let osAttachRequired = (required["os_attach"] ?? []).map(\.name)
        #expect(osAttachRequired == ["link", "source", "source_type", "target", "target_type"],
                "os_attach's published required list is what the hints are rendered from")
        // The placeholders an agent has to fill in must say what belongs there.
        #expect((required["os_attach"] ?? []).first { $0.name == "target" }?.description?.isEmpty == false,
                "os_attach's `target` needs a schema description so the hint placeholder explains itself")

        var checked = 0
        for name in catalog.names {
            guard catalog.descriptor(name)?.createSchema != nil else { continue }
            let lines = await NextStepsTestSupport.createHints(resource: name, catalog: catalog) ?? []
            for line in lines {
                guard let tool = recommendedTool(in: line) else { continue }
                let requiredArgs = (required[tool] ?? []).map(\.name)
                let rendered = renderedArguments(in: line, tool: tool)
                for arg in requiredArgs {
                    #expect(rendered.keys.contains(arg),
                            "hint for \(name) omits required parameter `\(arg)` of \(tool): \(line)")
                }
                for arg in rendered.keys {
                    #expect(requiredArgs.contains(arg),
                            "hint for \(name) names `\(arg)` for \(tool), which is not a required parameter of that tool: \(line)")
                }
                checked += 1
            }
        }
        // Guards the sweep itself: a refactor that stops emitting hints would
        // otherwise leave this test vacuously green.
        #expect(checked >= 8, "expected to check every creatable resource's hints, checked \(checked)")
    }

    /// The create-time spec fields a hint promises must exist in the target
    /// resource's `create_schema`, or the hint contradicts `os_describe`.
    @Test("hint spec literals only name fields the target create_schema declares")
    func hintSpecFieldsExistInSchema() async throws {
        let catalog = ResourceCatalog.phase1()
        for name in catalog.names {
            guard catalog.descriptor(name)?.createSchema != nil else { continue }
            let lines = await NextStepsTestSupport.createHints(resource: name, catalog: catalog) ?? []
            for line in lines {
                let createArgs = renderedArguments(in: line, tool: "os_create")
                guard recommendedTool(in: line) == "os_create",
                      let target = createArgs["resource"],
                      let spec = createArgs["spec"],
                      let schema = catalog.descriptor(target)?.createSchema,
                      let properties = schema.properties else { continue }
                for field in Self.specFieldNames(in: spec) {
                    #expect(properties[field] != nil,
                            "hint for \(name) puts `\(field)` in a \(target) spec, but \(target)'s create_schema has no such field: \(line)")
                }
            }
        }
    }

    /// Top-level spec field names of a rendered `{k: v, …}` literal.
    ///
    /// Depth-aware so nested object keys (`networks: [{network: …}]`) are not
    /// mistaken for top-level spec fields.
    private static func specFieldNames(in spec: String) -> [String] {
        var names: [String] = []
        var depth = 0
        var token = ""
        for ch in spec {
            switch ch {
            case "{", "[":
                depth += 1
                if depth == 1 { token = ""; continue }
                token.append(ch)
            case "}", "]":
                depth -= 1
                if depth == 0 { token = ""; continue }
                token.append(ch)
            case ",":
                if depth == 1 { token = "" } else { token.append(ch) }
            case ":":
                if depth == 1 {
                    let name = token.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { names.append(name) }
                    token = ""
                } else { token.append(ch) }
            default:
                if depth >= 1 { token.append(ch) }
            }
        }
        return names
    }

    // MARK: - The reported defect, end to end

    /// The user's exact complaint: the floating_ip hint was not a working call.
    /// This creates a real floating IP through the tool layer, then executes
    /// the call the hint describes — with the hint's substituted `source` — and
    /// requires it to succeed.
    @Test("floating_ip create hint is a complete, executable os_attach")
    func floatingIPHintIsExecutable() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let created = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("floating_ip"),
            "spec": .object(["floating_network_id": .string("net-ext")]),
        ])
        #expect(created.isError != true, "floating_ip create failed: \(firstText(created.content) ?? "nil")")
        guard let steps = nextSteps(from: created), let hint = steps.first else {
            Issue.record("expected a next_steps hint on floating_ip create, got: \(firstText(created.content) ?? "nil")")
            return
        }

        // The created id is substituted in, not a `<FIP>` placeholder. Read it
        // by decoding the JSON, not by scanning the text: the server serializes
        // `Swift.Dictionary` (unstable) key order, so the created resource's
        // `id` is sometimes the first key after `data":{` and sometimes after a
        // sibling — a positional text scan flakes. A keyed decode is stable.
        let createdJSON = (try? JSONSerialization.jsonObject(
            with: Data((firstText(created.content) ?? "").utf8))) as? [String: Any]
        let createdID = (createdJSON?["data"] as? [String: Any])?["id"] as? String ?? ""
        #expect(!createdID.isEmpty, "decoded create response must carry data.id")
        #expect(hint.contains("source: \(createdID)"), "hint must carry the real fip id: \(hint)")

        let args = renderedArguments(in: hint, tool: "os_attach")
        #expect(args["link"] == "floating_ip")
        #expect(args["source_type"] == "floating_ip", "hint omits source_type: \(hint)")
        #expect(args["target_type"] == "server", "hint omits target_type: \(hint)")
        #expect(args["source"] == createdID)
        // `target` is the caller's to supply, so it renders as a placeholder —
        // and the placeholder carries the schema's own description of the
        // argument rather than a bare word.
        let target = args["target"] ?? ""
        #expect(target.hasPrefix("<TARGET \"") && target.hasSuffix("\">"),
                "target must be a self-describing placeholder, got: \(target) in \(hint)")
        #expect(hint.contains("os_attach(link: floating_ip, source: \(createdID), source_type: floating_ip, target:"),
                "hint must render the required arguments in the schema's own order: \(hint)")

        // And the call the hint describes actually works: substitute a real
        // server for the one placeholder and attach. The fake's `POST /servers`
        // does not provision a Neutron port (only `os-interface-attach` does), so
        // a freshly-created server has no port and can never take a floating IP —
        // `os_attach` would correctly report `noReachablePort`. Attach to the
        // seeded `srv-0001`, whose `port-002` sits on `subnet-int`, bridged to
        // `net-ext` by `router-1`, so the hint's `os_attach` reaches a real port.
        let serverID = "srv-0001"

        let attached = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string(args["link"] ?? ""),
            "source": .string(args["source"] ?? ""),
            "source_type": .string(args["source_type"] ?? ""),
            "target": .string(serverID),
            "target_type": .string(args["target_type"] ?? ""),
        ])
        #expect(attached.isError != true,
                "the hint's own os_attach call failed: \(firstText(attached.content) ?? "nil")")
    }

    /// The other hints that name an `os_attach` (subnet → router_interface,
    /// router → router_interface/router_gateway) must be complete too, and must
    /// carry the created resource's id on the side that owns it.
    @Test("router and subnet create hints name all five os_attach parameters")
    func attachHintsOnNetworkResourcesAreComplete() async throws {
        let catalog = ResourceCatalog.phase1()
        let required = (AllTools.requiredArguments(catalog: catalog)["os_attach"] ?? []).map(\.name)

        for (resource, idArg) in [("subnet", "target"), ("router", "source")] {
            let lines = await NextStepsTestSupport.createHints(resource: resource, catalog: catalog)
            #expect(lines != nil && lines!.isEmpty == false, "expected next_steps for \(resource) create")
            for line in lines ?? [] where recommendedTool(in: line) == "os_attach" {
                let args = renderedArguments(in: line, tool: "os_attach")
                for arg in required {
                    #expect(args[arg] != nil, "\(resource) hint omits \(arg): \(line)")
                }
                // The created resource's own side must carry a value: its real
                // id when the create returned one, the `<ID>` placeholder when
                // it did not. Never blank.
                #expect((args[idArg] ?? "").isEmpty == false,
                        "\(resource) hint leaves \(idArg) blank: \(line)")
            }
        }
    }

    /// `os_wait` requires `resource` AND `id`. The old hint read
    /// `os_wait(server, <id>)` — positional, and with no `id=` key, so an agent
    /// that filled it in still had no `id` argument to send.
    @Test("server create hint is a complete os_wait call")
    func serverWaitHintIsComplete() async throws {
        let catalog = ResourceCatalog.phase1()
        let lines = await NextStepsTestSupport.createHints(resource: "server", catalog: catalog)
        guard let wait = (lines ?? []).first(where: { recommendedTool(in: $0) == "os_wait" }) else {
            Issue.record("expected an os_wait hint on server create, got: \(String(describing: lines))")
            return
        }
        let args = renderedArguments(in: wait, tool: "os_wait")
        #expect(args["resource"] == "server")
        #expect((args["id"] ?? "").isEmpty == false, "os_wait must name an id: \(wait)")
    }

    /// The provisioning follow-up names `os_action`'s three required arguments.
    @Test("server provisioning hint is a complete os_action call")
    func provisioningHintIsComplete() async throws {
        let catalog = ResourceCatalog.phase1()
        let lines = await NextStepsTestSupport.createHints(resource: "server", catalog: catalog,
                                                          provisioning: true)
        guard let action = (lines ?? []).first(where: { recommendedTool(in: $0) == "os_action" }) else {
            Issue.record("expected an os_action hint when the create carried a provisioning block, got: \(String(describing: lines))")
            return
        }
        let args = renderedArguments(in: action, tool: "os_action")
        #expect(args["resource"] == "server")
        #expect((args["id_or_name"] ?? "").isEmpty == false)
        #expect(args["action"] == "provisioning_status")
    }

    /// Every create hint that recommends `os_create` must show both required
    /// arguments (`resource`, `spec`) — the hint that used to read
    /// `os_create(subnet, {name, network_id: <this network's id>, cidr})` put
    /// the spec fields where the tool's arguments belong.
    @Test("create-in-create hints show resource and spec, not bare spec fields")
    func nestedCreateHintsShowToolArguments() async throws {
        let catalog = ResourceCatalog.phase1()
        var seen = 0
        for resource in ["network", "keypair", "security_group"] {
            let lines = await NextStepsTestSupport.createHints(resource: resource, catalog: catalog) ?? []
            for line in lines where recommendedTool(in: line) == "os_create" {
                let args = renderedArguments(in: line, tool: "os_create")
                #expect(args["resource"] != nil, "hint omits `resource` for os_create: \(line)")
                #expect(args["spec"] != nil, "hint omits `spec` for os_create: \(line)")
                seen += 1
            }
        }
        #expect(seen >= 3, "expected nested os_create hints from these three resources, saw \(seen)")
    }

    /// A volume create advertises nothing: the old boot-volume hint was
    /// unreachable (the create path never forwards `imageRef`) and named a spec
    /// field the server create path does not read as a device list.
    @Test("volume create emits no next_steps")
    func volumeHasNoCreateHint() async throws {
        let catalog = ResourceCatalog.phase1()
        let lines = await NextStepsTestSupport.createHints(resource: "volume", catalog: catalog,
                                                          imageRef: true)
        #expect(lines == nil, "volume must not advertise an unsupported step, got: \(String(describing: lines))")
    }

    /// Resources with no known follow-up must omit `next_steps` entirely.
    @Test("resources without a follow-up emit no next_steps")
    func unknownResourcesEmitNoHint() async throws {
        let catalog = ResourceCatalog.phase1()
        #expect(await NextStepsTestSupport.createHints(resource: "snapshot", catalog: catalog) == nil)
        #expect(await NextStepsTestSupport.createHints(resource: "not-a-resource", catalog: catalog) == nil)
    }
}
