import Foundation

/// Throws the no-endpoint error when the token's service catalog has no
/// endpoint for the given service type in the given region.
///
/// This is the single chokepoint for the Review Focus 3 requirement:
/// calling a region operation in a region where the service has no
/// advertised endpoint fails fast with a clear `OpenStackError`.
func guardEndpoint(serviceType: String, region: String, vt: ValidatedToken) throws {
    let resolver = EndpointResolver(
        catalog: ServiceCatalog(entries: vt.token.catalog)
    )
    _ = try resolver.endpoint(serviceType: serviceType, region: region)
}
