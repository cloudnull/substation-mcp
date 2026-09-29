import Foundation

/// Block storage (Cinder v3) resource entries. 5 resources per spec §8.5.
enum BlockStorageEntries {
    static let all: [ResourceDescriptor] = [
        // MARK: - volume

        ResourceDescriptor(
            name: "volume",
            service: .blockStorage,
            verbs: [.list, .get, .create, .update, .delete],
            actions: [
                ActionSpec(name: "extend", params: [ParamSpec(name: "size", type: "integer", required: true, description: "New size in GB")]),
                ActionSpec(name: "retype", params: [
                    ParamSpec(name: "volume_type", required: true, description: "Target volume type"),
                    ParamSpec(name: "reason", description: "Reason for retype")
                ]),
                ActionSpec(name: "reset_status", destructive: true, params: [
                    ParamSpec(name: "status", required: true, enumValues: ["available", "in-use", "error"], description: "New status")
                ]),
                ActionSpec(name: "upload_to_image", params: [
                    ParamSpec(name: "image_name", required: true, description: "Target image name"),
                    ParamSpec(name: "force", type: "boolean", description: "Force upload even if volume is attached")
                ]),
                ActionSpec(name: "set_bootable", params: [
                    ParamSpec(name: "bootable", type: "boolean", required: true, description: "Bootable flag")
                ]),
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
                    "name": .init(type: "string", description: "Volume name"),
                    "size": .init(type: "integer", description: "Size in GB"),
                    "volume_type": .init(type: "string", description: "Volume type"),
                    "description": .init(type: "string"),
                    "imageRef": .init(type: "string", description: "Source image ID"),
                    "snapshot_id": .init(type: "string", description: "Source snapshot ID"),
                    "source_vol_id": .init(type: "string", description: "Source volume ID (clone)"),
                    "availability_zone": .init(type: "string", description: "Availability zone"),
                    "metadata": .init(type: "object", description: "Key-value metadata")
                ],
                required: ["size"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "description": .init(type: "string")
            ]),
            listFilters: ["name", "status", "size", "volume_type", "availability_zone"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["available", "in-use", "error"],
            defaultListFields: ["id", "name", "status", "size", "volume_type", "availability_zone", "created_at"]
        ),

        // MARK: - volume_type

        ResourceDescriptor(
            name: "volume_type",
            service: .blockStorage,
            verbs: [.list, .get, .create, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Volume type name"),
                    "specifications": .init(type: "object", description: "Key-value specifications"),
                    "extra_specs": .init(type: "object", description: "Extra specifications")
                ],
                required: ["name"]
            ),
            listFilters: ["name"],
            idField: "id",
            nameField: "name"
        ),

        // MARK: - volume_snapshot

        ResourceDescriptor(
            name: "volume_snapshot",
            service: .blockStorage,
            verbs: [.list, .get, .create, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Snapshot name"),
                    "volume_id": .init(type: "string", description: "Volume ID"),
                    "description": .init(type: "string"),
                    "force": .init(type: "boolean", description: "Force snapshot of in-use volume")
                ],
                required: ["volume_id"]
            ),
            listFilters: ["name", "status", "volume_id"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["available", "error"]
        ),

        // MARK: - volume_backup

        ResourceDescriptor(
            name: "volume_backup",
            service: .blockStorage,
            verbs: [.list, .get, .create, .delete],
            actions: [
                ActionSpec(name: "restore", destructive: true, params: [
                    ParamSpec(name: "volume_id", description: "Target volume ID (existing volume to restore into)")
                ])
            ],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Backup name"),
                    "volume_id": .init(type: "string", description: "Volume ID"),
                    "description": .init(type: "string"),
                    "container": .init(type: "string", description: "Backup container name")
                ],
                required: ["volume_id"]
            ),
            listFilters: ["name", "status", "volume_id"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["available", "error"]
        ),

        // MARK: - quota (volume)

        ResourceDescriptor(
            name: "volume_quota",
            service: .blockStorage,
            verbs: [.get, .update],
            updateSchema: .init(
                type: "object",
                properties: [
                    "volumes": .init(type: "integer"),
                    "gigabytes": .init(type: "integer"),
                    "snapshots": .init(type: "integer"),
                    "backups": .init(type: "integer"),
                    "backup_gigabytes": .init(type: "integer")
                ]
            ),
            idField: "id",
            nameField: nil
        ),
    ]
}
