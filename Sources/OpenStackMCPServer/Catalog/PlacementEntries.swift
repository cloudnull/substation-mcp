import Foundation

/// Placement (resource providers) resource entries. 1 resource:
/// `placement` (a resource provider) — list/get, plus capacity-planning actions.
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
            // Admin capacity view (validated live on SAT0, 2026-10-18):
            //   GET /resource_providers/{uuid}/allocations  action "allocations"
            //   GET /allocation_candidates                  action "candidates"
            // Both return the raw placement payload (resource-class maps are
            // open-ended, so they are passed through unmodeled).
            actions: [
                ActionSpec(name: "allocations", adminOnly: true, params: []),
                ActionSpec(name: "candidates", adminOnly: true, params: [
                    ParamSpec(name: "resources", required: true, description: "Placement resource syntax, e.g. \"VCPU:2,MEMORY_MB:4096\" (groups separated by ';')"),
                    ParamSpec(name: "limit", type: "integer", description: "Max candidates to return"),
                    ParamSpec(name: "in_tree", type: "boolean", description: "Restrict candidates to a single provider tree"),
                ]),
            ],
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
