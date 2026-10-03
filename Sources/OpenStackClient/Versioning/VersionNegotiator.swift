import Foundation
import Logging

/// The result of negotiating a service's API version: the negotiated
/// microversion and the header (name + value) to send on requests, when the
/// service uses a microversion header.
public struct NegotiatedVersion: Sendable, Equatable {
    public let version: Microversion
    /// The header name to send, or nil when the service has no microversion.
    public let headerName: String?
    /// The header value to send (the formatted microversion).
    public let headerValue: String?

    /// The header pair to forward to a request, or empty when there is none.
    public var header: (String, String)? {
        guard let headerName, let headerValue else { return nil }
        return (headerName, headerValue)
    }
}

/// Negotiates the API version for a service by querying its version document,
/// caching the result, and picking min(serverMax, clientMax). Throws if the
/// negotiated version is below the floor.
///
/// The version document is fetched from the service endpoint root. Real clouds
/// (nova, cinder) return `{"versions":[{...}]}` — a list where the `CURRENT`
/// entry carries `version`/`max_version`; some clouds (cinder) return this with
/// HTTP 300 (Multiple Choices), not 200. The legacy `{"version":{"max_version"}}`
/// object form (used by the fake) is also accepted.
public actor VersionNegotiator {
    private let transport: Transport
    private let cache: Cache
    private let profile: ServiceVersionProfile
    /// The base URL to fetch the version doc from (the service endpoint). When
    /// nil the request goes under the cloud authURL with the versionDocPath.
    private let endpointBase: @Sendable () async -> URL?
    /// A token to send as `X-Auth-Token` on the version-doc fetch. Required when
    /// the transport is stateless (serve/`check` mode, where requests carry an
    /// explicit token override rather than a standing token source). Nil when the
    /// transport has a standing token source.
    private let tokenOverride: String?
    private let logger: Logger

    public init(
        transport: Transport,
        cache: Cache,
        profile: ServiceVersionProfile,
        endpointBase: @escaping @Sendable () async -> URL? = { nil },
        tokenOverride: String? = nil,
        logger: Logger = Logger(label: "version-negotiator")
    ) {
        self.transport = transport
        self.cache = cache
        self.profile = profile
        self.endpointBase = endpointBase
        self.tokenOverride = tokenOverride
        self.logger = logger
    }

    /// Negotiate the version for a region. Cached per region.
    ///
    /// - Parameter versionDocPath: the path (under the endpoint base) to GET
    ///   for the version document. Defaults to the profile's `versionDocPath`.
    ///   Callers pass the service's root path here: e.g. `"nova"` when the
    ///   fake serves the version list at `/nova`, or `""` when the real service
    ///   serves it at the endpoint root.
    public func negotiate(
        region: String,
        versionDocPath: String? = nil
    ) async throws -> NegotiatedVersion {
        let docPath = versionDocPath ?? profile.versionDocPath
        let key = CacheKey(
            tokenID: "_version_docs_",
            region: region,
            resource: "__versions__/\(profile.serviceType)",
            suffix: docPath
        )

        if let cached = await cache.get(key, ttl: .seconds(1800), as: Microversion.self) {
            return makeResult(cached)
        }

        let path = docPath.isEmpty ? "/" : docPath
        let base = await endpointBase()
        let (status, body, _) = try await transport.request(
            method: "GET",
            service: profile.serviceType,
            path: path,
            tokenOverride: tokenOverride,
            overrideBase: base,
            tolerate3xx: true
        )

        // Real service version docs may be 200 (nova) or 300 (cinder/glance).
        guard status == 200 || status == 300 else {
            throw OpenStackError.normalize(
                body: body,
                status: status,
                service: profile.serviceType,
                requestID: nil,
                hasAccessRules: false
            )
        }

        let serverMax = try Self.parseServerMax(from: body, serviceType: profile.serviceType)
        let negotiated = min(serverMax, profile.clientMax)

        if let floor = profile.floor, negotiated < floor {
            throw OpenStackError(
                service: profile.serviceType,
                status: 0,
                code: "below-floor",
                message: "cloud advertises \(profile.serviceType) max \(serverMax.stringValue); floor is \(floor.stringValue)",
                hint: "the cloud's API version is too old for the required features"
            )
        }

        await cache.put(key, ttl: .seconds(1800), value: negotiated)
        return makeResult(negotiated)
    }

    private func makeResult(_ version: Microversion) -> NegotiatedVersion {
        if profile.hasMicroversion {
            return NegotiatedVersion(version: version, headerName: profile.headerName, headerValue: profile.headerValue(version))
        }
        return NegotiatedVersion(version: version, headerName: nil, headerValue: nil)
    }

    /// Parse the server's max version from a version document response.
    /// Handles the real `{"versions":[{...}]}` list form (nova, cinder) and the
    /// legacy `{"version":{"max_version"}}` object form (the fake).
    static func parseServerMax(from body: Data, serviceType: String) throws -> Microversion {
        // Real form: {"versions":[{"id":"v2.1","status":"CURRENT","version":"2.100"}]}
        struct VersionsList: Codable {
            struct Entry: Codable {
                let status: String?
                let version: String?
                let max_version: String?
            }
            let versions: [Entry]
        }
        if let list = try? JSONDecoder().decode(VersionsList.self, from: body) {
            // Prefer the CURRENT entry; else the entry with the highest version.
            let current = list.versions.first(where: { $0.status?.uppercased() == "CURRENT" })
            let candidates: [VersionsList.Entry] = current != nil ? [current!] : list.versions
            var best: Microversion?
            for entry in candidates {
                let v = entry.max_version.flatMap { Microversion($0) }
                    ?? entry.version.flatMap { Microversion($0) }
                if let v, best == nil || v > best! {
                    best = v
                }
            }
            if let best {
                return best
            }
        }

        // Legacy object form: {"version":{"max_version":"2.104"}}
        struct VersionDoc: Codable {
            struct Version: Codable {
                let max_version: String?
                let version: String?
            }
            let version: Version
        }
        if let doc = try? JSONDecoder().decode(VersionDoc.self, from: body) {
            if let m = doc.version.max_version, let mv = Microversion(m) { return mv }
            if let v = doc.version.version, let mv = Microversion(v) { return mv }
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
