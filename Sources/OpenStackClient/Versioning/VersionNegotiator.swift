import Foundation
import Logging

/// Negotiates the API microversion for a service by querying its version
/// document, caching the result, and picking min(serverMax, clientMax).
/// Throws if the negotiated version is below the floor.
public actor VersionNegotiator {
    private let transport: Transport
    private let cache: Cache
    private let serviceType: String
    private let clientMax: Microversion
    private let floor: Microversion?
    private let logger: Logger

    public init(
        transport: Transport,
        cache: Cache,
        serviceType: String,
        clientMax: Microversion,
        floor: Microversion? = nil,
        logger: Logger = Logger(label: "version-negotiator")
    ) {
        self.transport = transport
        self.cache = cache
        self.serviceType = serviceType
        self.clientMax = clientMax
        self.floor = floor
        self.logger = logger
    }

    /// Negotiate the microversion for a region. Cached per region.
    public func negotiate(region: String) async throws -> Microversion {
        let key = CacheKey(
            tokenID: "_version_docs_",
            region: region,
            resource: "__versions__/\(serviceType)",
            suffix: ""
        )

        if let cached = await cache.get(key, ttl: .seconds(1800), as: Microversion.self) {
            return cached
        }

        let (status, body, _) = try await transport.request(
            method: "GET",
            service: serviceType,
            path: "/"
        )

        guard status == 200 else {
            throw OpenStackError.normalize(
                body: body,
                status: status,
                service: serviceType,
                requestID: nil,
                hasAccessRules: false
            )
        }

        let serverMax = try Self.parseServerMax(from: body, serviceType: serviceType)
        let negotiated = min(serverMax, clientMax)

        if let floor, negotiated < floor {
            throw OpenStackError(
                service: serviceType,
                status: 0,
                code: "below-floor",
                message: "cloud advertises \(serviceType) max \(serverMax.stringValue); floor is \(floor.stringValue)",
                hint: "the cloud's API version is too old for the required features"
            )
        }

        await cache.put(key, ttl: .seconds(1800), value: negotiated)
        return negotiated
    }

    /// Parse the server's max version from a version document response.
    /// Handles Nova (`{"version":{"max_version":"2.104"}}`),
    /// Cinder (`{"version":{"max_version":"3.x"}}`),
    /// and Glance (`{"versions":[...]}`).
    static func parseServerMax(from body: Data, serviceType: String) throws -> Microversion {
        struct VersionDoc: Codable {
            struct Version: Codable {
                let max_version: String
                let min_version: String?
            }
            let version: Version
        }

        struct GlanceVersions: Codable {
            struct VersionEntry: Codable {
                let id: String
                let status: String?
                let min_version: String?
                let max_version: String?
            }
            let versions: [VersionEntry]
        }

        // Try Nova/Cinder style first: {"version": {"max_version": "2.104"}}
        if let doc = try? JSONDecoder().decode(VersionDoc.self, from: body),
           let maxV = Microversion(doc.version.max_version) {
            return maxV
        }

        // Try Glance style: {"versions": [{"id": "v2", "max_version": "2.x"}]}
        if let glance = try? JSONDecoder().decode(GlanceVersions.self, from: body),
           let entry = glance.versions.first(where: { $0.status == "CURRENT" }) ?? glance.versions.last,
           let maxStr = entry.max_version,
           let maxV = Microversion(maxStr) {
            return maxV
        }

        throw OpenStackError(
            service: serviceType,
            status: 500,
            code: "version-parse",
            message: "could not parse version document from \(serviceType) response",
            hint: "check that the endpoint is the correct service"
        )
    }
}
