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
            defaultListFields: ["id", "name", "status", "allocation_id", "instance_id", "created"],
            phase1Note: "Live-validated on IAD3 (2026-10-19): the catalog advertises blazar at `/v1` and the edge serves 401 for unauthenticated requests (routing alive), but every authenticated request 503s with 'The Keystone service is temporarily unavailable' — the failure is in Blazar's Keystone token-validation hop, not the reservation API (stable across /v1, /v1/reservations, /v1/hosts and retries). The client is wired and fake-tested; retry when the upstream heals — no code change needed."
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
            defaultListFields: ["id", "status", "node_id", "reservation_id", "created"],
            phase1Note: "Same upstream outage as `reservation` (live-validated IAD3 2026-10-19): Blazar's Keystone token-validation hop 503s for every authenticated request; client wired + fake-tested, no code change needed when it heals."
        ),
    ]
}
