import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
@testable import OpenStackMCPServer
import Logging

// MARK: - check subcommand (spec §11.3)

/// Tests the `check` core (`CheckReport.build`) against the fake: identity,
/// derived scopes, regions, services, and the access-rule gap comparison
/// (unrestricted → N/A).
@Suite("Check Subcommand", .timeLimit(.minutes(2)))
struct CheckTests {

    private func decodeToken(id: String, keystoneURL: URL) async throws -> ValidatedToken {
        let url = keystoneURL.appendingPathComponent("auth/tokens")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(id, forHTTPHeaderField: "X-Auth-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as! HTTPURLResponse).statusCode
        #expect(status == 200, "Token decode failed with \(status)")
        let token = try Token.decode(from: data)
        return ValidatedToken(token: token, scopes: deriveScopes(roles: token.roles))
    }

    @Test("check (admin token) shows project, write scope, regions, versions")
    func checkAdmin() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }

        guard let ft = await handle.state.mintToken(
            credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil
        ) else { throw OpenStackError(service: "test", status: 500, message: "mint failed") }

        let cloud = CloudEntry(name: "fake", authURL: URL(string: handle.url.absoluteString)!, regionName: nil)
        let logger = Logger(label: "check-test")
        let cache = Cache(maxEntries: 100)
        let transport = Transport(cloud: cloud, tokenSource: { ft.id }, logger: logger)
        defer { transport.syncShutdown() }
        let validator = TokenValidator(transport: transport, cache: cache, servedProjects: [])
        let client = OpenStackClient(cloud: cloud, transport: transport, cache: cache, validator: validator, logger: logger)

        let vt = try await decodeToken(id: ft.id, keystoneURL: handle.keystoneURL)
        let whoami = await client.whoami(vt)
        // The fake's catalog has RegionOne + RegionTwo and 6 service types.
        #expect(whoami.scopes.contains(.write), "admin token should have write scope")
        #expect(whoami.scopes.contains(.read))
        #expect(whoami.regions.contains("RegionOne"))
        #expect(whoami.services["compute"] != nil)

        // Build the report: no access rules on the fake token → unrestricted N/A
        // path is NOT taken (rules present? The fake token carries no access
        // rules, so accessRules is nil and unrestricted is nil → default to
        // "no rules → gaps N/A").
        let report = CheckReport.build(
            whoami: whoami,
            versions: ["compute": Microversion(major: 2, minor: 104), "volumev3": Microversion(major: 3, minor: 70)],
            neutronExtensions: ["address-group", "provider"],
            accessRules: nil,
            unrestricted: nil
        )
        let (stdout, _) = report.render()
        #expect(stdout.contains(whoami.project.name ?? whoami.project.id))
        #expect(stdout.contains("openstack:write"))
        #expect(stdout.contains("2.104"))
        #expect(stdout.contains("RegionOne"))
    }

    @Test("check with access-rule gaps reports missing rules per service")
    func checkGaps() {
        let whoami = Whoami(
            project: IdentityRef(id: "p", name: "P"),
            domain: IdentityRef(id: "d", name: "D"),
            roles: ["admin"],
            scopes: [.read, .write],
            expiresAt: Date().addingTimeInterval(3600),
            regions: ["RegionOne"],
            services: ["compute": ["nova"]]
        )
        // A token with ONLY a couple of compute rules → many gaps.
        let rules: [[String: String]] = [
            ["service": "compute", "method": "GET", "path": "/servers"],
            ["service": "compute", "method": "POST", "path": "/servers"],
        ]
        let report = CheckReport.build(
            whoami: whoami,
            versions: [:],
            neutronExtensions: [],
            accessRules: rules,
            unrestricted: false
        )
        let computeGap = report.gaps.first { $0.service == "compute" }
        #expect(computeGap != nil)
        #expect(computeGap!.noRules == false)
        // GET/POST /servers are present → not in the missing list.
        #expect(!computeGap!.missing.contains { $0.path == "/servers" && ($0.method == "GET" || $0.method == "POST") })
        // DELETE /servers/* is pinned but absent → reported missing.
        #expect(computeGap!.missing.contains { $0.path == "/servers/*" && $0.method == "DELETE" })
    }

    @Test("check with unrestricted token prints gaps-not-applicable")
    func checkUnrestricted() {
        let whoami = Whoami(
            project: IdentityRef(id: "p", name: "P"),
            domain: IdentityRef(id: "d", name: "D"),
            roles: ["admin"],
            scopes: [.read, .write],
            expiresAt: Date().addingTimeInterval(3600),
            regions: ["RegionOne"],
            services: ["compute": ["nova"]]
        )
        let report = CheckReport.build(
            whoami: whoami,
            versions: [:],
            neutronExtensions: [],
            accessRules: nil,
            unrestricted: true
        )
        #expect(report.unrestricted)
        #expect(report.gaps.isEmpty)
        let (stdout, _) = report.render()
        #expect(stdout.contains("unrestricted"))
    }
}
