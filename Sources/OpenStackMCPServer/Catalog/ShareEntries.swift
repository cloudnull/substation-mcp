import Foundation

/// Manila (shared file systems) resource entries. 2 resources per spec
/// (phase 2): `share` (pollable — status creating -> available) and
/// `share_access` (share-scoped).
enum ShareEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "share",
            service: .sharev2,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Share name"),
                    "share_size": .init(type: "integer", description: "Size in GiB"),
                    "share_type": .init(type: "string", description: "Share type"),
                    "description": .init(type: "string", description: "Description"),
                    "is_public": .init(type: "boolean", description: "Whether the share is public"),
                ],
                required: ["name"]
            ),
            updateSchema: nil,
            listFilters: ["name", "status", "share_type"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["available", "error", "deleted"],
            defaultListFields: ["id", "name", "status", "share_size", "share_type", "created_at"]
        ),
        ResourceDescriptor(
            name: "share_access",
            service: .sharev2,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "share_id": .init(type: "string", description: "Share id"),
                    "access_to": .init(type: "string", description: "User, group, or IP to grant access to"),
                    "access_type": .init(type: "string", enumValues: ["ip", "user", "group", "cert", "cert_group"], description: "Access type"),
                    "access_protocol": .init(type: "string", description: "Protocol (nfs, cifs, glusterfs)"),
                ],
                required: ["share_id", "access_to"]
            ),
            updateSchema: nil,
            listFilters: ["access_to", "access_type", "access_protocol"],
            idField: "id",
            nameField: nil,
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "share_id", "access_to", "access_type", "access_protocol", "state"]
        ),
    ]
}
