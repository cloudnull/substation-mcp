import Foundation

/// Gnocchi (metric) resource entries — phase 2, IAD3 gap-fill.
/// Resources: `metric` (read-only; metrics are collector-written) and
/// `resource_type` (the Gnocchi resource-type map).
enum MetricEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "metric",
            service: .metric,
            verbs: [.list, .get],
            actions: [],
            links: [],
            listFilters: ["name", "resource_id", "archive_policy"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "unit", "resource_id", "creator", "created"]
        ),
        ResourceDescriptor(
            name: "resource_type",
            service: .metric,
            verbs: [.list, .get],
            actions: [],
            links: [],
            listFilters: [],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "href"]
        ),
    ]
}
