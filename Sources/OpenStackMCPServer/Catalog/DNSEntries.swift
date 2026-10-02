import Foundation

/// Designate (DNS) resource entries. 2 resources per spec (phase 2):
/// `zone` (pollable — status lifecycle pending -> active) and `recordset`.
enum DNSEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "zone",
            service: .dns,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Zone name (FQDN, trailing dot)"),
                    "email": .init(type: "string", description: "SOA email"),
                    "ttl": .init(type: "integer", description: "TTL in seconds"),
                ],
                required: ["name"]
            ),
            updateSchema: nil,
            listFilters: ["name", "status"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["active", "pending_delete"],
            defaultListFields: ["id", "name", "status", "ttl", "email", "created_at"]
        ),
        ResourceDescriptor(
            name: "recordset",
            service: .dns,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Record name (FQDN)"),
                    "type": .init(type: "string", enumValues: ["A", "AAAA", "CNAME", "MX", "NS", "PTR", "SRV", "TXT"], description: "Record type"),
                    "ttl": .init(type: "integer", description: "TTL in seconds"),
                    "records": .init(type: "array", items: .init(type: "string"), description: "Record values"),
                    "zone_id": .init(type: "string", description: "Zone id"),
                ],
                required: ["name", "type", "records"]
            ),
            updateSchema: nil,
            listFilters: ["name", "type", "zone_id"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "type", "ttl", "records", "zone_id"]
        ),
    ]
}
