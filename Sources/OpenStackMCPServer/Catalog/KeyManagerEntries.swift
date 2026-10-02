import Foundation

/// Barbican (key manager) resource entries. 2 resources per spec (phase 2):
/// `secret` (pollable — status lifecycle inactive -> active) and `container`.
enum KeyManagerEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "secret",
            service: .keyManager,
            verbs: [.list, .get, .create, .delete],
            actions: [
                ActionSpec(name: "get_payload", params: [])
            ],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Secret name"),
                    "type": .init(type: "string", enumValues: ["opaque", "symmetric_key", "asymmetric_key", "certificate", "private_key", "public_key"], description: "Secret type"),
                    "algorithm": .init(type: "string", description: "Algorithm (for key types)"),
                    "bit_size": .init(type: "integer", description: "Key bit size"),
                    "mode": .init(type: "string", enumValues: ["CBC", "CFB", "ECB", "OFB", "XTS", "GCM"], description: "Mode (for symmetric keys)"),
                    "secret": .init(type: "string", description: "Base64 payload (for opaque secrets)"),
                    "visibility": .init(type: "string", enumValues: ["private", "shared", "public"], description: "Visibility"),
                ],
                required: []
            ),
            updateSchema: nil,
            listFilters: ["name", "type", "status", "visibility"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["active", "expired", "deleted"],
            defaultListFields: ["id", "name", "type", "status", "visibility", "created_at"]
        ),
        ResourceDescriptor(
            name: "secret_container",
            service: .keyManager,
            verbs: [.list, .get, .delete],
            actions: [],
            links: [],
            createSchema: nil,
            updateSchema: nil,
            listFilters: ["name", "type"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "type", "secret_refs"]
        ),
    ]
}
