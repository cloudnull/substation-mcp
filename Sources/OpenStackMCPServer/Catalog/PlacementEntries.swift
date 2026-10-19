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
                ActionSpec(name: "allocations", adminOnly: true, params: [
                    ParamSpec(name: "consumer_uuid", description: "Optional: narrow to allocations made by one consumer (server uuid)")
                ]),
                ActionSpec(name: "candidates", adminOnly: true, params: [
                    ParamSpec(name: "resources", required: true, description: "Placement resource syntax, e.g. \"VCPU:2,MEMORY_MB:4096\" (groups separated by ';')"),
                    ParamSpec(name: "limit", type: "integer", description: "Max candidates to return"),
                    ParamSpec(name: "in_tree", description: "Restrict candidates to one provider tree (provider-tree uuid)"),
                    ParamSpec(name: "required", description: "Resource classes the provider tree MUST have (comma-separated), e.g. \"CUSTOM_HW_CPU_THREAD\""),
                    ParamSpec(name: "member_of", description: "Only providers in these aggregates: \"~in:<agg_uuid>,<agg_uuid>\" (repeat groups with ';')"),
                    ParamSpec(name: "not_member_of", description: "Exclude providers in these aggregates (same syntax as member_of) — use it to keep candidates off the host being evacuated"),
                    ParamSpec(name: "group_policy", enumValues: ["none", "aggregate"], description: "\"aggregate\": each multi-provider request must resolve within one provider tree/aggregate"),
                    ParamSpec(name: "include_all_providers", type: "boolean", description: "true: also return providers that match no resource class (debugging inventory)"),
                ]),
            ],
            links: [],
            createSchema: nil,
            updateSchema: nil,
            listFilters: ["name", "type"],
            idField: "uuid",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["uuid", "name", "generation"],
            phase1Note: "Live-validated on IAD3 (2026-10-18): the placement service is advertised in the catalog and `/` serves the version doc (v1.0-1.39), but `allocation_candidates` returns 404 through the public proxy — Rackspace does not expose it publicly. `resource_providers` requires placement policy. On such clouds use host=null migration actions (Nova schedules) and `os_list(hypervisor)` capacity fields for placement; candidates remains the path on clouds that expose placement (validated on SAT0).",
        ),
    ]
}
