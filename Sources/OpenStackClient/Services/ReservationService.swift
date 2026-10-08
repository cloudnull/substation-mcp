import Foundation
import Logging

/// Region-bound Blazar (reservation) client.
///
/// Keystone service type: `reservation`. IAD3 advertises the catalog endpoint
/// with `/v1`, so the catalog URL is the authoritative base and the client's
/// basePath is dropped. List responses are keyed envelopes
/// (`{"reservations":[...]}`), single items return the bare object.
public struct ReservationRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    private let serviceRoot: String = ""
    private let catalogType: String = "reservation"

    private func req(
        _ vt: ValidatedToken,
        _ region: String,
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: Data? = nil
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
            overrideBase: ep.overrideBase
        )
    }

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "reservation", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    public func listReservations(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [BlazarReservation] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "reservation", suffix: suffix)
        if let cached = await cache.get(key, ttl: .seconds(120), as: [BlazarReservation].self) { return cached }
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/reservations", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "reservation", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let reservations: [BlazarReservation] }
        let items = try JSONDecoder().decode(Envelope.self, from: result.body).reservations
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getReservation(_ vt: ValidatedToken, id: String) async throws -> BlazarReservation {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/reservations/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "reservation", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(BlazarReservation.self, from: result.body)
    }

    public func createReservation(_ vt: ValidatedToken, _ spec: CreateBlazarReservationSpec) async throws -> BlazarReservation {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/reservations", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "reservation", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "reservation", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(BlazarReservation.self, from: result.body)
    }

    public func deleteReservation(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/reservations/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "reservation", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "reservation", tokenID: vt.token.id, region: region)
    }

    public func listAllocations(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil) async throws -> [BlazarAllocation] {
        let region = try resolveRegion(vt)
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/allocations", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "reservation", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let allocations: [BlazarAllocation] }
        return try JSONDecoder().decode(Envelope.self, from: result.body).allocations
    }

    public func getAllocation(_ vt: ValidatedToken, id: String) async throws -> BlazarAllocation {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/allocations/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "reservation", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(BlazarAllocation.self, from: result.body)
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: catalogType, region: region, vt: vt)
        return region
    }
}

/// Blazar reservation client.
public struct ReservationService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> ReservationRegion {
        ReservationRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "", defaultRegion: region ?? cloud.regionName)
    }
}