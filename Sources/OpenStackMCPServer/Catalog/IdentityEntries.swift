import Foundation

/// Identity (Keystone v3) resource entries. 10 resources per spec §8.5.
enum IdentityEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "region",
            service: .identity,
            verbs: [.list, .get],
            idField: "id",
            nameField: "id",
            defaultListFields: ["id"]
        ),
        ResourceDescriptor(
            name: "project",
            service: .identity,
            verbs: [.list, .get, .create, .update, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Project name"),
                    "description": .init(type: "string"),
                    "domain_id": .init(type: "string", description: "Domain ID"),
                    "enabled": .init(type: "boolean")
                ],
                required: ["name"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "description": .init(type: "string"),
                "enabled": .init(type: "boolean")
            ]),
            listFilters: ["name", "domain", "enabled"],
            idField: "id",
            nameField: "name",
            statusField: "enabled"
        ),
        ResourceDescriptor(
            name: "user",
            service: .identity,
            verbs: [.list, .get, .create, .update, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "User name"),
                    "domain_id": .init(type: "string", description: "Domain ID"),
                    "email": .init(type: "string"),
                    "password": .init(type: "string", description: "Initial password (never echoed)"),
                    "enabled": .init(type: "boolean")
                ],
                required: ["name"]
            ),
            updateSchema: .init(type: "object", properties: [
                "email": .init(type: "string"),
                "enabled": .init(type: "boolean"),
                "password": .init(type: "string")
            ]),
            listFilters: ["name", "domain", "email", "enabled"],
            idField: "id",
            nameField: "name",
            statusField: "enabled"
        ),
        ResourceDescriptor(
            name: "group",
            service: .identity,
            verbs: [.list, .get, .create, .update, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Group name"),
                    "description": .init(type: "string"),
                    "domain_id": .init(type: "string")
                ],
                required: ["name"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "description": .init(type: "string")
            ]),
            listFilters: ["name", "domain"],
            idField: "id",
            nameField: "name"
        ),
        ResourceDescriptor(
            name: "role",
            service: .identity,
            verbs: [.list, .get, .create, .update, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Role name"),
                    "domain_id": .init(type: "string")
                ],
                required: ["name"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string", description: "New role name")
            ]),
            listFilters: ["name", "domain"],
            idField: "id",
            nameField: "name"
        ),
        ResourceDescriptor(
            name: "role_assignment",
            service: .identity,
            verbs: [.list, .create, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "role": .init(type: "string", description: "Role ID or name"),
                    "user": .init(type: "string", description: "User ID or name"),
                    "project": .init(type: "string", description: "Project ID or name"),
                    "group": .init(type: "string", description: "Group ID or name (alternative to user)")
                ],
                required: ["role"]
            ),
            listFilters: ["role", "user", "project", "group", "scope"],
            idField: "id",
            nameField: nil
        ),
        ResourceDescriptor(
            name: "domain",
            service: .identity,
            verbs: [.list, .get, .create, .update, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Domain name"),
                    "description": .init(type: "string"),
                    "enabled": .init(type: "boolean")
                ],
                required: ["name"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "description": .init(type: "string"),
                "enabled": .init(type: "boolean")
            ]),
            listFilters: ["name", "enabled"],
            idField: "id",
            nameField: "name",
            statusField: "enabled"
        ),
        ResourceDescriptor(
            name: "service",
            service: .identity,
            verbs: [.list, .get],
            listFilters: ["type", "name"],
            idField: "id",
            nameField: "name"
        ),
        ResourceDescriptor(
            name: "endpoint",
            service: .identity,
            verbs: [.list, .get],
            listFilters: ["service_id", "interface", "region"],
            idField: "id",
            nameField: nil
        ),
        ResourceDescriptor(
            name: "application_credential",
            service: .identity,
            verbs: [.list, .get],
            listFilters: ["name", "user"],
            idField: "id",
            nameField: "name",
            statusField: "enabled"
        ),
    ]
}
