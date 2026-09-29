import Foundation

/// The decoded Keystone service catalog from a validated token.
public struct ServiceCatalog: Sendable, Equatable {
    public let entries: [CatalogEntry]

    public init(entries: [CatalogEntry]) {
        self.entries = entries
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
