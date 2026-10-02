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
            updateSchema: nil,
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
            verbs: [.list, .get, .create, .delete],
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
                ],
                required: ["protocol", "protocol_port"]
            ),
            updateSchema: nil,
            listFilters: ["name", "protocol", "protocol_port", "load_balancer_id"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "protocol", "protocol_port", "load_balancer_id"]
        ),
        ResourceDescriptor(
            name: "pool",
            service: .loadBalancer,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Pool name"),
                    "protocol": .init(type: "string", enumValues: ["HTTP", "HTTPS", "TCP"], description: "Protocol"),
                    "lb_algorithm": .init(type: "string", enumValues: ["ROUND_ROBIN", "LEAST_CONNECTIONS", "SOURCE_IP"], description: "Load-balancing algorithm"),
                    "load_balancer_id": .init(type: "string", description: "Load balancer id"),
                    "health_monitor_id": .init(type: "string", description: "Health monitor id"),
                ],
                required: ["protocol"]
            ),
            updateSchema: nil,
            listFilters: ["name", "protocol", "load_balancer_id"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "protocol", "lb_algorithm", "load_balancer_id"]
        ),
        ResourceDescriptor(
            name: "member",
            service: .loadBalancer,
            verbs: [.list, .get, .create, .delete],
            actions: [],
            links: [],
            createSchema: .init(
                type: "object",
                properties: [
                    "name": .init(type: "string", description: "Member name"),
                    "protocol_address": .init(type: "string", description: "Member address"),
                    "protocol_port": .init(type: "integer", description: "Port"),
                    "weight": .init(type: "integer", description: "Weight"),
                    "admin_state_up": .init(type: "boolean", description: "Admin state"),
                    "pool_id": .init(type: "string", description: "Pool id"),
                ],
                required: ["protocol_address", "protocol_port"]
            ),
            updateSchema: nil,
            listFilters: ["name", "pool_id", "protocol_address"],
            idField: "id",
            nameField: "name",
            statusField: "status",
            terminalStates: ["ONLINE", "OFFLINE"],
            defaultListFields: ["id", "name", "protocol_address", "protocol_port", "pool_id", "status"]
        ),
        ResourceDescriptor(
            name: "health_monitor",
            service: .loadBalancer,
            verbs: [.list, .get, .create, .delete],
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
            updateSchema: nil,
            listFilters: ["name", "type", "pool_id"],
            idField: "id",
            nameField: "name",
            statusField: nil,
            terminalStates: [],
            defaultListFields: ["id", "name", "type", "delay", "timeout", "max_retries"]
        ),
    ]
}
