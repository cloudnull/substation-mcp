import Foundation

/// Gnocchi (metric / Rackspace meterng) resource entries — phase 2, IAD3
/// gap-fill, deepened 2026-10-18 against live IAD3 meterng.
///
/// Resources: `metric` (list/get + `measures`/`metrics` actions; create/delete
/// allowed — meterng grants project members their own metric namespace),
/// `resource_type` (the Gnocchi resource-type map, + `metrics` join action),
/// and `archive_policy` (the aggregation/granularity vocabulary).
///
/// Live-validated surface (all with a project-scoped member token):
///   GET  /v1/metric, /v1/metric/{id}, /v1/metric/{id}/measures (raw + agg)
///   POST /v1/metric (201), DELETE /v1/metric/{id} (204)
///   GET  /v1/archive_policy, /v1/resource (map), /v1/metric?resource_id=
/// NOT available on this deployment: PATCH metric (405), relative time
/// windows (400), /v1/status (403 non-admin), measures of other projects'
/// metrics (403), POST /search/* (503 upstream).
enum MetricEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "metric",
            service: .metric,
            verbs: [.list, .get, .create, .delete],
            actions: [
                // Read actions: measures retrieval (no write scope semantics —
                // the gate is the cloud's own per-project policy).
                ActionSpec(name: "measures", params: [
                    ParamSpec(name: "aggregation", description: "Aggregation method from the metric's archive policy (e.g. mean, rate:mean). Requires granularity; omit both for raw stored measures"),
                    ParamSpec(name: "granularity", description: "Aggregation granularity from the archive policy definition (e.g. 0:05:00). See os_list archive_policy"),
                    ParamSpec(name: "start", description: "Window start, ABSOLUTE ISO-8601 only (e.g. 2026-10-17T00:00:00+00:00 or 2026-10-17). Relative forms like -P7D are rejected by meterng"),
                    ParamSpec(name: "stop", description: "Window stop, absolute ISO-8601"),
                    ParamSpec(name: "limit", type: "integer", description: "Max points to return"),
                ]),
                ActionSpec(name: "metrics", params: [
                    ParamSpec(name: "resource_id", required: true, description: "Gnocchi resource id — for a server this is the server uuid (instance resource type)"),
                ]),
            ],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "archive_policy": .init(type: "string", description: "Archive policy name (see os_list archive_policy; meterng: low, medium, high, bool, ceilometer-low, ceilometer-low-rate, ceilometer-high, ceilometer-high-rate)"),
                    "name": .init(type: "string", description: "Optional metric name"),
                    "unit": .init(type: "string", description: "Optional unit (e.g. B, ns, %)"),
                ],
                required: ["archive_policy"]
            ),
            updateSchema: nil,
            listFilters: ["name", "resource_id", "archive_policy", "marker"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "unit", "resource_id", "creator", "created"],
            phase1Note: "Measures are readable only for metrics in the caller's project (meterng enforces this per-project). Absolute time windows only. Metrics bound to a monitored resource cannot be deleted (409)."
        ),
        ResourceDescriptor(
            name: "resource_type",
            service: .metric,
            verbs: [.list, .get],
            actions: [
                ActionSpec(name: "metrics", params: [
                    ParamSpec(name: "resource_id", required: true, description: "Resource id of this type (e.g. the server uuid for type `instance`)"),
                ]),
            ],
            links: [],
            listFilters: [],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "href"],
            phase1Note: "Gnocchi resource types (instance, volume, network, host, …) are the metering-side view of cloud resources; the `instance` resource id equals the server uuid."
        ),
        ResourceDescriptor(
            name: "archive_policy",
            service: .metric,
            verbs: [.list, .get],
            actions: [],
            links: [],
            listFilters: [],
            idField: "name",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["name", "definition", "aggregation_methods"],
            phase1Note: "Read-only vocabulary: the definition steps are the legal `granularity` values and aggregation_methods the legal `aggregation` values for os_action(metric, <id>, measures)."
        ),
    ]
}
