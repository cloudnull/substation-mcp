import Foundation

/// Trove (database) resource entries — phase 2, IAD3 gap-fill.
/// Resources: `database_instance` (pollable BUILD -> ACTIVE / ERROR),
/// `database_flavor`, `database_datastore` (read-only catalogs).
enum DatabaseEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "database_instance",
            service: .database,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Instance name"),
                    "flavorRef": .init(type: "string", description: "Database flavor id (from database_flavor)"),
                    "volume_size": .init(type: "integer", description: "Storage size in GB"),
                    "datastore": .init(type: "string", description: "Datastore type name, e.g. mysql (default: mysql)"),
                ],
                required: ["name", "flavorRef", "volume_size"]
            ),
            updateSchema: nil,
            listFilters: ["status", "datastore"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["ACTIVE", "ERROR", "SHUTDOWN"],
            defaultListFields: ["id", "name", "status", "versionNumber", "ip", "created"]
        ),
        ResourceDescriptor(
            name: "database_flavor",
            service: .database,
            verbs: [.list, .get],
            actions: [],
            links: [],
            listFilters: [],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "vcpus", "ram", "disk"]
        ),
        ResourceDescriptor(
            name: "database_datastore",
            service: .database,
            verbs: [.list, .get],
            actions: [],
            links: [],
            listFilters: ["name"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name"]
        ),
    ]
}
