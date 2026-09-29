import Foundation

/// Compute (Nova) resource entries. 10 resources per spec §8.5.
enum ComputeEntries {
    static let all: [ResourceDescriptor] = [
        // MARK: - server

        ResourceDescriptor(
            name: "server",
            service: .compute,
            verbs: [.list, .get, .create, .update, .delete],
            actions: [
                ActionSpec(name: "start", destructive: false),
                ActionSpec(name: "stop", destructive: true),
                ActionSpec(name: "reboot", destructive: true, params: [ParamSpec(name: "type", enumValues: ["soft", "hard"], description: "Reboot type")]),
                ActionSpec(name: "pause"),
                ActionSpec(name: "unpause"),
                ActionSpec(name: "suspend"),
                ActionSpec(name: "resume"),
                ActionSpec(name: "lock"),
                ActionSpec(name: "unlock"),
                ActionSpec(name: "shelve", destructive: true),
                ActionSpec(name: "unshelve"),
                ActionSpec(name: "rescue", destructive: true),
                ActionSpec(name: "unrescue"),
                ActionSpec(name: "resize", destructive: true, params: [ParamSpec(name: "flavor", required: true, description: "Target flavor ID or name")]),
                ActionSpec(name: "confirm_resize"),
                ActionSpec(name: "revert_resize"),
                ActionSpec(name: "rebuild", destructive: true, params: [ParamSpec(name: "image", required: true, description: "Image ID or name"), ParamSpec(name: "admin_pass", description: "New admin password (never echoed)")]),
                ActionSpec(name: "snapshot", destructive: false, params: [ParamSpec(name: "name", required: true, description: "Snapshot image name")]),
                ActionSpec(name: "console_output", params: [ParamSpec(name: "lines", type: "integer", description: "Number of lines to return")]),
                ActionSpec(name: "console_url", params: [ParamSpec(name: "type", enumValues: ["vnc", "spice", "rdp"], description: "Console type")]),
                ActionSpec(name: "add_security_group", params: [ParamSpec(name: "name", required: true, description: "Security group name")]),
                ActionSpec(name: "remove_security_group", params: [ParamSpec(name: "name", required: true, description: "Security group name")]),
                ActionSpec(name: "evacuate", destructive: true, adminOnly: true),
                ActionSpec(name: "live_migrate", destructive: true, adminOnly: true),
                ActionSpec(name: "migrate", destructive: true, adminOnly: true),
            ],
            links: [
                LinkSpec(
                    kind: "volume",
                    source: .init(resource: "server"),
                    target: .init(resource: "volume"),
                    params: [
                        ParamSpec(name: "device", description: "Device name (e.g. vda)"),
                        ParamSpec(name: "delete_on_termination", type: "boolean", description: "Delete volume when server is deleted")
                    ],
                    preconditions: ["volume is available or multiattach type", "server is not building"]
                ),
                LinkSpec(
                    kind: "interface",
                    source: .init(resource: "server"),
                    target: .init(resource: "port"),
                    params: [
                        ParamSpec(name: "fixed_ip", description: "Fixed IP address"),
                        ParamSpec(name: "port_id", description: "Port ID"),
                        ParamSpec(name: "net_id", description: "Network ID")
                    ],
                    preconditions: ["port is unattached", "network reachable in region"]
                ),
                LinkSpec(
                    kind: "security_group",
                    source: .init(resource: "server"),
                    target: .init(resource: "security_group"),
                    preconditions: ["port security enabled"]
                ),
            ],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Server name"),
                    "flavor": .init(type: "string", description: "Flavor ID or name"),
                    "image": .init(type: "string", description: "Image ID or name"),
                    "networks": .init(type: "array", items: .init(type: "object", properties: ["network": .init(type: "string")]), description: "Networks to attach"),
                    "key_name": .init(type: "string", description: "Keypair name"),
                    "user_data": .init(type: "string", description: "Base64-encoded user data"),
                    "availability_zone": .init(type: "string", description: "Availability zone"),
                    "metadata": .init(type: "object", description: "Key-value metadata", additionalProperties: false),
                    "security_groups": .init(type: "array", items: .init(type: "string"), description: "Security group names"),
                    "config_drive": .init(type: "string", description: "config_drive setting")
                ],
                required: ["name", "flavor", "image"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string", description: "New name"),
                "description": .init(type: "string"),
                "metadata": .init(type: "object", description: "Metadata to merge"),
                "tags": .init(type: "array", items: .init(type: "string"), description: "Full replacement tag list")
            ]),
            listFilters: ["name", "status", "flavor", "image", "key_name", "user_id", "all_tenants", "metadata"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["ACTIVE", "SHUTOFF", "ERROR", "SHELVED_OFFLOADED"],
            defaultListFields: ["id", "name", "status", "flavor", "addresses", "created"],
            destructiveHints: ["stop", "reboot", "shelve", "rescue", "resize", "rebuild", "evacuate", "live_migrate", "migrate"]
        ),

        // MARK: - flavor

        ResourceDescriptor(
            name: "flavor",
            service: .compute,
            verbs: [.list, .get, .create, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Flavor name"),
                    "vcpus": .init(type: "integer", description: "Number of vCPUs"),
                    "ram": .init(type: "integer", description: "RAM in MB"),
                    "disk": .init(type: "integer", description: "Root disk in GB"),
                    "swap": .init(type: "integer", description: "Swap in MB"),
                    "ephemeral": .init(type: "integer", description: "Ephemeral disk in GB")
                ],
                required: ["name", "vcpus", "ram", "disk"]
            ),
            listFilters: ["name", "minRam", "minDisk", "minVcpus"],
            idField: "id",
            nameField: "name"
        ),

        // MARK: - keypair

        ResourceDescriptor(
            name: "keypair",
            service: .compute,
            verbs: [.list, .get, .create, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Keypair name"),
                    "public_key": .init(type: "string", description: "Public key (omit to generate)")
                ],
                required: ["name"]
            ),
            listFilters: ["name"],
            idField: "name",
            nameField: "name"
        ),

        // MARK: - server_group

        ResourceDescriptor(
            name: "server_group",
            service: .compute,
            verbs: [.list, .get, .create, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Group name"),
                    "policies": .init(type: "array", items: .init(type: "string", enumValues: [.string("soft-anti-affinity"), .string("soft-affinity")]), description: "Policies")
                ],
                required: ["name"]
            ),
            listFilters: ["name"],
            idField: "id",
            nameField: "name"
        ),

        // MARK: - availability_zone

        ResourceDescriptor(
            name: "availability_zone",
            service: .compute,
            verbs: [.list],
            idField: "zoneName",
            nameField: "zoneName",
            statusField: "state"
        ),

        // MARK: - hypervisor

        ResourceDescriptor(
            name: "hypervisor",
            service: .compute,
            verbs: [.list, .get],
            listFilters: ["hypervisor_hostname"],
            idField: "id",
            nameField: "hypervisor_hostname"
        ),

        // MARK: - compute_service

        ResourceDescriptor(
            name: "compute_service",
            service: .compute,
            verbs: [.list, .update],
            actions: [
                ActionSpec(name: "enable", adminOnly: true, params: [ParamSpec(name: "host", required: true)]),
                ActionSpec(name: "disable", destructive: true, adminOnly: true, params: [ParamSpec(name: "host", required: true), ParamSpec(name: "reason", description: "Disable reason")]),
            ],
            updateSchema: .init(type: "object", properties: [
                "disabled": .init(type: "boolean", description: "Enable/disable the service"),
                "reason": .init(type: "string", description: "Reason for disable")
            ]),
            listFilters: ["binary", "host"],
            idField: "id",
            nameField: "host",
            statusField: "disabled_reason"
        ),

        // MARK: - server_interface

        ResourceDescriptor(
            name: "server_interface",
            service: .compute,
            verbs: [.list],
            listFilters: ["server_id", "port_id"],
            idField: "id",
            nameField: nil
        ),

        // MARK: - server_volume_attachment

        ResourceDescriptor(
            name: "server_volume_attachment",
            service: .compute,
            verbs: [.list],
            listFilters: ["server_id", "volume_id"],
            idField: "id",
            nameField: nil
        ),

        // MARK: - quota (compute)

        ResourceDescriptor(
            name: "compute_quota",
            service: .compute,
            verbs: [.get, .update],
            updateSchema: .init(
                type: "object",
                properties: [
                    "cores": .init(type: "integer"),
                    "instances": .init(type: "integer"),
                    "ram": .init(type: "integer"),
                    "volumes": .init(type: "integer"),
                    "fixed_ips": .init(type: "integer"),
                    "floating_ips": .init(type: "integer"),
                    "injected_files": .init(type: "integer"),
                    "key_pairs": .init(type: "integer"),
                    "metadata_items": .init(type: "integer")
                ]
            ),
            idField: "id",
            nameField: nil
        ),
    ]
}
