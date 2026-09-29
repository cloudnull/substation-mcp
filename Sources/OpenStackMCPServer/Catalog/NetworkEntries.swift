import Foundation

/// Network (Neutron) resource entries. 9 resources per spec §8.5.
enum NetworkEntries {
    static let all: [ResourceDescriptor] = [
        // MARK: - network

        ResourceDescriptor(
            name: "network",
            service: .network,
            verbs: [.list, .get, .create, .update, .delete],
            links: [
                LinkSpec(
                    kind: "router_gateway",
                    source: .init(resource: "router"),
                    target: .init(resource: "network"),
                    params: [
                        ParamSpec(name: "enable_snat", type: "boolean", description: "Enable SNAT"),
                        ParamSpec(name: "external_fixed_ips", type: "array", description: "External fixed IPs")
                    ],
                    preconditions: ["network is router:external"]
                ),
            ],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Network name"),
                    "admin_state_up": .init(type: "boolean"),
                    "shared": .init(type: "boolean"),
                    "external": .init(type: "boolean", description: "Mark as external (router:external)"),
                    "provider_network_type": .init(type: "string", enumValues: ["flat", "vlan", "vxlan", "geneve"], description: "Provider network type"),
                    "provider_physical_network": .init(type: "string"),
                    "provider_segmentation_id": .init(type: "integer"),
                    "mtu": .init(type: "integer"),
                    "port_security_enabled": .init(type: "boolean")
                ],
                required: ["name"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "admin_state_up": .init(type: "boolean"),
                "shared": .init(type: "boolean"),
                "mtu": .init(type: "integer"),
                "port_security_enabled": .init(type: "boolean")
            ]),
            listFilters: ["name", "status", "admin_state_up", "shared", "external"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["ACTIVE"]
        ),

        // MARK: - subnet

        ResourceDescriptor(
            name: "subnet",
            service: .network,
            verbs: [.list, .get, .create, .update, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Subnet name"),
                    "network_id": .init(type: "string", description: "Network ID"),
                    "cidr": .init(type: "string", description: "CIDR (e.g. 192.168.1.0/24)"),
                    "gateway_ip": .init(type: "string", description: "Gateway IP (default: first usable IP)"),
                    "ip_version": .init(type: "integer", enumValues: [.integer(4), .integer(6)]),
                    "enable_dhcp": .init(type: "boolean"),
                    "dns_nameservers": .init(type: "array", items: .init(type: "string")),
                    "allocation_pools": .init(type: "array", items: .init(type: "object", properties: [
                        "start": .init(type: "string"),
                        "end": .init(type: "string")
                    ])),
                    "host_routes": .init(type: "array", items: .init(type: "object", properties: [
                        "destination": .init(type: "string"),
                        "next_hop": .init(type: "string")
                    ]))
                ],
                required: ["network_id", "cidr"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "dns_nameservers": .init(type: "array", items: .init(type: "string")),
                "host_routes": .init(type: "array")
            ]),
            listFilters: ["name", "network_id", "cidr", "ip_version", "gateway_ip"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["ACTIVE"]
        ),

        // MARK: - port

        ResourceDescriptor(
            name: "port",
            service: .network,
            verbs: [.list, .get, .create, .update, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Port name"),
                    "network_id": .init(type: "string", description: "Network ID"),
                    "admin_state_up": .init(type: "boolean"),
                    "mac_address": .init(type: "string"),
                    "fixed_ips": .init(type: "array", items: .init(type: "object", properties: [
                        "ip_address": .init(type: "string"),
                        "subnet_id": .init(type: "string")
                    ])),
                    "security_groups": .init(type: "array", items: .init(type: "string")),
                    "device_owner": .init(type: "string"),
                    "device_id": .init(type: "string"),
                    "port_security_enabled": .init(type: "boolean"),
                    "allowed_address_pairs": .init(type: "array", items: .init(type: "object"))
                ],
                required: ["network_id"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "admin_state_up": .init(type: "boolean"),
                "fixed_ips": .init(type: "array"),
                "security_groups": .init(type: "array", items: .init(type: "string")),
                "port_security_enabled": .init(type: "boolean"),
                "description": .init(type: "string")
            ]),
            listFilters: ["name", "network_id", "status", "device_id", "device_owner", "fixed_ips", "mac_address", "security_group_ids"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["ACTIVE"],
            defaultListFields: ["id", "name", "status", "network_id", "fixed_ips", "security_groups", "mac_address", "device_owner"]
        ),

        // MARK: - router

        ResourceDescriptor(
            name: "router",
            service: .network,
            verbs: [.list, .get, .create, .update, .delete],
            actions: [
                ActionSpec(name: "set_gateway", params: [
                    ParamSpec(name: "network", required: true, description: "External network ID or name"),
                    ParamSpec(name: "enable_snat", type: "boolean", description: "Enable SNAT")
                ]),
                ActionSpec(name: "clear_gateway", destructive: true),
            ],
            links: [
                LinkSpec(
                    kind: "router_interface",
                    source: .init(resource: "router"),
                    target: .init(resource: "subnet"),
                    preconditions: ["subnet has a gateway IP or port is free"]
                ),
                LinkSpec(
                    kind: "router_gateway",
                    source: .init(resource: "router"),
                    target: .init(resource: "network"),
                    params: [
                        ParamSpec(name: "enable_snat", type: "boolean"),
                        ParamSpec(name: "external_fixed_ips", type: "array")
                    ],
                    preconditions: ["network is router:external"]
                ),
            ],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Router name"),
                    "admin_state_up": .init(type: "boolean"),
                    "external_gateway_info": .init(type: "object", properties: [
                        "network_id": .init(type: "string", description: "External network ID"),
                        "enable_snat": .init(type: "boolean"),
                        "external_fixed_ips": .init(type: "array")
                    ]),
                    "routes": .init(type: "array", items: .init(type: "object", properties: [
                        "destination": .init(type: "string"),
                        "next_hop": .init(type: "string")
                    ]))
                ],
                required: ["name"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "admin_state_up": .init(type: "boolean"),
                "routes": .init(type: "array")
            ]),
            listFilters: ["name", "status", "external_gateway_info"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["ACTIVE", "DOWN"]
        ),

        // MARK: - floating_ip

        ResourceDescriptor(
            name: "floating_ip",
            service: .network,
            verbs: [.list, .get, .create, .delete],
            actions: [
                ActionSpec(name: "associate", params: [
                    ParamSpec(name: "port", description: "Port ID or name"),
                    ParamSpec(name: "fixed_ip", description: "Fixed IP address")
                ]),
                ActionSpec(name: "disassociate", destructive: true),
            ],
            links: [
                LinkSpec(
                    kind: "floating_ip",
                    source: .init(resource: "floating_ip"),
                    target: .init(resource: "port"),
                    params: [ParamSpec(name: "fixed_ip", description: "Fixed IP on the port")],
                    preconditions: ["port's subnet reachable from the floating IP's external network through a router"]
                ),
            ],
            createSchema: .init(
                type: "object",
                properties: [
                    "floating_network_id": .init(type: "string", description: "External network ID"),
                    "subnet_id": .init(type: "string", description: "Floating IP subnet ID"),
                    "port_id": .init(type: "string", description: "Port to associate with"),
                    "fixed_ip_address": .init(type: "string", description: "Fixed IP to associate with"),
                    "description": .init(type: "string")
                ]
            ),
            listFilters: ["name", "status", "floating_network_id", "floating_ip_address", "port_id", "fixed_ip_address"],
            idField: "id",
            nameField: nil,
            statusField: "status",
            terminalStates: ["ACTIVE", "DOWN"]
        ),

        // MARK: - security_group

        ResourceDescriptor(
            name: "security_group",
            service: .network,
            verbs: [.list, .get, .create, .update, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Security group name"),
                    "description": .init(type: "string")
                ],
                required: ["name"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "description": .init(type: "string")
            ]),
            listFilters: ["name", "description"],
            idField: "id",
            nameField: "name"
        ),

        // MARK: - security_group_rule

        ResourceDescriptor(
            name: "security_group_rule",
            service: .network,
            verbs: [.list, .get, .create, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "security_group_id": .init(type: "string", description: "Security group ID"),
                    "direction": .init(type: "string", enumValues: ["ingress", "egress"]),
                    "ethertype": .init(type: "string", enumValues: ["IPv4", "IPv6"]),
                    "protocol": .init(type: "string", description: "Protocol (tcp, udp, icmp, or number)"),
                    "port_range_min": .init(type: "integer"),
                    "port_range_max": .init(type: "integer"),
                    "remote_ip_prefix": .init(type: "string", description: "CIDR (e.g. 10.0.0.0/8)"),
                    "remote_group_id": .init(type: "string", description: "Remote security group ID"),
                    "remote_subnet_id": .init(type: "string", description: "Remote subnet ID"),
                    "description": .init(type: "string")
                ],
                required: ["security_group_id", "direction"]
            ),
            listFilters: ["security_group_id", "direction", "protocol", "port_range_min", "port_range_max", "remote_ip_prefix", "remote_group_id"],
            idField: "id",
            nameField: nil
        ),

        // MARK: - address_group

        ResourceDescriptor(
            name: "address_group",
            service: .network,
            verbs: [.list, .get, .create, .update, .delete],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Address group name"),
                    "description": .init(type: "string"),
                    "ip_addresses": .init(type: "array", items: .init(type: "string"), description: "IP addresses (CIDR or single IP)")
                ],
                required: ["name"]
            ),
            updateSchema: .init(type: "object", properties: [
                "name": .init(type: "string"),
                "description": .init(type: "string"),
                "ip_addresses": .init(type: "array", items: .init(type: "string"))
            ]),
            listFilters: ["name"],
            idField: "id",
            nameField: "name"
        ),

        // MARK: - quota (network)

        ResourceDescriptor(
            name: "network_quota",
            service: .network,
            verbs: [.get, .update],
            updateSchema: .init(
                type: "object",
                properties: [
                    "network": .init(type: "integer"),
                    "subnet": .init(type: "integer"),
                    "port": .init(type: "integer"),
                    "security_group": .init(type: "integer"),
                    "security_group_rule": .init(type: "integer"),
                    "floating_ip": .init(type: "integer"),
                    "router": .init(type: "integer"),
                    "fip_per_port": .init(type: "integer")
                ]
            ),
            idField: "id",
            nameField: nil
        ),
    ]
}
