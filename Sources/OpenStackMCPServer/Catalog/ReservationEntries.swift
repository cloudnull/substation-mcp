import Foundation

/// Blazar (reservation) resource entries — phase 2, IAD3 gap-fill.
/// Resources: `reservation` (pollable BUILDING -> ACTIVE / ERROR) and
/// `allocation` (read-only).
enum ReservationEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "reservation",
            service: .reservation,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Reservation name"),
                    "flavor_id": .init(type: "string", description: "Nova flavor id to reserve"),
                    "expiry": .init(type: "string", description: "ISO 8601 expiry (defaults to the Blazar policy expiry)"),
                ],
                required: []
            ),
            updateSchema: nil,
            listFilters: ["status", "allocation_id"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["ACTIVE", "ERROR", "DELETED"],
            defaultListFields: ["id", "name", "status", "allocation_id", "instance_id", "created"]
        ),
        ResourceDescriptor(
            name: "allocation",
            service: .reservation,
            verbs: [.list, .get],
            actions: [],
            links: [],
            listFilters: ["status", "reservation_id"],
            idField: "id",
            nameField: nil,
            statusField: "status",
            terminalStates: [],
            defaultListFields: ["id", "status", "node_id", "reservation_id", "created"]
        ),
    ]
}
