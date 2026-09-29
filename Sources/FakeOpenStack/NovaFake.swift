import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Nova v2.1 implementation.
public struct NovaFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        router.get("/nova") { _, _ in
            Self.jsonResponse(status: .ok, body: """
            {"version":{"id":"v2.1","status":"stable","max_version":"2.104","min_version":"2.1","updated":"2024-01-01T00:00:00Z","endpoints":[{"region":"RegionOne","publicURL":"/nova"}]}}
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
            return Self.jsonResponse(status: .ok, body: Self.serversListJSON(servers: servers))
        }

        router.get("/nova/servers/detail") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            let servers = await state.listServers(projectID: token.projectID)
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

            let actions = ["start","stop","reboot","pause","unpause","suspend","resume","lock","unlock","shelve","unshelve","rescue","unrescue","resize","confirmResize","revertResize","rebuild","createImage","evacuate","liveMigrate","os-migrate","os-start","os-stop"]
            guard let actionKey = actions.first(where: { body.contains("\"" + $0 + "\"") }) else {
                return Self.novaError(status: .badRequest, message: "Unknown action")
            }

            // Actions that don't need server state (return 202)
            let noStateActions = ["rebuild","createImage","os-start","os-stop","os-migrate","evacuate","liveMigrate","confirmResize","revertResize","resize"]
            if noStateActions.contains(actionKey) {
                return Response(status: .accepted)
            }

            let (success, error) = await state.serverAction(id: id, projectID: token.projectID, action: actionKey)
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
            let body = try await Self.readBody(req)
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
            return Self.jsonResponse(status: .ok, body: """
            {"keypairs":[{"name":"test-key","fingerprint":"AA:BB:CC:DD","public_key":"ssh-rsa AAAA test@host","type":"rsa"}]}
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
            {"hypervisors":[{"host":"compute-01","hypervisor_hostname":"compute-01","hypervisor_version":"15.0","state":"up","status":"enabled","maxmemory":65536,"current_workload":32768,"disk_total":1000,"disk_used":500,"cpu":64,"cpus":32,"running_vcpus":16}]}
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
            {"hypervisor":{"host":"\(host)","hypervisor_hostname":"\(host)","hypervisor_version":"15.0","state":"up","status":"enabled","maxmemory":65536,"current_workload":32768,"disk_total":1000,"disk_used":500,"cpu":64,"cpus":32,"running_vcpus":16}}
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
            _ = token
            let serverID = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            return Self.jsonResponse(status: .accepted, body: """
            {"volumeAttachment":{"id":"att-001","serverId":"\(serverID)","volumeId":"vol-001","status":"attaching","device":"/dev/vdb"}}
            """)
        }

        router.delete("/nova/servers/:id/os-volume_attachments/:attID") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            return Self.jsonResponse(status: .accepted, body: "")
        }

        // MARK: - Interface attachments

        router.post("/nova/servers/:id/os-interface-attach") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
            return Self.jsonResponse(status: .accepted, body: """
            {"interfaceAttachment":{"port":"port-001","net_id":"net-001","fixed_ips":["10.0.0.5"]}}
            """)
        }

        router.post("/nova/servers/:id/os-interface-detach") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.novaError(status: .unauthorized, message: "Unauthorized")
            }
            _ = token
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

    static func readBody(_ req: Request) async throws -> String {
        var data = Data()
        for try await buffer in req.body {
            data.append(contentsOf: buffer.readableBytesView)
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func serversListJSON(servers: [FakeState.FakeServer], detail: Bool = false) -> String {
        let items = servers.map { server -> String in
            let keyName = server.keyName.map { "\"\($0)\"" } ?? "null"
            let secGroups = server.securityGroups.map { "\"\($0.value)\"" }.joined(separator: ",")
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
        return """
        {"server":{"id":"\(server.id)","name":"\(server.name)","status":"\(server.status)","flavor":{"id":"\(server.flavorID)","links":[{"rel":"bookmark","href":"/nova/flavors/\(server.flavorID)"}]},"image":{"id":\(image),"links":[]},"key_name":\(server.keyName.map { "\"\($0)\"" } ?? "null"),"addresses":\(addressesJSON(server.addresses)),"security_groups":[\(server.securityGroups.map { "\"\($0)\"" }.joined(separator: ","))],"metadata":{},"created":"\(server.created.ISO8601Format())","updated":\(server.updated.map { "\"\($0.ISO8601Format())\"" } ?? "null")}}
        """
    }

    static func addressesJSON(_ addresses: [String: [String: String]]) -> String {
        let items = addresses.map { (network, ips) in
            "\"\(network)\":[\(ips.values.map { "\"\($0)\"" }.joined(separator: ","))]"
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
