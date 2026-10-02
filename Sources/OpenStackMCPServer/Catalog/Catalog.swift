import Foundation

/// The phase 1 resource catalog: all 33 resources from spec §8.5 with their
/// verbs, actions, links, terminal states, and dispatch closures.
public struct ResourceCatalog: Sendable {
    public let resources: [ResourceDescriptor]

    private let byName: [String: ResourceDescriptor]

    public init(resources: [ResourceDescriptor]) {
        self.resources = resources
        self.byName = Dictionary(uniqueKeysWithValues: resources.map { ($0.name, $0) })
    }

    /// The full phase 1 catalog.
    public static func phase1() -> ResourceCatalog {
        let all = [
            IdentityEntries.all,
            ComputeEntries.all,
            NetworkEntries.all,
            BlockStorageEntries.all,
            ImageEntries.all,
            ObjectStorageEntries.all,
            KeyManagerEntries.all,
            LoadBalancerEntries.all,
            DNSEntries.all,
            ContainerEntries.all,
            OrchestrationEntries.all,
        ].flatMap { $0 }
        return ResourceCatalog(resources: all)
    }

    /// Look up a descriptor by resource name.
    public func descriptor(_ name: String) -> ResourceDescriptor? {
        byName[name]
    }

    /// All resource names.
    public var names: [String] {
        resources.map(\.name)
    }

    /// Resources for a given service.
    public func resources(for service: Service) -> [ResourceDescriptor] {
        resources.filter { $0.service == service }
    }

    /// All action specs for a resource, keyed by action name.
    public func actions(for resource: String) -> [String: ActionSpec] {
        guard let d = byName[resource] else { return [:] }
        return Dictionary(uniqueKeysWithValues: d.actions.map { ($0.name, $0) })
    }

    /// All link specs across all resources, keyed by link kind.
    public var allLinks: [String: LinkSpec] {
        var links: [String: LinkSpec] = [:]
        for r in resources {
            for link in r.links {
                links[link.kind] = link
            }
        }
        return links
    }
}
