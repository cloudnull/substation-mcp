import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import MCP
@testable import OpenStackMCPServer
import Logging

// MARK: - Audit logging (spec §12)

/// A `LogHandler` that records every record it is asked to write, keyed by
/// level. Used to assert that a mutating tool call produced exactly one audit
/// record (category=audit) carrying the required fields.
final class AuditCapture: LogHandler, @unchecked Sendable {
    struct Record: Sendable {
        let level: Logger.Level
        let message: String
        let metadata: [String: Logger.MetadataValue]
    }
    private let lock = NSLock()
    private var _records: [Record] = []

    let id: Logger.MetadataValue = .string("audit-capture")
    var metadata: Logger.Metadata = Logger.Metadata()
    var logLevel: Logger.Level = .trace

    init() {}

    subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set {
            if let newValue { metadata[key] = newValue } else { metadata.removeValue(forKey: key) }
        }
    }

    var records: [Record] {
        lock.lock(); defer { lock.unlock() }
        return _records
    }

    var auditRecords: [Record] {
        records.filter { $0.metadata["category"]?.description == "audit" }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
        lock.lock()
        _records.append(Record(level: level, message: message.description, metadata: merged))
        lock.unlock()
    }
}

@Suite("Audit Logging", .timeLimit(.minutes(2)))
struct AuditTests {

    /// Decode a token via the fake Keystone's auth/tokens endpoint.
    private func decodeToken(id: String, keystoneURL: URL) async throws -> ValidatedToken {
        let url = keystoneURL.appendingPathComponent("auth/tokens")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(id, forHTTPHeaderField: "X-Auth-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as! HTTPURLResponse).statusCode
        #expect(status == 200, "Token decode failed with \(status)")
        let token = try Token.decode(from: data)
        let scopes = deriveScopes(roles: token.roles)
        return ValidatedToken(token: token, scopes: scopes)
    }

    /// Build a `ToolRegistry` (admin, write-scoped) over a running fake, with a
    /// capturing logger, and return (registry, capture).
    private func makeAuditRegistry(
        handle: FakeHandle,
        credID: String,
        secret: String,
        auditEnabled: Bool
    ) async throws -> (registry: ToolRegistry, capture: AuditCapture) {
        let capture = AuditCapture()
        let logger = Logger(label: "audit-test") { _ in capture }

        guard let ft = await handle.state.mintToken(credID: credID, secret: secret, domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "test", status: 500, message: "mint failed")
        }
        let vt = try await decodeToken(id: ft.id, keystoneURL: handle.keystoneURL)
        let whoami = Whoami(
            project: IdentityRef(id: ft.projectID, name: ft.projectName),
            domain: IdentityRef(id: ft.domainID, name: ft.domainName),
            roles: ft.roles,
            scopes: deriveScopes(roles: ft.roles),
            expiresAt: ft.expiresAt,
            regions: ["RegionOne"],
            services: ["compute": ["nova"], "network": ["neutron"]]
        )
        let identity = RequestIdentity(vt: vt, whoami: whoami, cloudName: "fake")

        let cloud = CloudEntry(name: "fake", authURL: URL(string: handle.url.absoluteString)!, regionName: nil)
        let cache = Cache(maxEntries: 100)
        let transport = Transport(cloud: cloud, tokenSource: { ft.id }, logger: logger)
        let validator = TokenValidator(transport: transport, cache: cache, servedProjects: [])
        let client = OpenStackClient(cloud: cloud, transport: transport, cache: cache, validator: validator, logger: logger)

        let registry = ToolRegistry(
            client: client,
            catalog: ResourceCatalog.phase1(),
            policy: Policy(),
            identity: identity,
            logger: logger,
            auditEnabled: auditEnabled
        )
        return (registry, capture)
    }

    @Test("a mutating tool call emits exactly one audit record with required fields")
    func mutatingCallEmitsAuditRecord() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let (registry, capture) = try await makeAuditRegistry(
            handle: handle, credID: "fake-cred-admin", secret: "secret-admin", auditEnabled: true
        )

        // os_delete with dry_run:true does not actually delete; it still
        // exercises the mutating dispatch path and the audit hook.
        let params = CallTool.Parameters(
            name: "os_delete",
            arguments: [
                "resource": .string("server"),
                "id_or_name": .string("does-not-exist"),
                "dry_run": .bool(true),
            ]
        )
        let server = await registry.makeServer()
        defer { Task { await server.stop() } }
        let result = try await registry.dispatch(params, server: server)

        let audits = capture.auditRecords
        #expect(audits.count == 1, "Expected exactly 1 audit record, got \(audits.count)")
        let rec = audits[0]
        // Required fields per spec §12: category, token id, project id, tool,
        // outcome. The audit carries the token id (not the credential) and the
        // identity's project id.
        #expect(rec.metadata["category"]?.description == "audit")
        #expect(rec.metadata["tool"]?.description == "os_delete")
        #expect(rec.metadata["token"]?.description == registry.identity.vt.token.id)
        #expect(rec.metadata["project"]?.description == registry.identity.whoami.project.id)
        // The outcome must agree with the call result: an error result is
        // audited as "error", an ok result as "ok".
        let expectedOutcome = (result.isError ?? false) ? "error" : "ok"
        #expect(rec.metadata["outcome"]?.description == expectedOutcome)
        // The token credential/secret must never appear in the audit line.
        let allValues = rec.metadata.values.map { $0.description }.joined(separator: " ")
        #expect(!allValues.contains("secret-admin"))
    }

    @Test("a mutating tool call does NOT emit an audit record when audit is disabled")
    func auditDisabledEmitsNoAuditRecord() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let (registry, capture) = try await makeAuditRegistry(
            handle: handle, credID: "fake-cred-admin", secret: "secret-admin", auditEnabled: false
        )

        let params = CallTool.Parameters(
            name: "os_delete",
            arguments: [
                "resource": .string("server"),
                "id_or_name": .string("does-not-exist"),
                "dry_run": .bool(true),
            ]
        )
        let server = await registry.makeServer()
        defer { Task { await server.stop() } }
        _ = try await registry.dispatch(params, server: server)

        #expect(capture.auditRecords.isEmpty, "Expected no audit record when auditEnabled=false")
    }

    @Test("a read-only tool call emits no audit record even when audit is enabled")
    func readOnlyCallEmitsNoAuditRecord() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let (registry, capture) = try await makeAuditRegistry(
            handle: handle, credID: "fake-cred-admin", secret: "secret-admin", auditEnabled: true
        )

        // os_list is read-only; it must not be audited.
        let params = CallTool.Parameters(
            name: "os_list",
            arguments: ["resource": .string("server")]
        )
        let server = await registry.makeServer()
        defer { Task { await server.stop() } }
        _ = try await registry.dispatch(params, server: server)

        #expect(capture.auditRecords.isEmpty, "Expected no audit record for a read-only call")
    }
}
