import Foundation
import Logging

/// Nova compute service. Stateless w.r.t. identity — every operation
/// takes the request's `vt: ValidatedToken` as its first argument.
public struct ComputeService: Sendable {
    private let cloud: CloudEntry
    private let transport: Transport
    private let cache: Cache
    private let logger: Logger
    private let basePath: String

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "nova") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
    }

    /// Create a region-bound compute client.
    public func region(_ region: String? = nil) -> ComputeRegion {
        ComputeRegion(
            cloud: cloud,
            transport: transport,
            cache: cache,
            logger: logger,
            defaultRegion: region ?? cloud.regionName,
            basePath: basePath
        )
    }
}

/// Region-bound Nova client. Resolves endpoint and negotiates microversion
/// lazily on first use.
public struct ComputeRegion: Sendable {
    private let cloud: CloudEntry
    private let transport: Transport
    private let cache: Cache
    private let logger: Logger
    private let defaultRegion: String?
    private let basePath: String

    private let serviceType: String

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, defaultRegion: String?, basePath: String, serviceType: String = "compute") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.defaultRegion = defaultRegion
        self.basePath = basePath
        self.serviceType = serviceType
    }

    /// The version root the catalog URL should carry (empty = catalog URL is
    /// always the authoritative base; non-empty = verify the catalog path ends
    /// with it, else use the catalog host + this root). Nova's root is its own
    /// base, so empty.
    private let serviceRoot: String = ""

    /// Route a request to the service's real endpoint from the token catalog
    /// (multi-endpoint clouds) or the cloud authURL (single-endpoint fallback).
    /// `path` is the full service path relative to the authURL (i.e. it starts
    /// with `basePath`); the leading `basePath` is replaced by the resolved
    /// service-root prefix.
    private func req(
        _ vt: ValidatedToken,
        _ region: String,
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: Data? = nil,
        timeoutOverride: Duration? = nil
    ) async throws -> (status: Int, body: Data, requestID: String?) {
        let ep = resolveServiceEndpoint(
            vt: vt, region: region, cloud: cloud,
            basePath: basePath, serviceRoot: serviceRoot,
            serviceType: serviceType, fullPath: path
        )
        // Nova negotiates its microversion and sends it on every request. The
        // negotiator caches the result per region, so this is a cache hit after
        // the first call. Failures are non-fatal: a version-doc error should not
        // block the data-plane call, so we proceed without the header.
        var extraHeaders: [(String, String)] = []
        if let profile = ServiceVersionProfile.profile(for: serviceType), profile.hasMicroversion {
            let negotiator = VersionNegotiator(
                transport: transport,
                cache: cache,
                profile: profile,
                endpointBase: { ep.overrideBase },
                tokenOverride: vt.token.id
            )
            do {
                // The version doc lives at the service root (the resolved path
                // prefix), fetched from the resolved base (catalog host on
                // multi-endpoint clouds, authURL on single-endpoint).
                let negotiated = try await negotiator.negotiate(region: region, versionDocPath: ep.pathPrefix)
                if let header = negotiated.header {
                    extraHeaders.append(header)
                }
            } catch {
                logger.debug("Microversion negotiation failed for \(serviceType) in \(region); proceeding without header: \(error)")
            }
        }

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

    // MARK: - Server operations

    public func listServers(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Server] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "server", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(60), as: [Server].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters {
            query.append(URLQueryItem(name: k, value: v))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let marker {
            query.append(URLQueryItem(name: "marker", value: marker))
        }

        // Use the detail view: the non-detail `/servers` list returns only
        // id/name/links, but our Server model needs the detail fields
        // (status/flavor/addresses). Real clouds (e.g. Rackspace) confirm the
        // non-detail shape lacks those, so /servers/detail is the correct call.
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/servers/detail", query: query)
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct ServerList: Decodable {
            struct Server: Decodable { let id: String; let name: String; let status: String
                let flavor: FlavorRef; let addresses: [String: [String: String]]
                let key_name: String?; let created: String?
                let security_groups: [String]?
            }
            let servers: [Server]
        }

        let decoded = try JSONDecoder().decode(ServerList.self, from: result.body)
        let servers = decoded.servers.map { s in
            Server(
                id: s.id,
                name: s.name,
                status: s.status,
                flavor: s.flavor,
                addresses: s.addresses,
                created: s.created.flatMap { Self.parseDate($0) },
                keyName: s.key_name,
                securityGroups: s.security_groups ?? []
            )
        }

        await cache.put(key, ttl: .seconds(60), value: servers)
        return servers
    }

    public func getServer(_ vt: ValidatedToken, id: String) async throws -> Server {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/servers/\(id)")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct ServerResp: Decodable {
            struct Server: Decodable {
                let id: String; let name: String; let status: String
                let flavor: FlavorRef
                let addresses: [String: [String: String]]
                let key_name: String?
                let created: String?
                let updated: String?
                let metadata: [String: String]
                let security_groups: [String]?
                let progress: Int?
            }
            let server: Server
        }

        let decoded = try JSONDecoder().decode(ServerResp.self, from: result.body)
        let s = decoded.server
        return Server(
            id: s.id,
            name: s.name,
            status: s.status,
            flavor: s.flavor,
            addresses: s.addresses,
            created: s.created.flatMap { Self.parseDate($0) },
            metadata: s.metadata,
            keyName: s.key_name,
            securityGroups: s.security_groups ?? [],
            updated: s.updated.flatMap { Self.parseDate($0) },
            progress: s.progress
        )
    }

    public func createServer(_ vt: ValidatedToken, _ spec: CreateServerSpec) async throws -> Server {
        let region = try resolveRegion(vt)
        // Microversion gating for feature-gated fields
        let mv = try await negotiateMicroversion(vt, region: region)
        if spec.hostname != nil, mv < Microversion(major: 2, minor: 90) {
            throw OpenStackError(
                service: "compute",
                status: 400,
                code: "feature_unavailable",
                message: "hostname requires microversion 2.90, negotiated \(mv.stringValue)"
            )
        }
        if spec.pinnedAvailabilityZone != nil, mv < Microversion(major: 2, minor: 96) {
            throw OpenStackError(
                service: "compute",
                status: 400,
                code: "feature_unavailable",
                message: "pinned availability zone requires microversion 2.96, negotiated \(mv.stringValue)"
            )
        }

        let body = spec.body().data(using: .utf8)!
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/servers", body: body)
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        // Invalidate server list cache
        await cache.invalidate(resource: "server", tokenID: vt.token.id, region: region)

        return try decodeSingleServer(result.body)
    }

    public func deleteServer(_ vt: ValidatedToken, id: String, force: Bool = false) async throws {
        let region = try resolveRegion(vt)
        var query: [URLQueryItem] = []
        if force {
            query.append(URLQueryItem(name: "force", value: "true"))
        }

        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/servers/\(id)", query: query)
        // Nova returns 200, 202, or 204 for delete
        if ![200, 202, 204].contains(result.status) {
            try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)
        }

        await cache.invalidate(resource: "server", tokenID: vt.token.id, region: region)
    }

    public func action(_ vt: ValidatedToken, _ serverID: String, _ action: ServerAction) async throws -> Server? {
        let region = try resolveRegion(vt)
        let body = action.body().data(using: .utf8)!

        let result = try await req(vt, region, method: "POST", path: "\(basePath)/servers/\(serverID)/action", body: body)

        // Some actions return 202 with no body, some return a server
        if result.status == 202 || result.status == 204 {
            return nil
        }

        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        // Try to decode a server from the response
        if let server = try? decodeSingleServer(result.body) {
            return server
        }
        return nil
    }

    /// Request a console (vnc/spice/rdp) for a server. Unlike state-changing
    /// actions, Nova returns 200 with a `{"console":{...}}` body; the url is
    /// scoped to the requesting identity (Nova-side), so it is returned only to
    /// the session that asked.
    public func getConsole(_ vt: ValidatedToken, _ serverID: String, type: String) async throws -> Console {
        let region = try resolveRegion(vt)
        let body = "{\"getVNCConsole\":{\"type\":\"\(type)\"}}".data(using: .utf8)!

        let result = try await req(vt, region, method: "POST", path: "\(basePath)/servers/\(serverID)/action", body: body)

        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct ConsoleResp: Decodable {
            let console: Console
        }
        let decoded = try JSONDecoder().decode(ConsoleResp.self, from: result.body)
        return decoded.console
    }

    /// Fetch serial console output (last `lines` lines) for a server.
    public func getConsoleOutput(_ vt: ValidatedToken, _ serverID: String, lines: Int) async throws -> String {
        let region = try resolveRegion(vt)
        let body = "{\"getConsoleOutput\":{\"length\":\(lines)}}".data(using: .utf8)!

        let result = try await req(vt, region, method: "POST", path: "\(basePath)/servers/\(serverID)/action", body: body)

        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct OutputResp: Decodable { let output: String }
        let decoded = try JSONDecoder().decode(OutputResp.self, from: result.body)
        return decoded.output
    }

    // MARK: - Flavors

    public func listFlavors(_ vt: ValidatedToken) async throws -> [Flavor] {
        let region = try resolveRegion(vt)
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "flavor", suffix: "")

        if let cached = await cache.get(key, ttl: .seconds(300), as: [Flavor].self) {
            return cached
        }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/flavors")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct FlavorList: Decodable {
            let flavors: [Flavor]
        }
        let decoded = try JSONDecoder().decode(FlavorList.self, from: result.body)
        await cache.put(key, ttl: .seconds(300), value: decoded.flavors)
        return decoded.flavors
    }

    public func getFlavor(_ vt: ValidatedToken, id: String) async throws -> Flavor {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/flavors/\(id)")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct FlavorResp: Decodable {
            let flavor: Flavor
        }
        let decoded = try JSONDecoder().decode(FlavorResp.self, from: result.body)
        return decoded.flavor
    }

    // MARK: - Keypairs

    public func listKeypairs(_ vt: ValidatedToken) async throws -> [KeyPair] {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/os-keypairs")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct KeyPairList: Decodable {
            let keypairs: [KeyPair]
        }
        let decoded = try JSONDecoder().decode(KeyPairList.self, from: result.body)
        return decoded.keypairs
    }

    public func createKeyPair(_ vt: ValidatedToken, name: String, publicKey: String?) async throws -> KeyPair {
        let region = try resolveRegion(vt)
        let keypairJSON = publicKey != nil
            ? "{\"keypair\":{\"name\":\"\(name)\",\"public_key\":\"\(publicKey!)\"}}"
            : "{\"keypair\":{\"name\":\"\(name)\"}}"

        let result = try await req(vt, region, method: "POST", path: "\(basePath)/os-keypairs", body: keypairJSON.data(using: .utf8))
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct KeyPairResp: Decodable {
            let keypair: KeyPair
        }
        let decoded = try JSONDecoder().decode(KeyPairResp.self, from: result.body)
        await cache.invalidate(resource: "keypair", tokenID: vt.token.id, region: region)
        return decoded.keypair
    }

    public func deleteKeyPair(_ vt: ValidatedToken, name: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/os-keypairs/\(name)")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)
        await cache.invalidate(resource: "keypair", tokenID: vt.token.id, region: region)
    }

    // MARK: - Server groups

    public func listServerGroups(_ vt: ValidatedToken) async throws -> [ServerGroup] {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/os-server-groups")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct ServerGroupList: Decodable {
            let server_groups: [ServerGroup]
        }
        let decoded = try JSONDecoder().decode(ServerGroupList.self, from: result.body)
        return decoded.server_groups
    }

    // MARK: - Availability zones

    public func listAvailabilityZones(_ vt: ValidatedToken) async throws -> [AvailabilityZone] {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/os-availability-zone")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct AZList: Decodable {
            let availabilityZoneInfo: [AvailabilityZone]
        }
        let decoded = try JSONDecoder().decode(AZList.self, from: result.body)
        return decoded.availabilityZoneInfo
    }

    // MARK: - Hypervisors (admin)

    public func listHypervisors(_ vt: ValidatedToken) async throws -> [Hypervisor] {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/os-hypervisors")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct HypervisorList: Decodable {
            let hypervisors: [Hypervisor]
        }
        let decoded = try JSONDecoder().decode(HypervisorList.self, from: result.body)
        return decoded.hypervisors
    }

    public func getHypervisor(_ vt: ValidatedToken, host: String) async throws -> Hypervisor {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/os-hypervisors/\(host)")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct HypervisorResp: Decodable {
            let hypervisor: Hypervisor
        }
        let decoded = try JSONDecoder().decode(HypervisorResp.self, from: result.body)
        return decoded.hypervisor
    }

    // MARK: - Compute services (admin)

    public func listComputeServices(_ vt: ValidatedToken) async throws -> [ComputeServiceInfo] {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/os-services")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct ServiceList: Decodable {
            let services: [ComputeServiceInfo]
        }
        let decoded = try JSONDecoder().decode(ServiceList.self, from: result.body)
        return decoded.services
    }

    // MARK: - Quotas

    public func getQuotaSet(_ vt: ValidatedToken) async throws -> QuotaSet {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/os-quota-sets/\(projectID)")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct QuotaSetResp: Decodable {
            let quota_set: QuotaSet
        }
        let decoded = try JSONDecoder().decode(QuotaSetResp.self, from: result.body)
        return decoded.quota_set
    }

    public func updateQuotaSet(_ vt: ValidatedToken, quotas: QuotaSet) async throws -> QuotaSet {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id

        // Build quota update body. Quota fields are optional; OpenStack
        // treats -1 as "no change", so a nil (unset) field maps to -1.
        // (Directly interpolating an Int? would emit "Optional(n)"/"nil",
        // which is invalid JSON.)
        var parts: [String] = []
        parts.append("\"instances\":\(quotas.instances ?? -1)")
        parts.append("\"cores\":\(quotas.cores ?? -1)")
        parts.append("\"ram\":\(quotas.ram ?? -1)")
        parts.append("\"metadata_items\":\(quotas.metadataItems ?? -1)")
        parts.append("\"injected_files\":\(quotas.injectedFiles ?? -1)")
        parts.append("\"key_pairs\":\(quotas.keyPairs ?? -1)")
        parts.append("\"security_groups\":\(quotas.securityGroups ?? -1)")
        parts.append("\"security_group_rules\":\(quotas.securityGroupRules ?? -1)")
        parts.append("\"fixed_ips\":\(quotas.fixedIPs ?? -1)")
        parts.append("\"floating_ips\":\(quotas.floatingIPs ?? -1)")

        let body = "{\"quota_set\":{\(parts.joined(separator: ","))}}"
        let result = try await req(vt, region, method: "PUT", path: "\(basePath)/os-quota-sets/\(projectID)", body: body.data(using: .utf8))
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)

        struct QuotaSetResp: Decodable {
            let quota_set: QuotaSet
        }
        let decoded = try JSONDecoder().decode(QuotaSetResp.self, from: result.body)
        await cache.invalidate(resource: "server", tokenID: vt.token.id, region: region)
        return decoded.quota_set
    }

    // MARK: - Volume attachments

    public func attachVolume(
        _ vt: ValidatedToken,
        serverID: String,
        volumeID: String,
        device: String? = nil,
        deleteOnTermination: Bool? = nil
    ) async throws {
        let region = try resolveRegion(vt)
        var parts: [String] = ["\"volumeId\":\"\(volumeID)\""]
        if let device { parts.append("\"device\":\"\(device)\"") }
        if let deleteOnTermination { parts.append("\"delete_on_termination\":\(deleteOnTermination ? "true" : "false")") }

        let body = "{\"os-attach-volume\":{\(parts.joined(separator: ","))}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/servers/\(serverID)/os-volume_attachments", body: body.data(using: .utf8))
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)
        await cache.invalidate(resource: "server", tokenID: vt.token.id, region: region)
    }

    public func detachVolume(_ vt: ValidatedToken, serverID: String, attachmentID: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/servers/\(serverID)/os-volume_attachments/\(attachmentID)")
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)
        await cache.invalidate(resource: "server", tokenID: vt.token.id, region: region)
    }

    // MARK: - Interface attachments

    public func attachInterface(
        _ vt: ValidatedToken,
        serverID: String,
        networkID: String? = nil,
        subnetID: String? = nil,
        portID: String? = nil,
        fixedIP: String? = nil
    ) async throws {
        let region = try resolveRegion(vt)
        var parts: [String] = []
        if let networkID { parts.append("\"net_id\":\"\(networkID)\"") }
        if let subnetID { parts.append("\"subnet_id\":\"\(subnetID)\"") }
        if let portID { parts.append("\"port\":\"\(portID)\"") }
        if let fixedIP { parts.append("\"fixed_ip\":\"\(fixedIP)\"") }

        let body = "{\"os-interface-attach\":{\(parts.joined(separator: ","))}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/servers/\(serverID)/os-interface-attach", body: body.data(using: .utf8))
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)
        await cache.invalidate(resource: "server", tokenID: vt.token.id, region: region)
    }

    public func detachInterface(_ vt: ValidatedToken, serverID: String, portID: String) async throws {
        let region = try resolveRegion(vt)
        let body = "{\"os-interface-detach\":{\"port\":\"\(portID)\"}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/servers/\(serverID)/os-interface-detach", body: body.data(using: .utf8))
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)
        await cache.invalidate(resource: "server", tokenID: vt.token.id, region: region)
    }

    // MARK: - Update server

    public func updateServer(
        _ vt: ValidatedToken,
        id: String,
        name: String? = nil,
        description: String? = nil,
        metadata: [String: String]? = nil,
        tags: [String]? = nil
    ) async throws -> Server {
        let region = try resolveRegion(vt)
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let description { parts.append("\"description\":\"\(description)\"") }
        if let metadata, !metadata.isEmpty {
            let metaStr = metadata.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            parts.append("\"metadata\":{\(metaStr)}")
        }
        if let tags {
            let tagsStr = tags.map { "\"\($0)\"" }.joined(separator: ",")
            parts.append("\"tags\":[\(tagsStr)]")
        }

        let body = "{\"server\":{\(parts.joined(separator: ","))}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/servers/\(id)", body: body.data(using: .utf8))
        try Self.checkStatus(result.status, service: "compute", resultID: result.requestID)
        await cache.invalidate(resource: "server", tokenID: vt.token.id, region: region)

        return try decodeSingleServer(result.body)
    }

    // MARK: - Private helpers

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
        return region
    }

    /// Negotiate the microversion for feature-gating (e.g. hostname requires
    /// 2.90). Reuses the shared profile-based `VersionNegotiator`, which parses
    /// both the real `{"versions":[...]}` form and the legacy object form. The
    /// version doc is fetched from the service's resolved endpoint base (or the
    /// cloud authURL for single-endpoint clouds) at the service root path.
    private func negotiateMicroversion(_ vt: ValidatedToken, region: String) async throws -> Microversion {
        let profile = ServiceVersionProfile.profile(for: serviceType)!
        // Resolve the endpoint base the same way `req` does, so the version doc
        // is fetched from the correct host (catalog on multi-endpoint clouds,
        // authURL on single-endpoint). We only need the base here — the negotiator
        // fetches the doc at `versionDocPath: basePath`, not at `ep.path`.
        let ep = resolveServiceEndpoint(
            vt: vt, region: region, cloud: cloud,
            basePath: basePath, serviceRoot: serviceRoot,
            serviceType: serviceType, fullPath: "\(basePath)/__version__"
        )
        let negotiator = VersionNegotiator(
            transport: transport,
            cache: cache,
            profile: profile,
            endpointBase: { ep.overrideBase },
            tokenOverride: vt.token.id
        )
        return try await negotiator.negotiate(region: region, versionDocPath: ep.pathPrefix).version
    }

    private static func checkStatus(_ status: Int, service: String, resultID: String?) throws {
        guard (200..<300).contains(status) else {
            throw OpenStackError(
                service: service,
                status: status,
                code: nil,
                message: "HTTP \(status)",
                requestID: resultID,
                retriable: [429, 502, 503, 504].contains(status)
            )
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func decodeSingleServer(_ data: Data) throws -> Server {
        struct ServerResp: Decodable {
            struct Server: Decodable {
                let id: String
                let name: String
                let status: String
                let flavor: FlavorRef
                let addresses: [String: [String: String]]
                let key_name: String?
                let created: String?
                let updated: String?
                let metadata: [String: String]
                let security_groups: [String]?
                let progress: Int?
            }
            let server: Server
        }
        let decoded = try JSONDecoder().decode(ServerResp.self, from: data)
        let s = decoded.server
        return Server(
            id: s.id,
            name: s.name,
            status: s.status,
            flavor: s.flavor,
            addresses: s.addresses,
            created: s.created.flatMap { Self.parseDate($0) },
            metadata: s.metadata,
            keyName: s.key_name,
            securityGroups: s.security_groups ?? [],
            updated: s.updated.flatMap { Self.parseDate($0) },
            progress: s.progress
        )
    }
}
