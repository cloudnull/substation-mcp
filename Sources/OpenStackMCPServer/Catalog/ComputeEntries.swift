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
                ActionSpec(name: "provisioning_status", params: [ParamSpec(name: "lines", type: "integer", description: "Serial console lines to scan (default 500)")]),
                ActionSpec(name: "console_url", params: [ParamSpec(name: "type", enumValues: ["vnc", "spice", "rdp"], description: "Console type")]),
                ActionSpec(name: "add_security_group", params: [ParamSpec(name: "name", required: true, description: "Security group name")]),
                ActionSpec(name: "remove_security_group", params: [ParamSpec(name: "name", required: true, description: "Security group name")]),
                ActionSpec(name: "evacuate", destructive: true, adminOnly: true, params: [
                    ParamSpec(name: "on_shared_storage", type: "boolean", description: "Whether the instance's root disk is on shared storage. Nova 400s a null value; omit to let Nova infer. false = copy the disk (block evacuation)."),
                    ParamSpec(name: "host", description: "Target hypervisor hostname. Omit = Nova scheduler picks."),
                ]),
                ActionSpec(name: "live_migrate", destructive: true, adminOnly: true, params: [
                    ParamSpec(name: "host", description: "Target hypervisor hostname. Omit/null = Nova scheduler picks (placement decides)."),
                    ParamSpec(name: "block_migration", type: "boolean", description: "true: copy local disks during the live migration (needed when the instance has local/ephemeral disks and the target lacks shared storage)."),
                    ParamSpec(name: "disk_over_commit", type: "boolean", description: "true: allow over-committing disk on the target during block live-migration. Set explicitly alongside block_migration."),
                ]),
                ActionSpec(name: "migrate", destructive: true, adminOnly: true, params: [
                    ParamSpec(name: "host", description: "Target hypervisor hostname. Omit/null = Nova scheduler picks."),
                    ParamSpec(name: "block_migration", type: "boolean", description: "true: COLD BLOCK migration — copy local/ephemeral disks to the target (the path for instances with ephemeral root disks). Pair with disk_over_commit=false to refuse over-commit."),
                    ParamSpec(name: "disk_over_commit", type: "boolean", description: "true: allow target disk over-commit during block cold-migration. Set explicitly alongside block_migration."),
                ]),
            ],
            links: [
                LinkSpec(
                    kind: "volume",
                    source: .init(resource: "server"),
                    target: .init(resource: "volume"),
                    params: [
                        ParamSpec(name: "device", description: "Requested device name (e.g. /dev/vdb). ADVISORY — KVM hypervisors frequently assign a different slot; the attach response reports the actual assigned device."),
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
                    "networks": .init(
                        type: "array",
                        items: .init(
                            type: "object",
                            properties: [
                                "network": .init(type: "string", description: "Network ID or name to attach"),
                                "port": .init(type: "string", description: "Existing port ID to attach (alternative to network)"),
                                "fixed_ip": .init(type: "string", description: "Specific fixed IP to request on the network")
                            ],
                            required: ["network"],
                            description: "One entry per network. Use `network` (ID or name); `port` attaches an existing port; `fixed_ip` pins an address.",
                            additionalProperties: false
                        ),
                        description: "Networks to attach. REQUIRED for server creation on Rackspace. The server must be attached to a PRIVATE network (not PUBLICNET) that has: (1) a subnet with DHCP enabled, and (2) a router connected to both the private subnet AND an external network (PUBLICNET) via a router interface + gateway. If no private network exists in the project, you MUST create one first: os_create(network) → os_create(subnet with CIDR e.g. 192.168.0.0/24) → os_create(router with external_gateway_info pointing to PUBLICNET) → os_attach(link:router_interface, source=router, target=subnet). Only then can you create the server on that private network."
                    ),
                    "key_name": .init(type: "string", description: "Keypair name"),
                    "user_data": .init(type: "string", description: "Base64-encoded user data. Mutually exclusive with `provisioning`."),
                    "provisioning": .init(
                        type: "object",
                        properties: [
                            "packages": .init(type: "array", items: .init(type: "string"), description: "Package names to install (resolved per-distro: apt or dnf)"),
                            "services": .init(type: "array", items: .init(type: "string"), description: "Systemd unit names to enable and start"),
                            "users": .init(
                                type: "array",
                                items: .init(
                                    type: "object",
                                    properties: [
                                        "name": .init(type: "string", description: "Login name"),
                                        "shell": .init(type: "string", description: "Login shell (default /bin/bash)"),
                                        "sudo": .init(type: "boolean", description: "Grant passwordless sudo (adds to sudo/wheel groups)")
                                    ],
                                    required: ["name"]
                                ),
                                description: "Additional users to create via cloud-init (primary login is handled by key_name)"
                            ),
                            "firewall": .init(
                                type: "array",
                                items: .init(
                                    type: "object",
                                    properties: [
                                        "proto": .init(type: "string", description: "Protocol: tcp or udp"),
                                        "port": .init(type: "integer", description: "Port number")
                                    ],
                                    required: ["proto", "port"]
                                ),
                                description: "Ports to open (ufw on apt distros, firewalld on yum distros)"
                            ),
                            "extra_runcmd": .init(type: "array", items: .init(type: "string"), description: "Escape-hatch shell lines appended to runcmd (each runs via sh -c, rc is tracked). Use for anything the primitives don't cover — e.g. enabling a repo (dnf install -y epel-release), applying security patches (dnf upgrade --security -y), or installing packages that live outside the base repos."),
                            "final_message": .init(type: "string", description: "Message written to /etc/motd.d/99-osmcp, visible at login")
                        ],
                        description: "Distro-aware provisioning block delivered as cloud-init user_data at boot. This is the mechanism for patching the OS and installing/configuring software (container runtimes, agents, etc.) on a fresh server: `packages` installs from the distro's default repos, `extra_runcmd` handles repo setup and patching. Boot-time results are verified via the serial console (check with os_action(server, provisioning_status)). Secret-safe: no passwords or key material."
                    ),
                    "availability_zone": .init(type: "string", description: "Availability zone"),
                    "metadata": .init(type: "object", description: "Key-value metadata", additionalProperties: false),
                    "security_groups": .init(type: "array", items: .init(type: "string"), description: "Security group names. If omitted, a per-server security group is auto-created with SSH (port 22)."),
                    "config_drive": .init(type: "string", description: "config_drive setting"),
                    "volumes": .init(
                        type: "array",
                        items: .init(
                            type: "object",
                            properties: [
                                "boot": .init(type: "boolean", description: "Set true for the root/boot volume. Nova creates a NEW volume from the server's image at creation time (block_device_mapping_v2 source_type=image, destination_type=volume). The server boots from this new volume as /dev/vda. Only one entry may have boot=true."),
                                "size": .init(type: "integer", description: "Root volume size in GB (boot entries only). Defaults to 40. Must be >= flavor disk size."),
                                "volume_type": .init(type: "string", description: "Volume type for the boot volume (e.g. 'HA-Performance', 'Performance', 'Standard'). Defaults to 'HA-Performance'."),
                                "volume_id": .init(type: "string", description: "Pre-created volume ID (data entries only). The volume must exist and be in 'available' state."),
                                "device": .init(type: "string", description: "Target device for data volumes (e.g. /dev/vdb, /dev/vdc). Ignored for boot volumes."),
                                "delete_on_termination": .init(type: "boolean", description: "Delete volume when server is terminated. Defaults to true for boot volumes.")
                            ],
                            additionalProperties: false
                        ),
                        description: "Volumes for the server. An entry with boot=true tells Nova to create a new root volume from the image (BDM v2: source_type=image, destination_type=volume) — no pre-created volume needed; specify size and volume_type instead. Entries without boot are pre-existing data volumes attached post-boot at the specified device (require volume_id)."
                    )
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
            defaultListFields: ["id", "name", "status", "flavor", "addresses", "created",
                                "task_state", "volumes_attached"],
            destructiveHints: ["stop", "reboot", "shelve", "rescue", "resize", "rebuild", "evacuate", "live_migrate", "migrate"],
            phase1Note: "Evacuation classification without OS-EXT-SRV-ATTR (2.1-pinned clouds like Rackspace; live-validated IAD3: OS-EXT-SRV-ATTR:* never emitted): root on volume when volumes_attached non-empty; local root when flavor.disk > 0 and volumes_attached empty; ephemeral local disk when flavor.ephemeral > 0 (needs cold BLOCK migrate); swap when flavor.swap > 0 (travels with block migration). Migration completion: status ACTIVE alone is NOT proof — poll task_state back to null, then confirm the instance left the source host via os_action(hypervisor, servers). os_get(server) returns all extended fields (task_state, power_state, vm_state, volumes_attached, srv_attr_host, srv_attr_hypervisor, srv_attr_root_device, srv_attr_availability_zone) when the cloud emits them.",
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
            // Only list is implemented (ComputeService.listServerGroups). get/create/delete have no
            // handlers yet; advertising them would let dry_run promise verbs that hard-400.
            verbs: [.list],
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

        // Admin surface (validated live on SAT0, 2026-10-18):
        //   GET  /os-hypervisors/detail            list (full capacity detail)
        //   GET  /os-hypervisors/{id}              get (id or hypervisor_hostname)
        //   GET  /os-hypervisors/statistics        action "statistics" (fleet totals)
        //   GET  /os-hypervisors/{id}/servers      action "servers" (instances on host)
        //   PUT  /os-hypervisors/{name}/state      action "set_state" (mv 2.53;
        //       fencing: enabled=false stops NEW placements, running VMs stay —
        //       the first step of a controlled evacuation; shape validated live
        //       on IAD3: unknown host 404, member token 403 policy)
        // Requires a project-scoped admin token: domain-scoped tokens lack
        // nova policy target_project match and get 403.
        ResourceDescriptor(
            name: "hypervisor",
            service: .compute,
            verbs: [.list, .get],
            actions: [
                ActionSpec(name: "statistics", adminOnly: true, params: []),
                ActionSpec(name: "servers", adminOnly: true, params: []),
                ActionSpec(name: "set_state", destructive: true, adminOnly: true, params: [
                    ParamSpec(name: "enabled", type: "boolean", required: true, description: "false fences the host: no NEW instances are scheduled to it (running VMs are untouched). true re-enables placement. First step of a controlled evacuation."),
                ]),
            ],
            listFilters: ["hypervisor_hostname", "with_servers"],
            idField: "id",
            nameField: "hypervisor_hostname",
            defaultListFields: ["id", "hypervisor_hostname", "state", "status", "vcpus", "vcpus_used",
                                "memory_mb", "memory_mb_used", "local_gb", "local_gb_used", "running_vms"]
        ),

        // MARK: - compute_service

        // Admin surface (validated live on SAT0, 2026-10-18):
        //   GET  /os-services                       list (binary/host filters)
        //   PUT  /os-services/disable {host,binary} action "disable"  (mv 2.1-2.52)
        //   PUT  /os-services/enable  {host,binary} action "enable"   (mv 2.1-2.52)
        //   PUT  /os-services/force-down {host,binary,forced_down}
        //       action "force_down" — only nova-compute services are updatable.
        // `id_or_name` is the host name; `binary` (default nova-compute) is an
        // action param. The mv 2.53 PUT /os-services/{uuid} {status,...} form
        // exists too but the legacy form works across all microversions.
        ResourceDescriptor(
            name: "compute_service",
            service: .compute,
            verbs: [.list],
            actions: [
                ActionSpec(name: "enable", adminOnly: true, params: [
                    ParamSpec(name: "binary", description: "Service binary (default nova-compute)"),
                ]),
                ActionSpec(name: "disable", destructive: true, adminOnly: true, params: [
                    ParamSpec(name: "binary", description: "Service binary (default nova-compute)"),
                    ParamSpec(name: "reason", description: "Why the service is being disabled"),
                ]),
                ActionSpec(name: "force_down", destructive: true, adminOnly: true, params: [
                    ParamSpec(name: "binary", description: "Service binary (default nova-compute)"),
                    ParamSpec(name: "forced_down", type: "boolean", description: "true (default) marks the host down before it reports; false clears the flag (nova refuses when evacuations are pending)"),
                ]),
            ],
            listFilters: ["binary", "host"],
            idField: "host",
            nameField: "host",
            statusField: "status",
            defaultListFields: ["id", "host", "binary", "zone", "status", "state", "disabled_reason", "updated_at"]
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
