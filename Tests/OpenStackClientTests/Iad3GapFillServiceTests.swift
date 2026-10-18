import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

/// Client-level tests for the IAD3 gap-fill services (phase 2) driven against
/// the fake cloud, mirroring OrchestrationServiceTests.
@Suite("IAD3 Gap-Fill Service Tests", .timeLimit(.minutes(3)))
struct Iad3GapFillServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, Transport) {
        let handle = try await FakeApp.start()
        let state = handle.state

        guard let fakeToken = await state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token")
        }
        let tokenID = fakeToken.id

        let keystoneURL = handle.keystoneURL.appendingPathComponent("auth/tokens")
        var req = URLRequest(url: keystoneURL)
        req.httpMethod = "GET"
        req.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let httpStatus = (resp as! HTTPURLResponse).statusCode
        #expect(httpStatus == 200, "Token validation failed: \(httpStatus)")

        let token = try Token.decode(from: data)
        let vt = ValidatedToken(token: token, scopes: [.read, .write])

        let cloud = CloudEntry(name: "fake", authURL: URL(string: handle.url.absoluteString)!, regionName: "RegionOne")
        let transport = Transport(cloud: cloud, tokenSource: { tokenID }, logger: logger)
        return (handle, vt, transport)
    }

    private func makeClient(_ cloud: CloudEntry, _ transport: Transport) -> OpenStackClient {
        let cache = Cache(maxEntries: 100)
        let validator = TokenValidator(transport: transport, cache: cache, servedProjects: [])
        return OpenStackClient(cloud: cloud, transport: transport, cache: cache, validator: validator, logger: logger)
    }

    private func cloud(from handle: FakeHandle) -> CloudEntry {
        CloudEntry(name: "fake", authURL: URL(string: handle.url.absoluteString)!, regionName: "RegionOne")
    }

    @Test("Trove: list/get/create/delete database instances")
    func databaseInstances() async throws {
        let (handle, vt, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let client = makeClient(cloud(from: handle), transport)
        let r = await client.database(region: "RegionOne")

        let instances = try await r.listInstances(vt)
        #expect(instances.first?.id == "db-1")
        #expect(instances.first?.name == "fake-mysql")
        #expect(instances.first?.status == "ACTIVE")

        let got = try await r.getInstance(vt, id: "db-1")
        #expect(got.versionNumber == "8.0")
        #expect(got.volumeSize == 10)

        let flavors = try await r.listFlavors(vt)
        #expect(flavors.count == 2)
        #expect(flavors.contains { $0.id == "fl-1" })

        let datastores = try await r.listDatastores(vt)
        #expect(datastores.contains { $0.id == "mysql" })

        let created = try await r.createInstance(vt, CreateDatabaseInstanceSpec(name: "new-db", flavorRef: "fl-2", volumeSize: 5, datastore: "mysql"))
        #expect(created.name == "new-db")
        #expect(created.status == "ACTIVE")

        try await r.deleteInstance(vt, id: created.id)
        let after = try await r.listInstances(vt)
        #expect(!after.contains { $0.id == created.id })
    }

    @Test("Gnocchi: list metrics and resource types")
    func metricLists() async throws {
        let (handle, vt, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let client = makeClient(cloud(from: handle), transport)
        let r = await client.metric(region: "RegionOne")

        let metrics = try await r.listMetrics(vt)
        #expect(metrics.count == 2)
        #expect(metrics.first?.name == "cpu.utilization")
        #expect(metrics.first?.unit == "%")

        let filtered = try await r.listMetrics(vt, name: "memory.usage")
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "memory.usage")

        let types = try await r.listResourceTypes(vt)
        #expect(types.contains { $0.id == "instance" })
    }

    @Test("Gnocchi: get by id, resource join, archive policies, measures, create/delete lifecycle")
    func metricDeepening() async throws {
        let (handle, vt, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let client = makeClient(cloud(from: handle), transport)
        let r = await client.metric(region: "RegionOne")

        // get by id
        let m = try await r.getMetric(vt, id: "gnocchi-1")
        #expect(m.name == "cpu.utilization")
        #expect(m.unit == "%")

        // resource join + archive-policy filter
        let joined = try await r.listMetricsForResource(vt, resourceID: "inst-1")
        #expect(joined.count == 2)
        let byPolicy = try await r.listMetrics(vt, archivePolicy: "low")
        #expect(byPolicy.map(\.name) == ["cpu.utilization"])

        // raw measures pass through as triples
        let raw = try await r.getMeasures(vt, metricID: "gnocchi-1")
        guard case .array(let rows) = raw, case .array(let first) = rows.first, rows.count == 2 else {
            throw OpenStackError(service: "mcp", status: 500, message: "expected 2 raw measure rows, got \(raw)")
        }
        #expect(first.count == 3)

        // aggregation validated against the policy vocabulary (low offers mean @ 0:05:00)
        let agg = try await r.getAggregatedMeasures(vt, metricID: "gnocchi-1", aggregation: "mean", granularity: "0:05:00", start: "2026-01-01T00:00:00+00:00", stop: nil)
        guard case .array(let bucket) = agg, bucket.count == 1 else {
            throw OpenStackError(service: "mcp", status: 500, message: "expected one aggregated bucket, got \(agg)")
        }
        // unknown method → 404 like meterng
        await #expect(throws: OpenStackError.self) {
            _ = try await r.getAggregatedMeasures(vt, metricID: "gnocchi-1", aggregation: "rate:mean", granularity: "0:05:00", start: nil, stop: nil)
        }
        // relative window → 400 like meterng
        await #expect(throws: OpenStackError.self) {
            _ = try await r.getAggregatedMeasures(vt, metricID: "gnocchi-1", aggregation: "mean", granularity: "0:05:00", start: "-P7D", stop: nil)
        }

        // archive policies
        let policies = try await r.listArchivePolicies(vt)
        #expect(policies.contains { $0.name == "ceilometer-low-rate" && $0.aggregationMethods.contains("rate:mean") })
        #expect(policies.first(where: { $0.name == "low" })?.definition.first?.granularity == "0:05:00")

        // create → appears in list → delete → gone
        let created = try await r.createMetric(vt, archivePolicy: "medium", name: "probe.metric", unit: "B")
        #expect(!created.id.isEmpty)
        #expect(created.archivePolicyName == "medium")
        let afterCreate = try await r.listMetrics(vt, name: "probe.metric")
        #expect(afterCreate.contains { $0.id == created.id })
        try await r.deleteMetric(vt, id: created.id)
        let afterDelete = try await r.listMetrics(vt, name: "probe.metric")
        #expect(afterDelete.isEmpty)

        // unknown archive policy on create → error
        await #expect(throws: OpenStackError.self) {
            _ = try await r.createMetric(vt, archivePolicy: "nope", name: nil, unit: nil)
        }
    }

    @Test("ZaQar: list and get queues")
    func messagingQueues() async throws {
        let (handle, vt, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let client = makeClient(cloud(from: handle), transport)
        let r = await client.messaging(region: "RegionOne")

        let queues = try await r.listQueues(vt)
        #expect(queues.count == 2)
        #expect(queues.contains { $0.name == "queue-1" })

        let q = try await r.getQueue(vt, name: "queue-1")
        #expect(q.name == "queue-1")
    }
    @Test("Blazar: list/get/create/delete reservations + allocations")
    func reservationLifecycle() async throws {
        let (handle, vt, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let client = makeClient(cloud(from: handle), transport)
        let r = await client.reservation(region: "RegionOne")

        let reservations = try await r.listReservations(vt)
        #expect(reservations.first?.id == "res-1")
        #expect(reservations.first?.status == "ACTIVE")

        let allocations = try await r.listAllocations(vt)
        #expect(allocations.first?.id == "alloc-1")

        let created = try await r.createReservation(vt, CreateBlazarReservationSpec(name: "new-res", flavorID: "flavor-9", expiry: nil, requiredAny: []))
        #expect(created.name == "new-res")

        try await r.deleteReservation(vt, id: created.id)
        let after = try await r.listReservations(vt)
        #expect(!after.contains { $0.id == created.id })
    }

    @Test("Freezer: list/get backups and schedules")
    func backupLists() async throws {
        let (handle, vt, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let client = makeClient(cloud(from: handle), transport)
        let r = await client.backup(region: "RegionOne")

        let backups = try await r.listBackups(vt)
        #expect(backups.first?.id == "bk-1")
        #expect(backups.first?.status == "backup")

        let got = try await r.getBackup(vt, id: "bk-1")
        #expect(got.volumeID == "vol-1")

        let schedules = try await r.listSchedules(vt)
        #expect(schedules.first?.id == "sched-1")
        #expect(schedules.first?.backupIntervalHours == 24)
    }
}
