import Foundation

/// Magnum (container infrastructure) resource entries. 2 resources per spec
/// (phase 2): `cluster` (pollable — status CREATING -> ACTIVE / ERROR) and
/// `cluster_template`.
enum ContainerEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "cluster",
            service: .containerInfra,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Cluster name"),
                    "cluster_template_id": .init(type: "string", description: "Cluster template id"),
                    "master_count": .init(type: "integer", description: "Number of master nodes"),
                    "node_count": .init(type: "integer", description: "Number of worker nodes"),
                    "server_group": .init(type: "string", description: "Server group name"),
                ],
                required: ["name"]
            ),
            updateSchema: nil,
            listFilters: ["name", "status", "cluster_template_id"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["ACTIVE", "ERROR", "DELETE_COMPLETE"],
            defaultListFields: ["id", "name", "status", "master_count", "node_count", "created_at"]
        ),
        ResourceDescriptor(
            name: "cluster_template",
            service: .containerInfra,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Template name"),
                    "master_count": .init(type: "integer", description: "Number of master nodes"),
                    "node_count": .init(type: "integer", description: "Number of worker nodes"),
                ],
                required: ["name"]
            ),
            updateSchema: nil,
            listFilters: ["name"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "master_count", "node_count", "created_at"]
        ),
    ]
}
