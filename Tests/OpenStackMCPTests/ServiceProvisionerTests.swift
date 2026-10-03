import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
@testable import OpenStackMCPServer
import Logging

// MARK: - service user + application credential provisioning (idempotency)

/// Drives `ServiceProvisioner.ensureServiceIdentity()` against the fake Keystone
/// with an admin token. Run once → creates user (service domain) + grants admin
/// + creates the app credential (returns its secret); run again → idempotent
/// (same ids, no duplicates, no new secret — the existing app-cred's secret is
/// not recoverable, so `appCredSecret` is nil on reuse).
@Suite("Service Provisioner", .timeLimit(.minutes(2)))
struct ServiceProvisionerTests {

    /// Mint an admin token and return its id (used as X-Auth-Token).
    private func adminToken(handle: FakeHandle) async throws -> String {
        guard let ft = await handle.state.mintToken(
            credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil
        ) else {
            throw OpenStackError(service: "test", status: 500, message: "mint failed")
        }
        return ft.id
    }

    private func makeProvisioner(
        handle: FakeHandle,
        token: String,
        username: String = "substation",
        appCredName: String = "substation-cred"
    ) -> (provisioner: ServiceProvisioner, transport: Transport) {
        let cloud = CloudEntry(name: "fake", authURL: URL(string: handle.url.absoluteString)!, regionName: nil)
        let logger = Logger(label: "provision-test")
        let transport = Transport(cloud: cloud, tokenSource: { token }, logger: logger)
        let provisioner = ServiceProvisioner(
            username: username,
            domainName: "service",
            appCredName: appCredName,
            roles: ["admin"],
            adminToken: token,
            transport: transport,
            logger: logger
        )
        return (provisioner, transport)
    }

    @Test("provision is idempotent: creates user+app-cred once, reuses on second run")
    func idempotent() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }

        let token = try await adminToken(handle: handle)
        let (provisioner, transport) = makeProvisioner(handle: handle, token: token)
        defer { transport.syncShutdown() }

        // First run: creates the user + app-cred, returns the secret.
        let first = try await provisioner.ensureServiceIdentity()
        #expect(!first.userID.isEmpty)
        #expect(first.username == "substation")
        #expect(first.domainName == "service")
        #expect(!first.appCredID.isEmpty)
        #expect(first.appCredSecret != nil, "first run must return the created app-cred secret")
        #expect(first.appCredSecret!.count >= 32, "secret should be a non-trivial value")
        #expect(!first.userReused, "first run creates the user")
        #expect(!first.appCredReused, "first run creates the app-cred")

        // Verify the state: user exists in the service domain with the admin role.
        let svcDomain = await handle.state.domain(name: "service")
        #expect(svcDomain != nil)
        let user = await handle.state.identityUser(name: "substation", domainID: svcDomain!.id)
        #expect(user != nil)
        #expect(await handle.state.roleAssigned(userID: user!.id, roleID: (await handle.state.role(name: "admin"))!.id, domainID: svcDomain!.id))
        let cred = await handle.state.appCred(name: "substation-cred", userID: user!.id)
        #expect(cred != nil)
        #expect(cred?.id == first.appCredID)

        let userCountAfterFirst = await handle.state.listIdentityUsers().count
        let credCountAfterFirst = await handle.state.appCreds(userID: user!.id).count

        // Second run: same user + app-cred ids, all reused, no new secret.
        let second = try await provisioner.ensureServiceIdentity()
        #expect(second.userID == first.userID, "user id must be stable")
        #expect(second.appCredID == first.appCredID, "app-cred id must be stable")
        #expect(second.userReused, "second run reuses the user")
        #expect(second.appCredReused, "second run reuses the app-cred")
        #expect(second.appCredSecret == nil, "reused app-cred does not return its secret")

        let userCountAfterSecond = await handle.state.listIdentityUsers().count
        let credCountAfterSecond = await handle.state.appCreds(userID: user!.id).count
        #expect(userCountAfterSecond == userCountAfterFirst, "no duplicate user")
        #expect(credCountAfterSecond == credCountAfterFirst, "no duplicate app-cred")
    }

    @Test("provision can target a custom username in the service domain")
    func customUsername() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }

        let token = try await adminToken(handle: handle)
        let (provisioner, transport) = makeProvisioner(handle: handle, token: token, username: "substation-mcp", appCredName: "smcp-cred")
        defer { transport.syncShutdown() }

        let result = try await provisioner.ensureServiceIdentity()
        #expect(result.username == "substation-mcp")
        let svcDomain = await handle.state.domain(name: "service")
        let user = await handle.state.identityUser(name: "substation-mcp", domainID: svcDomain!.id)
        #expect(user != nil)
        #expect(result.userID == user!.id)
    }

    @Test("provision rejects a non-admin (invalid) token")
    func rejectsBadToken() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        // A token id that was never minted → the fake Keystone 401s.
        let (provisioner, transport) = makeProvisioner(handle: handle, token: "fake-tok-0000")
        defer { transport.syncShutdown() }
        await #expect(throws: (any Error).self) {
            _ = try await provisioner.ensureServiceIdentity()
        }
    }
}
