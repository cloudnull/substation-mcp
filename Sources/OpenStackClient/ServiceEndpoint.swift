import Foundation

/// Computes the effective base URL + request path for a service call, routing
/// to the service's real endpoint from the token's catalog when available
/// (multi-endpoint clouds like Rackspace, where each service lives on its own
/// host), and falling back to the cloud's `authURL` when the catalog has no
/// endpoint for the service/region (single-endpoint clouds).
///
/// - `fullPath` is the service path as the caller would build it relative to the
///   cloud authURL, i.e. `"\(basePath)/<resource>"` (e.g. `nova/servers`,
///   `neutron/v2.0/networks`). The leading `basePath` is stripped and replaced
///   with the resolved prefix so the request targets the correct service root.
///
/// Returns `(overrideBase, path)` where `overrideBase` is `nil` when the cloud
/// has no `authURL` (the test/local fake path) and the existing `baseURL`
/// default applies.
func resolveServiceEndpoint(
    vt: ValidatedToken,
    region: String,
    cloud: CloudEntry,
    basePath: String,
    serviceRoot: String,
    serviceType: String,
    fullPath: String
) -> (overrideBase: URL?, path: String) {
    // Strip the leading basePath so the resource path is relative to the
    // service root (e.g. `nova/servers` -> `servers`).
    let resource: String
    if fullPath.hasPrefix(basePath) {
        let remainder = String(fullPath.dropFirst(basePath.count))
        resource = remainder.hasPrefix("/") ? String(remainder.dropFirst()) : remainder
    } else {
        resource = fullPath
    }

    guard let authURL = cloud.authURL else {
        // No authURL (local/test rig): let the transport's default base apply.
        return (nil, fullPath)
    }

    let resolver = EndpointResolver(
        catalog: ServiceCatalog(entries: vt.token.catalog),
        preferredInterface: cloud.interface
    )
    let ep = (try? resolver.resolveEndpoint(
        serviceType: serviceType,
        region: region,
        basePath: basePath,
        serviceRoot: serviceRoot,
        fallbackBase: authURL
    )) ?? ResolvedEndpoint(base: authURL, pathPrefix: basePath)

    let joined = ep.pathPrefix.isEmpty
        ? resource
        : "\(ep.pathPrefix)/\(resource)"
    return (ep.base, joined)
}
