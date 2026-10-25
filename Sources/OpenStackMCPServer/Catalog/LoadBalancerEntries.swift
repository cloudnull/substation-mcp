import Foundation

/// Octavia (load balancer) resource entries. 5 resources per spec (phase 2):
/// load_balancer (pollable), listener, pool, member, health_monitor.
enum LoadBalancerEntries {
    static let all: [ResourceDescriptor] = [
        ResourceDescriptor(
            name: "load_balancer",
            service: .loadBalancer,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Load balancer name"),
                    "vip_subnet_id": .init(type: "string", description: "VIP subnet id"),
                    "vip_address": .init(type: "string", description: "VIP address"),
                    "description": .init(type: "string", description: "Description"),
                    "flavor_id": .init(type: "string", description: "Flavor id"),
                ],
                required: []
            ),
            updateSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Load balancer name"),
                    "description": .init(type: "string", description: "Description"),
                ]
            ),
            listFilters: ["name", "status", "provisioning_status", "vip_address"],
            idField: "id",
            nameField: "name",
            statusField: "provisioning_status",
            terminalStates: ["ACTIVE", "DEGRADED", "ERROR"],
            defaultListFields: ["id", "name", "status", "provisioning_status", "vip_address", "created_at"]
        ),
        ResourceDescriptor(
            name: "listener",
            service: .loadBalancer,
            verbs: [.list, .get, .create, .update, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Listener name"),
                    "protocol": .init(type: "string", enumValues: ["HTTP", "HTTPS", "TCP", "TLS"], description: "Protocol"),
                    "protocol_port": .init(type: "integer", description: "Port"),
                    "load_balancer_id": .init(type: "string", description: "Load balancer id"),
                    "connection_limit": .init(type: "integer", description: "Max connections"),
                    "default_pool_id": .init(type: "string", description: "Default pool id (binds a pool to this listener)"),
                ],
                required: ["protocol", "protocol_port"]
            ),
            updateSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Listener name"),
                    "connection_limit": .init(type: "integer", description: "Max connections"),
                    "default_pool_id": .init(type: "string", description: "Default pool id; null unbinds the default pool", allowsNull: true),
                ]
            ),
            listFilters: ["name", "protocol", "protocol_port", "load_balancer_id"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "protocol", "protocol_port", "load_balancer_id", "default_pool_id"]
        ),
        ResourceDescriptor(
            name: "pool",
            service: .loadBalancer,
            verbs: [.list, .get, .create, .update, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Pool name"),
                    "protocol": .init(type: "string", enumValues: ["HTTP", "HTTPS", "TCP"], description: "Protocol"),
                    "lb_algorithm": .init(type: "string", enumValues: ["ROUND_ROBIN", "LEAST_CONNECTIONS", "SOURCE_IP"], description: "Load-balancing algorithm"),
                    "load_balancer_id": .init(type: "string", description: "Load balancer id (required unless listener_id is given)"),
                    "listener_id": .init(type: "string", description: "Listener id; makes this pool the listener's default pool"),
                    "health_monitor_id": .init(type: "string", description: "Health monitor id"),
                ],
                required: ["protocol"]
            ),
            updateSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Pool name"),
                    "description": .init(type: "string", description: "Description"),
                    "lb_algorithm": .init(type: "string", enumValues: ["ROUND_ROBIN", "LEAST_CONNECTIONS", "SOURCE_IP"], description: "Load-balancing algorithm"),
                ]
            ),
            listFilters: ["name", "protocol", "load_balancer_id"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "protocol", "lb_algorithm", "load_balancer_id", "listener_id"]
        ),
        ResourceDescriptor(
            name: "member",
            service: .loadBalancer,
            verbs: [.list, .get, .create, .update, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Member name"),
                    "address": .init(type: "string", description: "Member IP address (Octavia attribute `address`)"),
                    "protocol_port": .init(type: "integer", description: "Port on the member"),
                    "subnet_id": .init(type: "string", description: "Subnet containing the member address"),
                    "weight": .init(type: "integer", description: "Weight"),
                    "admin_state_up": .init(type: "boolean", description: "Admin state"),
                    "pool_id": .init(type: "string", description: "Pool id (required; the parent pool)"),
                ],
                required: ["pool_id", "address", "protocol_port"]
            ),
            updateSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Member name"),
                    "weight": .init(type: "integer", description: "Weight"),
                    "admin_state_up": .init(type: "boolean", description: "Admin state"),
                ]
            ),
            listFilters: ["name", "pool_id", "address"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["ONLINE", "OFFLINE"],
            defaultListFields: ["id", "name", "address", "protocol_port", "pool_id", "weight", "status"]
        ),
        ResourceDescriptor(
            name: "health_monitor",
            service: .loadBalancer,
            verbs: [.list, .get, .create, .update, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Health monitor name"),
                    "type": .init(type: "string", enumValues: ["PING", "HTTP", "HTTPGET", "TCP"], description: "Monitor type"),
                    "delay": .init(type: "integer", description: "Delay in seconds"),
                    "timeout": .init(type: "integer", description: "Timeout in seconds"),
                    "max_retries": .init(type: "integer", description: "Max retries"),
                    "pool_id": .init(type: "string", description: "Pool id"),
                ],
                required: ["type"]
            ),
            updateSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Health monitor name"),
                    "delay": .init(type: "integer", description: "Delay in seconds"),
                    "timeout": .init(type: "integer", description: "Timeout in seconds"),
                    "max_retries": .init(type: "integer", description: "Max retries"),
                ]
            ),
            listFilters: ["name", "type", "pool_id"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "type", "delay", "timeout", "max_retries"]
        ),
    ]
}
