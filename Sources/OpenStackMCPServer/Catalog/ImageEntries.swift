import Foundation

/// Image (Glance v2) resource entries. 1 resource per spec §8.5.
enum ImageEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "image",
            service: .image,
            verbs: [.list, .get, .create, .update, .delete],
            actions: [
                ActionSpec(name: "set_visibility", params: [
                    ParamSpec(name: "visibility", required: true, enumValues: ["public", "private", "shared", "community"], description: "New visibility")
                ]),
                ActionSpec(name: "protect"),
                ActionSpec(name: "unprotect"),
                ActionSpec(name: "add_tag", params: [ParamSpec(name: "tag", required: true, description: "Tag to add")]),
                ActionSpec(name: "remove_tag", params: [ParamSpec(name: "tag", required: true, description: "Tag to remove")]),
                ActionSpec(name: "deactivate", destructive: true),
                ActionSpec(name: "reactivate"),
            ],
            links: [
                LinkSpec(
                    kind: "image",
                    source: .init(resource: "volume"),
                    target: .init(resource: "image"),
                    preconditions: []
                ),
            ],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Image name"),
                    "disk_format": .init(type: "string", enumValues: ["qcow2", "raw", "vhd", "vhdx", "vdi", "iso", "aki", "ari", "ami"], description: "Disk format"),
                    "container_format": .init(type: "string", enumValues: ["bare", "aki", "ari", "ami", "ovf", "ova", "docker"], description: "Container format"),
                    "visibility": .init(type: "string", enumValues: ["public", "private", "shared", "community"], description: "Visibility"),
                    "min_ram": .init(type: "integer", description: "Minimum RAM in MB"),
                    "protected": .init(type: "boolean", description: "Protection flag"),
                    "properties": .init(type: "object", description: "Image properties"),
                    "tags": .init(type: "array", items: .init(type: "string"), description: "Tags"),
                    "import": .init(type: "object", properties: [
                        "method": .init(type: "string", enumValues: ["web-download", "direct", "copy"], description: "Import method"),
                        "uri": .init(type: "string", description: "Source URI (for web-download)"),
                        "disk_format": .init(type: "string", description: "Disk format for import"),
                        "container_format": .init(type: "string", description: "Container format for import")
                    ], description: "Import specification (for web-download or direct upload)")
                ],
                required: ["name", "disk_format", "container_format"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "visibility": .init(type: "string", enumValues: ["public", "private", "shared", "community"]),
                "protected": .init(type: "boolean"),
                "min_ram": .init(type: "integer"),
                "tags": .init(type: "array", items: .init(type: "string")),
                "properties": .init(type: "object")
            ]),
            listFilters: ["name", "status", "visibility", "disk_format", "container_format", "tags", "protected"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["active", "killed"],
            defaultListFields: ["id", "name", "status", "visibility", "disk_format", "created_at"]
        ),
    ]
}
