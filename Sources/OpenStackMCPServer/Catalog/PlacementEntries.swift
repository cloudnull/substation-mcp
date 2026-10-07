import Foundation

/// Placement (resource providers) resource entries. 1 resource:
/// `placement` (a resource provider) — list/get only, read-only.
///
/// The resource provider is the authoritative per-host inventory entry:
/// its `inventory` holds resource-class totals (VCPU, MEMORY_MB, DISK_GB, and
/// GPU/PCI classes on accelerated clouds) and its `usages` hold allocated
/// amounts. `os_get placement <uuid>` merges both into one response. The
/// provider name (e.g. `compute://host-01`) is how a server's hostId is
/// correlated with real hardware inventory.
enum PlacementEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "placement",
            service: .placement,
            verbs: [.list, .get],
            actions: [],
            links: [],
            createSchema: nil,
            updateSchema: nil,
            listFilters: ["name"],
            idField: "uuid",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["uuid", "name", "generation"],
            phase1Note: nil
        ),
    ]
}
