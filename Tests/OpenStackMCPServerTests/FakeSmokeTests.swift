import Testing
import Foundation
import FoundationNetworking
import OpenStackClient
import FakeOpenStack

@Suite("FakeOpenStack Smoke Tests")
struct FakeSmokeTests {
    @Test("mint and validate token via fake Keystone", .timeLimit(.minutes(1)))
    func mintAndValidate() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }

        let mintBody = """
        {"auth":{"identity":{"methods":["application_credential"],"applicationCredential":{"id":"fake-cred-admin","secret":"secret-admin"}}}}
        """

        var request = URLRequest(url: handle.keystoneURL.appendingPathComponent("auth/tokens"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = mintBody.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpStatus = (response as! HTTPURLResponse).statusCode
        #expect(httpStatus == 201, "Expected 201, got \(httpStatus). Body: \(String(data: data, encoding: .utf8) ?? "nil")")

        struct MintedToken: Decodable {
            struct Token: Decodable { let id: String; let expires_at: String }
            let token: Token
        }
        let minted = try JSONDecoder().decode(MintedToken.self, from: data)
        let tokenID = minted.token.id
        #expect(!tokenID.isEmpty)

        var validateRequest = URLRequest(url: handle.keystoneURL.appendingPathComponent("auth/tokens"))
        validateRequest.httpMethod = "GET"
        validateRequest.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")

        let (validateData, validateResponse) = try await URLSession.shared.data(for: validateRequest)
        let validateStatus = (validateResponse as! HTTPURLResponse).statusCode
        #expect(validateStatus == 200, "Expected 200, got \(validateStatus). Body: \(String(data: validateData, encoding: .utf8) ?? "nil")")

        struct ValidatedToken: Decodable {
            struct Token: Decodable {
                let id: String
                let project: Project
                let roles: [String]
                struct Project: Decodable { let id: String; let name: String }
            }
            let token: Token
        }
        let validated = try JSONDecoder().decode(ValidatedToken.self, from: validateData)
        #expect(validated.token.id == tokenID)
        #expect(validated.token.project.id == "proj-one")
        #expect(validated.token.roles.contains("admin"))
    }

    @Test("reject bad credentials", .timeLimit(.minutes(1)))
    func rejectBadCredentials() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }

        let mintBody = """
        {"auth":{"identity":{"methods":["application_credential"],"applicationCredential":{"id":"fake-cred-admin","secret":"wrong-secret"}}}}
        """

        var request = URLRequest(url: handle.keystoneURL.appendingPathComponent("auth/tokens"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = mintBody.data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        #expect(status == 401)
    }

    @Test("list servers via fake Nova", .timeLimit(.minutes(1)))
    func listServers() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }

        let tokenID = try await Self.mintToken(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")

        var listRequest = URLRequest(url: handle.url.appendingPathComponent("nova/servers"))
        listRequest.httpMethod = "GET"
        listRequest.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")

        let (listData, listResponse) = try await URLSession.shared.data(for: listRequest)
        let listStatus = (listResponse as! HTTPURLResponse).statusCode
        let bodyStr = String(data: listData, encoding: .utf8) ?? "nil"
        #expect(listStatus == 200, "Expected 200, got \(listStatus). Body: \(bodyStr)")

        struct ServerList: Decodable {
            struct Server: Decodable { let id: String; let name: String; let status: String }
            let servers: [Server]
        }
        let servers = try JSONDecoder().decode(ServerList.self, from: listData)
        #expect(servers.servers.count >= 3)
    }

    @Test("tenant isolation: proj-one cannot see proj-two servers", .timeLimit(.minutes(1)))
    func tenantIsolation() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }

        let adminToken = try await Self.mintToken(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        let serverID = try await Self.createServer(handle: handle, tokenID: adminToken, name: "isolated-server")

        let adminServers = try await Self.listServerIDs(handle: handle, tokenID: adminToken)
        #expect(adminServers.contains(serverID))

        let twoToken = try await Self.mintToken(handle: handle, credID: "fake-cred-two", secret: "secret-two")
        let twoServerID = try await Self.createServer(handle: handle, tokenID: twoToken, name: "proj-two-server")

        let adminServers2 = try await Self.listServerIDs(handle: handle, tokenID: adminToken)
        #expect(!adminServers2.contains(twoServerID))

        let getURL = handle.url.appendingPathComponent("nova/servers/\(twoServerID)")
        var getRequest = URLRequest(url: getURL)
        getRequest.setValue(adminToken, forHTTPHeaderField: "X-Auth-Token")
        let (_, getResponse) = try await URLSession.shared.data(for: getRequest)
        let getStatus = (getResponse as! HTTPURLResponse).statusCode
        #expect(getStatus == 404)
    }

    @Test("server lifecycle: create, action, delete", .timeLimit(.minutes(1)))
    func serverLifecycle() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }

        let tokenID = try await Self.mintToken(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")

        let serverID = try await Self.createServer(handle: handle, tokenID: tokenID, name: "lifecycle-server")

        var serverRequest = URLRequest(url: handle.url.appendingPathComponent("nova/servers/\(serverID)"))
        serverRequest.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
        let (serverData, _) = try await URLSession.shared.data(for: serverRequest)
        struct ServerResp: Decodable { struct Server: Decodable { let id: String; let status: String }; let server: Server }
        let server = try JSONDecoder().decode(ServerResp.self, from: serverData)
        #expect(server.server.status == "BUILD")

        try await Self.performAction(handle: handle, tokenID: tokenID, serverID: serverID, action: "start")

        let (activeData, _) = try await URLSession.shared.data(for: serverRequest)
        let activeServer = try JSONDecoder().decode(ServerResp.self, from: activeData)
        #expect(activeServer.server.status == "ACTIVE")

        try await Self.performAction(handle: handle, tokenID: tokenID, serverID: serverID, action: "stop")

        let (stoppedData, _) = try await URLSession.shared.data(for: serverRequest)
        let stoppedServer = try JSONDecoder().decode(ServerResp.self, from: stoppedData)
        #expect(stoppedServer.server.status == "SHUTOFF")

        var deleteRequest = URLRequest(url: handle.url.appendingPathComponent("nova/servers/\(serverID)"))
        deleteRequest.httpMethod = "DELETE"
        deleteRequest.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
        let (_, deleteResponse) = try await URLSession.shared.data(for: deleteRequest)
        #expect((deleteResponse as! HTTPURLResponse).statusCode == 204)

        let (_, goneResponse) = try await URLSession.shared.data(for: serverRequest)
        #expect((goneResponse as! HTTPURLResponse).statusCode == 404)
    }

    // MARK: - Static helpers

    static func mintToken(handle: FakeHandle, credID: String, secret: String) async throws -> String {
        let mintBody = """
        {"auth":{"identity":{"methods":["application_credential"],"applicationCredential":{"id":"\(credID)","secret":"\(secret)"}}}}
        """
        var mintRequest = URLRequest(url: handle.keystoneURL.appendingPathComponent("auth/tokens"))
        mintRequest.httpMethod = "POST"
        mintRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        mintRequest.httpBody = mintBody.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: mintRequest)
        let status = (response as! HTTPURLResponse).statusCode
        guard status == 201 else {
            throw NSError(domain: "FakeSmokeTests", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Mint failed with \(status): \(String(data: data, encoding: .utf8) ?? "")"])
        }
        struct MintedToken: Decodable { struct Token: Decodable { let id: String }; let token: Token }
        return try JSONDecoder().decode(MintedToken.self, from: data).token.id
    }

    static func createServer(handle: FakeHandle, tokenID: String, name: String) async throws -> String {
        let body = """
        {"server":{"name":"\(name)","flavorRef":{"id":"1"},"imageRef":{"id":"img-1"}}}
        """
        var request = URLRequest(url: handle.url.appendingPathComponent("nova/servers"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard status == 202 else {
            throw NSError(domain: "FakeSmokeTests", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Create failed with \(status): \(String(data: data, encoding: .utf8) ?? "")"])
        }
        struct ServerResp: Decodable { struct Server: Decodable { let id: String }; let server: Server }
        return try JSONDecoder().decode(ServerResp.self, from: data).server.id
    }

    static func listServerIDs(handle: FakeHandle, tokenID: String) async throws -> [String] {
        var request = URLRequest(url: handle.url.appendingPathComponent("nova/servers"))
        request.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard status == 200 else {
            throw NSError(domain: "FakeSmokeTests", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "List failed with \(status): \(String(data: data, encoding: .utf8) ?? "")"])
        }
        struct ServerList: Decodable { struct Server: Decodable { let id: String }; let servers: [Server] }
        return try JSONDecoder().decode(ServerList.self, from: data).servers.map(\.id)
    }

    static func performAction(handle: FakeHandle, tokenID: String, serverID: String, action: String) async throws {
        let body = """
        {"\(action)":null}
        """
        var request = URLRequest(url: handle.url.appendingPathComponent("nova/servers/\(serverID)/action"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard status == 202 else {
            throw NSError(domain: "FakeSmokeTests", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Action failed with \(status): \(String(data: data, encoding: .utf8) ?? "")"])
        }
    }
}
