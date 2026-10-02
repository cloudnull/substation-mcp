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

    /// The version root the catalog URL should carry (empty = the catalog URL is
    /// always the authoritative base; non-empty = verify the catalog path ends
    /// with it, else use the catalog host + this root).
    private let serviceRoot: String = ""
    /// The Keystone catalog service type (may differ from the transport label,
    /// e.g. magnum is catalog type `container-infra` but labeled `container`).
    private let catalogType: String = "orchestration"

    /// Route a request to the service's real endpoint from the token catalog
    /// (multi-endpoint clouds) or the cloud authURL (single-endpoint fallback).
    /// `path` is the full service path relative to the authURL (starts with
    /// `basePath`); the leading `basePath` is replaced by the resolved prefix.
    private func req(
        _ vt: ValidatedToken,
        _ region: String,
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: Data? = nil,
        timeoutOverride: Duration? = nil,
        extraHeaders: [(String, String)] = []
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
            body: body,
            tokenOverride: vt.token.id,
            extraHeaders: extraHeaders,
            timeoutOverride: timeoutOverride,
            overrideBase: ep.overrideBase
        )
    }

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
        let body = try await fetchBody(vt, region: region, path: "\(basePath)/stacks", filters: filters, limit: limit, marker: marker)
        let items = try JSONDecoder().decode(Envelope.self, from: body).stacks
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getStack(_ vt: ValidatedToken, id: String) async throws -> Stack {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/stacks/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "orchestration", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Stack.self, from: result.body)
    }

    public func createStack(_ vt: ValidatedToken, _ spec: CreateStackSpec) async throws -> Stack {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/stacks", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "orchestration", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "stack", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(Stack.self, from: result.body)
    }

    public func deleteStack(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/stacks/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "orchestration", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "stack", tokenID: vt.token.id, region: region)
    }

    /// Fetch a stack's outputs. Heat returns `{"outputs":[{output_key, output_value, description}, ...]}`.
    public func getStackOutputs(_ vt: ValidatedToken, id: String) async throws -> [StackOutput] {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/stacks/\(id)/outputs")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "orchestration", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let outputs: [StackOutput] }
        return try JSONDecoder().decode(Envelope.self, from: result.body).outputs
    }

    // MARK: - Helpers

    private func fetchBody(_ vt: ValidatedToken, region: String, path: String, filters: [String: String], limit: Int?, marker: String?) async throws -> Data {
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await req(vt, region, method: "GET", path: path, query: query)
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
