import Foundation
import Logging

/// Region-bound ZaQar (messaging) client.
///
/// Keystone service type: `messaging`. The API is project-scoped
/// (`/v1/<project>/queues`), so the client injects the token's project id into
/// the path (empty basePath → resource path is built from scratch). IAD3
/// advertises the catalog endpoint at the host root; the resolver prepends the
/// `v1` service root. List returns a bare JSON array of queue *names*; a single
/// queue returns the metadata object.
public struct MessagingRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    private let serviceRoot: String = "v1"
    private let catalogType: String = "messaging"

    private func req(
        _ vt: ValidatedToken,
        _ region: String,
        method: String,
        path: String,
        query: [URLQueryItem]? = nil
    ) async throws -> (status: Int, body: Data, requestID: String?) {
        let ep = resolveServiceEndpoint(
            vt: vt, region: region, cloud: cloud,
            basePath: basePath, serviceRoot: serviceRoot,
            serviceType: catalogType, fullPath: path
        )
        return try await transport.request(
            method: method,
            service: serviceType,
            path: ep.path,
            query: query ?? [],
            body: nil,
            tokenOverride: vt.token.id,
            overrideBase: ep.overrideBase
        )
    }

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "messaging", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    /// The project-relative queues path (ZaQar is project-scoped). The version
    /// root is supplied by the resolver's `serviceRoot`, so this carries only
    /// `<project>/queues` relative to the service basePath.
    private func queuesPath(_ vt: ValidatedToken, _ suffix: String = "") -> String {
        let project = vt.token.project.id
        return "\(basePath)/\(project)/queues" + suffix
    }

    public func listQueues(_ vt: ValidatedToken) async throws -> [ZaQarQueue] {
        let region = try resolveRegion(vt)
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "queue", suffix: "")
        if let cached = await cache.get(key, ttl: .seconds(120), as: [ZaQarQueue].self) { return cached }
        let result = try await req(vt, region, method: "GET", path: queuesPath(vt))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "messaging", requestID: result.requestID, hasAccessRules: false)
        }
        let names = try JSONDecoder().decode([String].self, from: result.body)
        let items = names.map { ZaQarQueue(id: $0, name: $0) }
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getQueue(_ vt: ValidatedToken, name: String) async throws -> ZaQarQueue {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: queuesPath(vt, "/\(name)"))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "messaging", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(ZaQarQueue.self, from: result.body)
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: catalogType, region: region, vt: vt)
        return region
    }
}

/// ZaQar messaging client.
public struct MessagingService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "messaging") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> MessagingRegion {
        MessagingRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "messaging", defaultRegion: region ?? cloud.regionName)
    }
}
