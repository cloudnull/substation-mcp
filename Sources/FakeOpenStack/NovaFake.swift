import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Nova v2.1 implementation.
public struct NovaFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        // Real Nova returns the version list at GET / (root) or /nova, in the
        // {"versions":[...]} form, with the CURRENT entry carrying the max.
        // We serve it at /nova (the fake's version-doc path) in the real form.
        router.get("/nova") { _, _ in
            Self.jsonResponse(status: .ok, body: """
            {"versions":[{"id":"v2.0","status":"SUPPORTED","min_version":"2.1","endpoints":[{"region":"RegionOne","publicURL":"/nova"}]},{"id":"v2.1","status":"CURRENT","version":"2.104","min_version":"2.1","updated":"2024-01-01T00:00:00Z","endpoints":[{"region":"RegionOne","publicURL":"/nova"}]}]}
            """)
        }

        router.get("/nova/servers") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }

            let name = Self.queryParam("name", from: req)
            let status = Self.queryParam("status", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) }
            let marker = Self.queryParam("marker", from: req)

            let servers = await state.listServers(projectID: token.projectID, name: name, status: status, limit: limit, marker: marker)
            // Mirror real nova: the non-detail /servers list returns ONLY
            // id/name/links (no status/flavor/addresses). Those fields appear
            // only in /servers/detail. This keeps the fake faithful so the
            // client is forced to use the detail view for a full list.
            return Self.jsonResponse(status: .ok, body: Self.serversListJSONMinimal(servers: servers))
        }

        router.get("/nova/servers/detail") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            // Real nova /servers/detail supports the same name/status/limit/marker
            // filters as /servers.
            let name = Self.queryParam("name", from: req)
            let status = Self.queryParam("status", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) }
            let marker = Self.queryParam("marker", from: req)
            let servers = await state.listServers(projectID: token.projectID, name: name, status: status, limit: limit, marker: marker)
            return Self.jsonResponse(status: .ok, body: Self.serversListJSON(servers: servers, detail: true))
        }

        router.get("/nova/servers/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let server = await state.getServer(id: id, projectID: token.projectID) else {
                return Self.novaError(status: .notFound, message: "The resource could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.serverJSON(server: server))
        }

        router.post("/nova/servers") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }

            let body = try await Self.readBody(req)
            _ = body
            let server = await state.createServer(
                name: "created-server",
                projectID: token.projectID,
                flavorID: "1"
            )
            return Self.jsonResponse(status: .accepted, body: Self.serverJSON(server: server))
        }

        router.delete("/nova/servers/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteServer(id: id, projectID: token.projectID) else {
                return Self.novaError(status: .notFound, message: "The resource could not be found.")
            }
            return Response(status: .noContent)
        }

        router.post("/nova/servers/:id/action") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)

            // Console actions return 200 with a {"console":{...}} body. The url
            // is scoped to the requesting token (session), so each MCP session
            // only ever sees the console url it requested (spec §12).
            if body.contains("\"getVNCConsole\"") {
                let type = Self.parseConsoleType(body) ?? "novnc"
                let url = await state.consoleURL(tokenID: tokenID, serverID: id, type: type)
                return Self.jsonResponse(status: .ok, body: #"""
                {"console":{"type":"\#(type)","url":"\#(url)"}}
                """#)
            }
            if body.contains("\"getConsoleOutput\"") {
                return Self.jsonResponse(status: .ok, body: #"{"output":"fake-console-output\n"}"#)
            }

            let actions = ["start","stop","reboot","pause","unpause","suspend","resume","lock","unlock","shelve","unshelve","rescue","unrescue","resize","confirmResize","revertResize","rebuild","createImage","evacuate","liveMigrate","os-migrate","os-start","os-stop"]
            guard let actionKey = actions.first(where: { body.contains("\"" + $0 + "\"") }) else {
                return Self.novaError(status: .badRequest, message: "Unknown action")
            }

            // Actions that don't need server state (return 202)
            let noStateActions = ["rebuild","createImage","os-migrate","evacuate","liveMigrate","confirmResize","revertResize","resize"]
            if noStateActions.contains(actionKey) {
                return Response(status: .accepted)
            }

            let (success, error) = await state.serverActionWithSettle(id: id, projectID: token.projectID, action: actionKey)
            guard success else {
                return Self.novaError(status: .badRequest, message: error ?? "Action failed")
            }
            return Response(status: .accepted)
        }

        router.get("/nova/flavors") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            let flavors = await state.flavors
            let items = flavors.map { f in
                """
                {"id":"\(f.id)","name":"\(f.name)","vcpus":\(f.vcpus),"ram":\(f.ram),"disk":\(f.disk),"links":[{"rel":"bookmark","href":"/nova/flavors/\(f.id)"}]}
                """
            }
            return Self.jsonResponse(status: .ok, body: """
            {"flavors":[\(items.joined(separator: ","))]}
            """)
        }

        router.get("/nova/flavors/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            let id = ctx.parameters.get("id") ?? ""
            guard let f = await state.flavors.first(where: { $0.id == id }) else {
                return Self.novaError(status: .notFound, message: "No flavor found matching '\(id)'")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"flavor":{"id":"\(f.id)","name":"\(f.name)","vcpus":\(f.vcpus),"ram":\(f.ram),"disk":\(f.disk),"links":[{"rel":"bookmark","href":"/nova/flavors/\(f.id)"}]}}
            """)
        }

        router.get("/nova/flavors/:id/os-extra_specs") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            let id = ctx.parameters.get("id") ?? ""
            guard await state.flavors.contains(where: { $0.id == id }) else {
                return Self.novaError(status: .notFound, message: "No flavor found matching '\(id)'")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"extra_specs":{}"
            """)
        }

        router.get("/nova/os-availability-zone") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            return Self.jsonResponse(status: .ok, body: """
            {"availabilityZoneInfo":[{"zoneState":{"available":true},"zoneName":"nova"},{"zoneState":{"available":true},"zoneName":"nova-r2"}]}
            """)
        }

        router.get("/nova/os-quota-sets/:projectId") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            let pid = ctx.parameters.get("projectId") ?? ""
            return Self.jsonResponse(status: .ok, body: """
            {"quota_set":{"id":"\(pid)","instances":10,"cores":20,"ram":51200,"metadata_items":128,"injected_files":5,"key_pairs":5,"security_groups":10,"security_group_rules":200}}
            """)
        }

        // MARK: - Quota update

        router.put("/nova/os-quota-sets/:projectId") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            let pid = ctx.parameters.get("projectId") ?? ""
            _ = try await Self.readBody(req)
            // Echo back the quota set with the project ID
            return Self.jsonResponse(status: .ok, body: """
            {"quota_set":{"id":"\(pid)","instances":10,"cores":20,"ram":51200,"metadata_items":128,"injected_files":5,"key_pairs":5,"security_groups":10,"security_group_rules":200}}
            """)
        }

        // MARK: - Keypairs

        router.get("/nova/os-keypairs") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            // Nova wraps each keypair in a {"keypair": {...}} envelope
            return Self.jsonResponse(status: .ok, body: """
            {"keypairs":[{"keypair":{"name":"test-key","fingerprint":"AA:BB:CC:DD","public_key":"ssh-rsa AAAA test@host","type":"rsa"}}]}
            """)
        }

        router.post("/nova/os-keypairs") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            let body = try await Self.readBody(req)
            struct KeyPairReq: Decodable {
                struct KP: Decodable { let name: String; let public_key: String? }
                let keypair: KP
            }
            guard let parsed = try? JSONDecoder().decode(KeyPairReq.self, from: body.data(using: .utf8)!) else {
                return Self.novaError(status: .badRequest, message: "Invalid request")
            }
            return Self.jsonResponse(status: .accepted, body: """
            {"keypair":{"name":"\(parsed.keypair.name)","fingerprint":"AA:BB:CC:EE","public_key":"\(parsed.keypair.public_key ?? "ssh-rsa AAAA generated")","type":"rsa"}}
            """)
        }

        router.delete("/nova/os-keypairs/:name") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            return Self.jsonResponse(status: .noContent, body: "")
        }

        // MARK: - Server groups

        router.get("/nova/os-server-groups") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            return Self.jsonResponse(status: .ok, body: """
            {"server_groups":[{"id":"sg-001","name":"test-group","policy":"soft-affinity","members":[]}]}
            """)
        }

        // MARK: - Hypervisors (admin only)

        router.get("/nova/os-hypervisors") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            // Admin check: only allow if token has admin role
            if !token.roles.contains("admin") {
                return Self.novaError(status: .forbidden, message: "Admin access required")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"hypervisors":[{"id":1,"hypervisor_hostname":"compute-01","host_ip":"10.0.0.1","state":"up","status":"enabled","hypervisor_type":"QEMU","hypervisor_version":7002022,"service":{"id":1,"host":"compute-01","disabled_reason":null},"vcpus":32,"memory_mb":65536,"local_gb":1000,"vcpus_used":16,"memory_mb_used":32768,"local_gb_used":500,"free_ram_mb":32768,"free_disk_gb":500,"current_workload":0,"running_vms":16,"disk_available_least":490}]}
            """)
        }

        router.get("/nova/os-hypervisors/:host") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            if !token.roles.contains("admin") {
                return Self.novaError(status: .forbidden, message: "Admin access required")
            }
            let host = ctx.parameters.get("host") ?? ""
            return Self.jsonResponse(status: .ok, body: """
            {"hypervisor":{"id":1,"hypervisor_hostname":"\(host)","host_ip":"10.0.0.1","state":"up","status":"enabled","hypervisor_type":"QEMU","hypervisor_version":7002022,"service":{"id":1,"host":"\(host)","disabled_reason":null},"vcpus":32,"memory_mb":65536,"local_gb":1000,"vcpus_used":16,"memory_mb_used":32768,"local_gb_used":500,"free_ram_mb":32768,"free_disk_gb":500,"current_workload":0,"running_vms":16,"disk_available_least":490}}
            """)
        }

        // MARK: - Compute services (admin only)

        router.get("/nova/os-services") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            if !token.roles.contains("admin") {
                return Self.novaError(status: .forbidden, message: "Admin access required")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"services":[{"id":1,"host":"compute-01","binary":"nova-compute","zone":"internal","status":"enabled","state":"up","disabled_reason":null}]}
            """)
        }

        // MARK: - Volume attachments

        router.post("/nova/servers/:id/os-volume_attachments") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            let serverID = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            let attBody = Self.objectForKey("os-attach-volume", in: body) ?? body
            let volumeID = Self.extractString("volumeId", from: attBody) ?? Self.extractString("volume_id", from: attBody) ?? ""
            let device = Self.extractString("device", from: attBody) ?? "/dev/vda"
            guard let attID = await state.attachVolume(serverID: serverID, volumeID: volumeID, device: device, projectID: token.projectID) else {
                return Self.novaError(status: .notFound, message: "volume or server not found")
            }
            return Self.jsonResponse(status: .accepted, body: """
            {"volumeAttachment":{"id":"\(attID)","serverId":"\(serverID)","volumeId":"\(volumeID)","status":"attaching","device":"\(device)"}}
            """)
        }

        router.delete("/nova/servers/:id/os-volume_attachments/:attID") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            let serverID = ctx.parameters.get("id") ?? ""
            let attID = ctx.parameters.get("attID") ?? ""
            guard await state.detachVolume(attachmentID: attID, serverID: serverID, projectID: token.projectID) else {
                return Self.novaError(status: .notFound, message: "attachment not found")
            }
            return Self.jsonResponse(status: .accepted, body: "")
        }

        // MARK: - Interface attachments

        router.post("/nova/servers/:id/os-interface-attach") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            let serverID = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            let attBody = Self.objectForKey("os-interface-attach", in: body) ?? body
            let netID = Self.extractString("net_id", from: attBody)
            let subnetID = Self.extractString("subnet_id", from: attBody)
            let portID = Self.extractString("port", from: attBody)
            guard let port = await state.attachInterface(serverID: serverID, networkID: netID, subnetID: subnetID, portID: portID, projectID: token.projectID) else {
                return Self.novaError(status: .notFound, message: "network, subnet, or port not found")
            }
            let portRec = await state.getPort(id: port, projectID: token.projectID)
            let ips = portRec?.fixedIPs.map { "\"\($0.ip)\"" }.joined(separator: ",") ?? ""
            return Self.jsonResponse(status: .accepted, body: """
            {"interfaceAttachment":{"port":"\(port)","net_id":"\(portRec?.networkID ?? "")","fixed_ips":[\(ips)]}}
            """)
        }

        router.post("/nova/servers/:id/os-interface-detach") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            let serverID = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            let detBody = Self.objectForKey("os-interface-detach", in: body) ?? body
            let portID = Self.extractString("port", from: detBody) ?? ""
            guard await state.detachInterface(serverID: serverID, portID: portID, projectID: token.projectID) else {
                return Self.novaError(status: .notFound, message: "port not found on server")
            }
            return Self.jsonResponse(status: .accepted, body: "")
        }

        // MARK: - Update server (POST /servers/:id)

        router.post("/nova/servers/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            let serverID = ctx.parameters.get("id") ?? ""
            let servers = await state.listServers(projectID: token.projectID)
            guard let server = servers.first(where: { $0.id == serverID }) else {
                return Self.novaError(status: .notFound, message: "Server not found")
            }
            return Self.jsonResponse(status: .accepted, body: Self.serverJSON(server: server))
        }
    }

    /// Extract a query parameter from the request URI.
    static func queryParam(_ key: String, from req: Request) -> String? {
        req.uri.queryParameters[Substring(key)].map { String($0) }
    }

    /// Extract the `"type":"..."` value from a getVNCConsole request body
    /// (e.g. `{"getVNCConsole":{"type":"vnc"}}`).
    static func parseConsoleType(_ body: String) -> String? {
        let marker = "\"type\":\""
        guard let start = body.range(of: marker)?.upperBound else { return nil }
        let rest = body[start...]
        guard let end = rest.range(of: "\"") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    static func readBody(_ req: Request) async throws -> String {
        var data = Data()
        for try await buffer in req.body {
            data.append(contentsOf: buffer.readableBytesView)
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func objectForKey(_ key: String, in json: String) -> String? {
        let pattern = "\"\(key)\":"
        guard let start = json.range(of: pattern) else { return nil }
        let afterColon = json[start.upperBound...]
        guard let open = afterColon.firstIndex(of: "{") else { return nil }
        var depth = 0
        for (idx, ch) in afterColon.enumerated() {
            _ = idx
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let end = afterColon.index(afterColon.startIndex, offsetBy: idx)
                    return String(afterColon[open...end])
                }
            }
        }
        return nil
    }

    static func extractString(_ key: String, from json: String) -> String? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if afterColon.hasPrefix("\"") {
            let rest = afterColon.dropFirst()
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[rest.startIndex..<close])
        }
        return nil
    }

    /// The real-nova non-detail list shape: only id/name/links per server.
    static func serversListJSONMinimal(servers: [FakeState.FakeServer]) -> String {
        let items = servers.map { server -> String in
            "{\"id\":\"\(server.id)\",\"name\":\"\(server.name)\",\"links\":[{\"rel\":\"self\",\"href\":\"/nova/servers/\(server.id)\"},{\"rel\":\"bookmark\",\"href\":\"/nova/servers\"}]}"
        }
        return "{\"servers\":[\(items.joined(separator: ","))]}"
    }

    static func serversListJSON(servers: [FakeState.FakeServer], detail: Bool = false) -> String {
        let items = servers.map { server -> String in
            let keyName = server.keyName.map { "\"\($0)\"" } ?? "null"
            let secGroups = server.securityGroups.map { "{\"name\":\"\($0.value)\"}" }.joined(separator: ",")
            let addr = addressesJSON(server.addresses)
            var obj = "{\"id\":\"\(server.id)\",\"name\":\"\(server.name)\",\"status\":\"\(server.status)\",\"flavor\":{\"id\":\"\(server.flavorID)\",\"links\":[{\"rel\":\"bookmark\",\"href\":\"/nova/flavors/\(server.flavorID)\"}]},\"key_name\":\(keyName),\"addresses\":\(addr),\"security_groups\":[\(secGroups)]"
            if detail {
                let imageID = server.imageID.map { "\"\($0)\"" } ?? "null"
                obj += ",\"image\":{\"id\":\(imageID),\"links\":[]},\"metadata\":{},\"progress\":0"
            }
            obj += ",\"created\":\"\(server.created.ISO8601Format())\"}"
            return obj
        }
        return "{\"servers\":[\(items.joined(separator: ","))]}"
    }

    static func serverJSON(server: FakeState.FakeServer) -> String {
        let image = server.imageID.map { "\"\($0)\"" } ?? "null"
        let userData = server.userData.map { ",\"user_data\":\"\($0)\"" } ?? ""
        let secGroups = server.securityGroups.map { "{\"name\":\"\($0.value)\"}" }.joined(separator: ",")
        return """
        {"server":{"id":"\(server.id)","name":"\(server.name)","status":"\(server.status)","flavor":{"id":"\(server.flavorID)","links":[{"rel":"bookmark","href":"/nova/flavors/\(server.flavorID)"}]},"image":{"id":\(image),"links":[]},"key_name":\(server.keyName.map { "\"\($0)\"" } ?? "null"),"addresses":\(addressesJSON(server.addresses)),"security_groups":[\(secGroups)],"metadata":{},"created":"\(server.created.ISO8601Format())","updated":\(server.updated.map { "\"\($0.ISO8601Format())\"" } ?? "null")\(userData)}}
        """
    }

    /// Produce Nova-format addresses JSON: `{network: [{addr, version, OS-EXT-IPS:type}]}`.
    /// The fake stores addresses as `{network: {ip: port?}}`; we flatten to the Nova object-array form.
    static func addressesJSON(_ addresses: [String: [String: String]]) -> String {
        let items: [String] = addresses.map { network, ips in
            let addrObjs: [String] = ips.keys.map { ip in
                "{\"addr\":\"\(ip)\",\"version\":4,\"OS-EXT-IPS:type\":\"fixed\"}"
            }
            return "\"\(network)\":[\(addrObjs.joined(separator: ","))]"
        }
        if items.isEmpty { return "{}" }
        return "{\(items.joined(separator: ","))}"
    }

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: body))
        )
    }

    static func novaError(status: HTTPResponse.Status, message: String) -> Response {
        let code: Int
        switch status {
        case .badRequest: code = 400
        case .unauthorized: code = 401
        case .forbidden: code = 403
        case .notFound: code = 404
        default: code = 500
        }
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: """
            {"fault":{"code":\(code),"title":"\(message)","explanation":""}}
            """))
        )
    }
}
