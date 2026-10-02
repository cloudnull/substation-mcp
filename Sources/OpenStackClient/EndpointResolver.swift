import Foundation

/// The decoded Keystone service catalog from a validated token.
public struct ServiceCatalog: Sendable, Equatable {
    public let entries: [CatalogEntry]

    public init(entries: [CatalogEntry]) {
        self.entries = entries
    }
}

/// The effective base URL and path prefix for a service call, resolved from
/// the token's service catalog so that multi-endpoint clouds (e.g. Rackspace,
/// where each service lives on its own host) route to the correct endpoint.
///
/// - `base`: the URL the request is sent to (the catalog endpoint URL when the
///   catalog is the authoritative root, else the catalog host, else the cloud's
///   `authURL`).
/// - `pathPrefix`: the prefix to prepend to a resource-relative path. Empty when
///   the catalog URL already carries the service's version root (so the client's
///   own `basePath` is dropped); otherwise the service's `basePath` so the
///   request keeps its version root.
///
/// A service composes its request as `base.appendingPathComponent(pathPrefix +
/// "/" + resourcePath)` where `resourcePath` is the path after the service's
/// `basePath`.
public struct ResolvedEndpoint: Sendable {
    public let base: URL
    public let pathPrefix: String
}

extension EndpointResolver {
    /// Build a resolver for a token's catalog using the cloud's interface.
    init(vt: ValidatedToken, interface: String) {
        self.init(catalog: ServiceCatalog(entries: vt.token.catalog), preferredInterface: interface)
    }

    /// Resolve the base URL + path prefix for a service call.
    ///
    /// The catalog endpoint URL is authoritative for the **host**. Whether it is
    /// also authoritative for the **version root** is detected dynamically: if
    /// the catalog URL's path ends with the service's `versionRoot` segment, the
    /// catalog is the root and the client's own `basePath` is dropped
    /// (`pathPrefix == ""`). If the catalog URL omits the version root (Rackspace
    /// advertises neutron at `.../neutron/` but the real API is at
    /// `.../v2.0/...`), the catalog host is used and the client keeps its
    /// `basePath` so the request carries the correct version.
    ///
    /// - Parameters:
    ///   - serviceType: the Keystone service type (e.g. `compute`).
    ///   - region: the target region.
    ///   - basePath: the service's own prefix used in `transport.request` paths
    ///     (e.g. `neutron/v2.0`, `nova`).
    ///   - serviceRoot: the version root the service's catalog URL *should*
    ///     carry (e.g. `v2.0` for neutron). Empty for services whose catalog URL
    ///     is always treated as the authoritative root (nova, cinder, glance,
    ///     etc. — the catalog URL, whether `host/nova` or `nova.api/v2.1`, is
    ///     used in full and the client's `basePath` is dropped). When non-empty,
    ///     the resolver verifies the catalog path ends with it; if it does not
    ///     (Rackspace advertises neutron at `.../neutron/` but the real API is at
    ///     `.../v2.0/...`), the catalog host is used and `serviceRoot` is the
    ///     prefix so the request keeps the correct version.
    ///   - fallbackBase: the cloud `authURL`, used when the catalog has no
    ///     endpoint for this service/region (preserves single-endpoint behavior).
    ///     In that case the full `basePath` is kept (the authURL host is the
    ///     single host that serves all services under their basePath).
    public func resolveEndpoint(
        serviceType: String,
        region: String,
        basePath: String,
        serviceRoot: String,
        fallbackBase: URL?
    ) throws -> ResolvedEndpoint {
        var url: URL
        do {
            url = try endpoint(serviceType: serviceType, region: region)
        } catch {
            // No catalog endpoint (service absent for this token/region): fall
            // back to the cloud authURL with the service's full basePath when
            // one is available; otherwise surface the missing-endpoint error.
            if let fb = fallbackBase {
                return ResolvedEndpoint(base: fb, pathPrefix: basePath)
            }
            throw error
        }

        if catalogPathIncludesRoot(url, root: serviceRoot) {
            // Catalog is the authoritative root: use it in full and drop the
            // client's basePath.
            return ResolvedEndpoint(base: url, pathPrefix: "")
        }

        // Catalog host is authoritative but its path omits the service root
        // (Rackspace advertises neutron at `.../neutron/` but the real API is at
        // `.../v2.0/...`): use the catalog host and prepend the service root so
        // the request carries the correct version without a spurious
        // service-name segment.
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.path = ""
        guard let hostBase = comps?.url else {
            return ResolvedEndpoint(base: url, pathPrefix: serviceRoot)
        }
        return ResolvedEndpoint(base: hostBase, pathPrefix: serviceRoot)
    }

    /// True when the catalog URL's path already carries the service root, so
    /// the URL is the authoritative service base and the client's `basePath`
    /// can be dropped.
    private func catalogPathIncludesRoot(_ url: URL, root: String) -> Bool {
        guard !root.isEmpty else { return true }
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        return path.hasSuffix("/\(root)")
    }
}

/// Resolves service endpoints from the token's catalog, preferring a
/// configured interface and falling back public → internal → admin.
public struct EndpointResolver: Sendable {
    private let catalog: ServiceCatalog
    private let preferredInterface: String

    public init(catalog: ServiceCatalog, preferredInterface: String = "public") {
        self.catalog = catalog
        self.preferredInterface = preferredInterface
    }

    /// Resolve the endpoint URL for a service type in a region.
    /// Throws `OpenStackError` with code "no-endpoint" when no endpoint is found.
    public func endpoint(serviceType: String, region: String) throws -> URL {
        // Find all endpoints for this service type + region
        let matching = catalog.entries
            .filter { $0.type == serviceType }
            .flatMap { $0.endpoints }
            .filter { $0.region == region }

        guard !matching.isEmpty else {
            let interfacesTried = ["public", "internal", "admin"]
            throw OpenStackError(
                service: serviceType,
                status: 0,
                code: "no-endpoint",
                message: "no \(serviceType) endpoint in region \(region) (interfaces tried: \(interfacesTried.joined(separator: ", ")))",
                hint: "check the cloud's service catalog"
            )
        }

        // Try preferred interface first, then public → internal → admin
        let fallbackOrder = ["public", "internal", "admin"]
        let ordered = [preferredInterface] + fallbackOrder.filter { $0 != preferredInterface }

        for interface in ordered {
            if let ep = matching.first(where: { $0.interface == interface }) {
                return ep.url
            }
        }

        // If we got here, the matching endpoints exist but none matched our interface list.
        // Return the first one as a last resort.
        return matching[0].url
    }
}
