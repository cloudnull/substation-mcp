import Foundation

// MARK: - Octavia (load balancer) models — phase 2
//
// Keystone service type: `loadbalancer`. API base path: `loadbalancer/v1`
// (Octavia's API version root is `/v1/<project>`; the fake uses the project-
// scoped path). Resources: load_balancer (pollable — provisioning ->
// active), listener, pool, member, health_monitor.

public struct LoadBalancer: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var status: String
    public var provisioning_status: String
    public var vip_address: String?
    public var flavor_id: String?
    public var description: String?
    public var created_at: String?

    public init(
        id: String,
        name: String? = nil,
        status: String = "ACTIVE",
        provisioning_status: String = "ACTIVE",
        vip_address: String? = nil,
        flavor_id: String? = nil,
        description: String? = nil,
        created_at: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.provisioning_status = provisioning_status
        self.vip_address = vip_address
        self.flavor_id = flavor_id
        self.description = description
        self.created_at = created_at
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case provisioning_status
        case vip_address
        case flavor_id
        case description, created_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "ACTIVE"
        provisioning_status = try c.decodeIfPresent(String.self, forKey: .provisioning_status) ?? "ACTIVE"
        vip_address = try c.decodeIfPresent(String.self, forKey: .vip_address)
        flavor_id = try c.decodeIfPresent(String.self, forKey: .flavor_id)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(provisioning_status, forKey: .provisioning_status)
        try c.encodeIfPresent(vip_address, forKey: .vip_address)
        try c.encodeIfPresent(flavor_id, forKey: .flavor_id)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(created_at, forKey: .created_at)
    }
}

public struct Listener: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var protocolName: String
    public var protocol_port: Int
    public var load_balancer_id: String?
    public var connection_limit: Int?
    public var default_pool_id: String?

    public init(
        id: String,
        name: String? = nil,
        protocolName: String = "HTTP",
        protocol_port: Int = 80,
        load_balancer_id: String? = nil,
        connection_limit: Int? = nil,
        default_pool_id: String? = nil
    ) {
        self.id = id
        self.name = name
        self.protocolName = protocolName
        self.protocol_port = protocol_port
        self.load_balancer_id = load_balancer_id
        self.connection_limit = connection_limit
        self.default_pool_id = default_pool_id
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case `protocol` = "protocol"
        case protocol_port
        case load_balancer_id = "loadbalancer_id"
        case connection_limit
        case default_pool_id = "default_pool_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        protocolName = try c.decode(String.self, forKey: .protocol)
        protocol_port = try c.decode(Int.self, forKey: .protocol_port)
        load_balancer_id = try c.decodeIfPresent(String.self, forKey: .load_balancer_id)
        connection_limit = try c.decodeIfPresent(Int.self, forKey: .connection_limit)
        default_pool_id = try c.decodeIfPresent(String.self, forKey: .default_pool_id)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(protocolName, forKey: .protocol)
        try c.encode(protocol_port, forKey: .protocol_port)
        try c.encodeIfPresent(load_balancer_id, forKey: .load_balancer_id)
        try c.encodeIfPresent(connection_limit, forKey: .connection_limit)
        try c.encodeIfPresent(default_pool_id, forKey: .default_pool_id)
    }
}

public struct Pool: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var protocolName: String
    public var lb_algorithm: String
    public var load_balancer_id: String?
    public var health_monitor_id: String?

    public init(
        id: String,
        name: String? = nil,
        protocolName: String = "HTTP",
        lb_algorithm: String = "ROUND_ROBIN",
        load_balancer_id: String? = nil,
        health_monitor_id: String? = nil
    ) {
        self.id = id
        self.name = name
        self.protocolName = protocolName
        self.lb_algorithm = lb_algorithm
        self.load_balancer_id = load_balancer_id
        self.health_monitor_id = health_monitor_id
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case `protocol` = "protocol"
        case lb_algorithm
        case load_balancer_id = "loadbalancer_id"
        case health_monitor_id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        protocolName = try c.decode(String.self, forKey: .protocol)
        lb_algorithm = try c.decode(String.self, forKey: .lb_algorithm)
        load_balancer_id = try c.decodeIfPresent(String.self, forKey: .load_balancer_id)
        health_monitor_id = try c.decodeIfPresent(String.self, forKey: .health_monitor_id)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(protocolName, forKey: .protocol)
        try c.encode(lb_algorithm, forKey: .lb_algorithm)
        try c.encodeIfPresent(load_balancer_id, forKey: .load_balancer_id)
        try c.encodeIfPresent(health_monitor_id, forKey: .health_monitor_id)
    }
}

public struct Member: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var protocol_address: String
    public var protocol_port: Int
    public var weight: Int?
    public var admin_state_up: Bool?
    public var pool_id: String?
    public var status: String?

    public init(
        id: String,
        name: String? = nil,
        protocol_address: String,
        protocol_port: Int,
        weight: Int? = 1,
        admin_state_up: Bool? = true,
        pool_id: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.name = name
        self.protocol_address = protocol_address
        self.protocol_port = protocol_port
        self.weight = weight
        self.admin_state_up = admin_state_up
        self.pool_id = pool_id
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case protocol_address, protocol_port
        case weight
        case admin_state_up
        case pool_id, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        protocol_address = try c.decode(String.self, forKey: .protocol_address)
        protocol_port = try c.decode(Int.self, forKey: .protocol_port)
        weight = try c.decodeIfPresent(Int.self, forKey: .weight)
        admin_state_up = try c.decodeIfPresent(Bool.self, forKey: .admin_state_up)
        pool_id = try c.decodeIfPresent(String.self, forKey: .pool_id)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(protocol_address, forKey: .protocol_address)
        try c.encode(protocol_port, forKey: .protocol_port)
        try c.encodeIfPresent(weight, forKey: .weight)
        try c.encodeIfPresent(admin_state_up, forKey: .admin_state_up)
        try c.encodeIfPresent(pool_id, forKey: .pool_id)
        try c.encodeIfPresent(status, forKey: .status)
    }
}

public struct HealthMonitor: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var type: String
    public var delay: Int?
    public var timeout: Int?
    public var max_retries: Int?
    public var pool_id: String?

    public init(
        id: String,
        name: String? = nil,
        type: String = "PING",
        delay: Int? = 10,
        timeout: Int? = 5,
        max_retries: Int? = 3,
        pool_id: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.delay = delay
        self.timeout = timeout
        self.max_retries = max_retries
        self.pool_id = pool_id
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case delay, timeout
        case max_retries
        case pool_id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        delay = try c.decodeIfPresent(Int.self, forKey: .delay)
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
        max_retries = try c.decodeIfPresent(Int.self, forKey: .max_retries)
        pool_id = try c.decodeIfPresent(String.self, forKey: .pool_id)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(delay, forKey: .delay)
        try c.encodeIfPresent(timeout, forKey: .timeout)
        try c.encodeIfPresent(max_retries, forKey: .max_retries)
        try c.encodeIfPresent(pool_id, forKey: .pool_id)
    }
}

/// Spec for creating a load balancer. Requires a VIP subnet id + IP.
public struct CreateLoadBalancerSpec: Sendable {
    public var name: String?
    public var vip_subnet_id: String?
    public var vip_address: String?
    public var description: String?
    public var flavor_id: String?

    public init(name: String? = nil, vip_subnet_id: String? = nil, vip_address: String? = nil, description: String? = nil, flavor_id: String? = nil) {
        self.name = name
        self.vip_subnet_id = vip_subnet_id
        self.vip_address = vip_address
        self.description = description
        self.flavor_id = flavor_id
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let s = vip_subnet_id { parts.append("\"vip_subnet_id\":\"\(s)\"") }
        if let a = vip_address { parts.append("\"vip_address\":\"\(a)\"") }
        if let d = description { parts.append("\"description\":\"\(d)\"") }
        if let f = flavor_id { parts.append("\"flavor_id\":\"\(f)\"") }
        return "{\"loadbalancer\":{" + parts.joined(separator: ",") + "}}"
    }
}

public struct CreateListenerSpec: Sendable {
    public var name: String?
    public var _protocolName: String
    public var protocol_port: Int
    public var load_balancer_id: String?
    public var connection_limit: Int?

    public init(name: String? = nil, protocolName: String = "HTTP", protocol_port: Int = 80, load_balancer_id: String? = nil, connection_limit: Int? = nil) {
        self.name = name
        self._protocolName = protocolName
        self.protocol_port = protocol_port
        self.load_balancer_id = load_balancer_id
        self.connection_limit = connection_limit
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        parts.append("\"protocol\":\"\(_protocolName)\"")
        parts.append("\"protocol_port\":\(protocol_port)")
        if let lb = load_balancer_id { parts.append("\"loadbalancer_id\":\"\(lb)\"") }
        if let cl = connection_limit { parts.append("\"connection_limit\":\(cl)") }
        return "{\"listener\":{" + parts.joined(separator: ",") + "}}"
    }
}

public struct CreatePoolSpec: Sendable {
    public var name: String?
    public var _protocolName: String
    public var lb_algorithm: String
    public var load_balancer_id: String?
    public var health_monitor_id: String?

    public init(name: String? = nil, protocolName: String = "HTTP", lb_algorithm: String = "ROUND_ROBIN", load_balancer_id: String? = nil, health_monitor_id: String? = nil) {
        self.name = name
        self._protocolName = protocolName
        self.lb_algorithm = lb_algorithm
        self.load_balancer_id = load_balancer_id
        self.health_monitor_id = health_monitor_id
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        parts.append("\"protocol\":\"\(_protocolName)\"")
        parts.append("\"lb_algorithm\":\"\(lb_algorithm)\"")
        if let lb = load_balancer_id { parts.append("\"loadbalancer_id\":\"\(lb)\"") }
        if let hm = health_monitor_id { parts.append("\"health_monitor_id\":\"\(hm)\"") }
        return "{\"pool\":{" + parts.joined(separator: ",") + "}}"
    }
}

public struct CreateMemberSpec: Sendable {
    public var name: String?
    public var protocol_address: String
    public var protocol_port: Int
    public var weight: Int?
    public var admin_state_up: Bool?
    public var pool_id: String?

    public init(name: String? = nil, protocol_address: String, protocol_port: Int, weight: Int? = 1, admin_state_up: Bool? = true, pool_id: String? = nil) {
        self.name = name
        self.protocol_address = protocol_address
        self.protocol_port = protocol_port
        self.weight = weight
        self.admin_state_up = admin_state_up
        self.pool_id = pool_id
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        parts.append("\"protocol_address\":\"\(protocol_address)\"")
        parts.append("\"protocol_port\":\(protocol_port)")
        if let w = weight { parts.append("\"weight\":\(w)") }
        if let up = admin_state_up { parts.append("\"admin_state_up\":\(up)") }
        if let p = pool_id { parts.append("\"pool_id\":\"\(p)\"") }
        return "{\"member\":{" + parts.joined(separator: ",") + "}}"
    }
}

public struct CreateHealthMonitorSpec: Sendable {
    public var name: String?
    public var type: String
    public var delay: Int?
    public var timeout: Int?
    public var max_retries: Int?
    public var pool_id: String?

    public init(name: String? = nil, type: String = "PING", delay: Int? = 10, timeout: Int? = 5, max_retries: Int? = 3, pool_id: String? = nil) {
        self.name = name
        self.type = type
        self.delay = delay
        self.timeout = timeout
        self.max_retries = max_retries
        self.pool_id = pool_id
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        parts.append("\"type\":\"\(type)\"")
        if let d = delay { parts.append("\"delay\":\(d)") }
        if let t = timeout { parts.append("\"timeout\":\(t)") }
        if let mr = max_retries { parts.append("\"max_retries\":\(mr)") }
        if let p = pool_id { parts.append("\"pool_id\":\"\(p)\"") }
        return "{\"health_monitor\":{" + parts.joined(separator: ",") + "}}"
    }
}
