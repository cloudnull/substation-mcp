import Foundation
import Logging

/// Region-bound Heat (orchestration) client.
///
/// Keystone service type: `orchestration`. API base path: `orchestration/v1`.
/// Resources: stack (pollable — status lifecycle). Stack outputs are a
/// sub-collection fetched via the `stack_output` path. List responses are
/// keyed envelopes (`{"stacks":[...]}`), single items return the bare object.
public struct OrchestrationRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "orchestration", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // MARK: - Stacks

    public func listStacks(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Stack] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "stack", suffix: suffix)
        if let cached = try await cache.get(key, ttl: .seconds(120), as: [Stack].self) { return cached }
        struct Envelope: Decodable { let stacks: [Stack] }
        let body = try await fetchBody(vt, path: "\(basePath)/stacks", filters: filters, limit: limit, marker: marker)
        let items = try JSONDecoder().decode(Envelope.self, from: body).stacks
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getStack(_ vt: ValidatedToken, id: String) async throws -> Stack {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "GET", service: "orchestration", path: "\(basePath)/stacks/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "orchestration", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Stack.self, from: result.body)
    }

    public func createStack(_ vt: ValidatedToken, _ spec: CreateStackSpec) async throws -> Stack {
        let region = try resolveRegion(vt)
        let result = try await transport.request(method: "POST", service: "orchestration", path: "\(basePath)/stacks", body: Data(spec.body().utf8), tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "orchestration", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "stack", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(Stack.self, from: result.body)
    }

    public func deleteStack(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await transport.request(method: "DELETE", service: "orchestration", path: "\(basePath)/stacks/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "orchestration", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "stack", tokenID: vt.token.id, region: region)
    }

    /// Fetch a stack's outputs. Heat returns `{"outputs":[{output_key, output_value, description}, ...]}`.
    public func getStackOutputs(_ vt: ValidatedToken, id: String) async throws -> [StackOutput] {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "GET", service: "orchestration", path: "\(basePath)/stacks/\(id)/outputs", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "orchestration", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let outputs: [StackOutput] }
        return try JSONDecoder().decode(Envelope.self, from: result.body).outputs
    }

    // MARK: - Helpers

    private func fetchBody(_ vt: ValidatedToken, path: String, filters: [String: String], limit: Int?, marker: String?) async throws -> Data {
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await transport.request(method: "GET", service: "orchestration", path: path, query: query, tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "orchestration", requestID: result.requestID, hasAccessRules: false)
        }
        return result.body
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
        return region
    }
}

/// Heat orchestration client.
public struct OrchestrationService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "orchestration/v1") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> OrchestrationRegion {
        OrchestrationRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "orchestration/v1", defaultRegion: region ?? cloud.regionName)
    }
}
