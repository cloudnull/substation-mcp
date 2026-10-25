import Foundation

// MARK: - Octavia (load balancer) models — phase 2
//
// Keystone service type: `load-balancer`. API root: `<endpoint>/v2/lbaas/...`
// (the endpoint advertised in the token catalog already carries the service
// prefix, e.g. `…/loadbalancer`; `loadbalancer/v2` is the single-endpoint/fake
// layout). Resources: load_balancer (pollable — provisioning -> ACTIVE),
// listener, pool, member (a pool sub-resource), health_monitor.
//
// Field names below are the WIRE names from the upstream api-ref
// (https://docs.openstack.org/api-ref/load-balancer/v2/index.html), not the
// Python DB model names. The two differ in three places that matter here:
//   listener/pool  → request `loadbalancer_id`, response `loadbalancers: [{id}]`
//   pool           → response `healthmonitor_id` (one word; the DB key is
//                    `health_monitor_id` and requests use `healthmonitor_id`)
//   member         → `address` (NOT `protocol_address`)
//

/// Load balancer (`/v2/lbaas/loadbalancers`).
public struct LoadBalancer: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var status: String
    public var provisioning_status: String
    public var vip_address: String?
    public var vip_subnet_id: String?
    public var flavor_id: String?
    public var description: String?
    public var created_at: String?

    public init(
        id: String,
        name: String? = nil,
        status: String = "ACTIVE",
        provisioning_status: String = "ACTIVE",
        vip_address: String? = nil,
        vip_subnet_id: String? = nil,
        flavor_id: String? = nil,
        description: String? = nil,
        created_at: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.provisioning_status = provisioning_status
        self.vip_address = vip_address
        self.vip_subnet_id = vip_subnet_id
        self.flavor_id = flavor_id
        self.description = description
        self.created_at = created_at
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case provisioning_status
        case vip_address
        case vip_subnet_id
        case flavor_id
        case description, created_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeOrZero(String.self, forKey: .id)
        name = try c.decodeLenient(String.self, forKey: .name)
        status = try c.decodeLenient(String.self, forKey: .status) ?? "ACTIVE"
        provisioning_status = try c.decodeLenient(String.self, forKey: .provisioning_status) ?? "ACTIVE"
        vip_address = try c.decodeLenient(String.self, forKey: .vip_address)
        vip_subnet_id = try c.decodeLenient(String.self, forKey: .vip_subnet_id)
        flavor_id = try c.decodeLenient(String.self, forKey: .flavor_id)
        description = try c.decodeLenient(String.self, forKey: .description)
        created_at = try c.decodeLenient(String.self, forKey: .created_at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(provisioning_status, forKey: .provisioning_status)
        try c.encodeIfPresent(vip_address, forKey: .vip_address)
        try c.encodeIfPresent(vip_subnet_id, forKey: .vip_subnet_id)
        try c.encodeIfPresent(flavor_id, forKey: .flavor_id)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(created_at, forKey: .created_at)
    }
}

/// PATCH body for `PUT /v2/lbaas/loadbalancers/{id}` (`LoadBalancerPUT`
/// accepts name/description).
public struct UpdateLoadBalancerSpec: Sendable {
    public var name: String?
    public var description: String?

    public init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }

    public var isEmpty: Bool { name == nil && description == nil }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let d = description { parts.append("\"description\":\"\(d)\"") }
        return "{\"loadbalancer\":{" + parts.joined(separator: ",") + "}}"
    }
}

/// Listener (`/v2/lbaas/listeners`).
///
/// The parent load balancer arrives as `loadbalancers: [{id: …}]` (the api-ref
/// `loadbalancer-ids` response parameter) and is sent as `loadbalancer_id`, so
/// `load_balancer_id` is populated from either shape.
public struct Listener: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var protocolName: String
    public var protocol_port: Int
    public var load_balancer_id: String?
    public var connection_limit: Int?
    public var default_pool_id: String?
    public var provisioning_status: String?
    public var operating_status: String?

    public init(
        id: String,
        name: String? = nil,
        protocolName: String = "HTTP",
        protocol_port: Int = 80,
        load_balancer_id: String? = nil,
        connection_limit: Int? = nil,
        default_pool_id: String? = nil,
        provisioning_status: String? = nil,
        operating_status: String? = nil
    ) {
        self.id = id
        self.name = name
        self.protocolName = protocolName
        self.protocol_port = protocol_port
        self.load_balancer_id = load_balancer_id
        self.connection_limit = connection_limit
        self.default_pool_id = default_pool_id
        self.provisioning_status = provisioning_status
        self.operating_status = operating_status
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case `protocol` = "protocol"
        case protocol_port
        case loadbalancer_id
        case loadbalancers
        case connection_limit
        case default_pool_id
        case provisioning_status
        case operating_status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeOrZero(String.self, forKey: .id)
        name = try c.decodeLenient(String.self, forKey: .name)
        protocolName = try c.decodeOrZero(String.self, forKey: .protocol)
        protocol_port = (try? c.decodeLenient(Int.self, forKey: .protocol_port)) ?? 0
        load_balancer_id = try c.decodeLenient(String.self, forKey: .loadbalancer_id)
            ?? c.firstNestedID(from: .loadbalancers)
        connection_limit = try c.decodeLenient(Int.self, forKey: .connection_limit)
        default_pool_id = try c.decodeLenient(String.self, forKey: .default_pool_id)
        provisioning_status = try c.decodeLenient(String.self, forKey: .provisioning_status)
        operating_status = try c.decodeLenient(String.self, forKey: .operating_status)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(protocolName, forKey: .protocol)
        try c.encode(protocol_port, forKey: .protocol_port)
        try c.encodeIfPresent(load_balancer_id, forKey: .loadbalancer_id)
        try c.encodeIfPresent(connection_limit, forKey: .connection_limit)
        try c.encodeIfPresent(default_pool_id, forKey: .default_pool_id)
        try c.encodeIfPresent(provisioning_status, forKey: .provisioning_status)
        try c.encodeIfPresent(operating_status, forKey: .operating_status)
    }
}

/// Pool (`/v2/lbaas/pools`).
///
/// `listener_id` is accepted on create (the pool becomes that listener's
/// default pool) but is NOT accepted on update — `PoolPUT` has no such field —
/// so binding a pre-existing pool to a listener goes through
/// `PUT /v2/lbaas/listeners/{id}` with `default_pool_id`. The listener link
/// comes back as `listeners: [{id}]`.
public struct Pool: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var protocolName: String
    public var lb_algorithm: String
    public var load_balancer_id: String?
    public var health_monitor_id: String?
    public var listener_id: String?
    public var provisioning_status: String?
    public var operating_status: String?

    public init(
        id: String,
        name: String? = nil,
        protocolName: String = "HTTP",
        lb_algorithm: String = "ROUND_ROBIN",
        load_balancer_id: String? = nil,
        health_monitor_id: String? = nil,
        listener_id: String? = nil,
        provisioning_status: String? = nil,
        operating_status: String? = nil
    ) {
        self.id = id
        self.name = name
        self.protocolName = protocolName
        self.lb_algorithm = lb_algorithm
        self.load_balancer_id = load_balancer_id
        self.health_monitor_id = health_monitor_id
        self.listener_id = listener_id
        self.provisioning_status = provisioning_status
        self.operating_status = operating_status
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case `protocol` = "protocol"
        case lb_algorithm
        case loadbalancer_id
        case loadbalancers
        case healthmonitor_id
        case listener_id
        case listeners
        case provisioning_status
        case operating_status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeOrZero(String.self, forKey: .id)
        name = try c.decodeLenient(String.self, forKey: .name)
        protocolName = try c.decodeOrZero(String.self, forKey: .protocol)
        lb_algorithm = try c.decodeOrZero(String.self, forKey: .lb_algorithm)
        load_balancer_id = try c.decodeLenient(String.self, forKey: .loadbalancer_id)
            ?? c.firstNestedID(from: .loadbalancers)
        health_monitor_id = try c.decodeLenient(String.self, forKey: .healthmonitor_id)
        listener_id = try c.decodeLenient(String.self, forKey: .listener_id)
            ?? c.firstNestedID(from: .listeners)
        provisioning_status = try c.decodeLenient(String.self, forKey: .provisioning_status)
        operating_status = try c.decodeLenient(String.self, forKey: .operating_status)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(protocolName, forKey: .protocol)
        try c.encode(lb_algorithm, forKey: .lb_algorithm)
        try c.encodeIfPresent(load_balancer_id, forKey: .loadbalancer_id)
        try c.encodeIfPresent(health_monitor_id, forKey: .healthmonitor_id)
        try c.encodeIfPresent(listener_id, forKey: .listener_id)
        try c.encodeIfPresent(provisioning_status, forKey: .provisioning_status)
        try c.encodeIfPresent(operating_status, forKey: .operating_status)
    }
}

/// Pool member (`/v2/lbaas/pools/{pool_id}/members`).
///
/// The wire field is `address`; `protocol_address` does not exist in the
/// Octavia API (defect #7: the schema declared it, so the create sent a field
/// Octavia ignores and got a 400/405 back). `pool_id` is carried in the URL,
/// not the body, so it is surfaced here from the response when present.
public struct Member: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var address: String
    public var protocol_port: Int
    public var subnet_id: String?
    public var weight: Int?
    public var admin_state_up: Bool?
    public var pool_id: String?
    public var status: String?
    public var provisioning_status: String?

    public init(
        id: String,
        name: String? = nil,
        address: String,
        protocol_port: Int,
        subnet_id: String? = nil,
        weight: Int? = 1,
        admin_state_up: Bool? = true,
        pool_id: String? = nil,
        status: String? = nil,
        provisioning_status: String? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.protocol_port = protocol_port
        self.subnet_id = subnet_id
        self.weight = weight
        self.admin_state_up = admin_state_up
        self.pool_id = pool_id
        self.status = status
        self.provisioning_status = provisioning_status
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case address, protocol_port
        case subnet_id
        case weight
        case admin_state_up
        case pool_id
        case operating_status
        case provisioning_status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeOrZero(String.self, forKey: .id)
        name = try c.decodeLenient(String.self, forKey: .name)
        address = try c.decodeOrZero(String.self, forKey: .address)
        protocol_port = (try? c.decodeLenient(Int.self, forKey: .protocol_port)) ?? 0
        subnet_id = try c.decodeLenient(String.self, forKey: .subnet_id)
        weight = try c.decodeLenient(Int.self, forKey: .weight)
        admin_state_up = try c.decodeLenient(Bool.self, forKey: .admin_state_up)
        pool_id = try c.decodeLenient(String.self, forKey: .pool_id)
        // `status` is the Octavia operating status; the catalog's statusField
        // for `member` is "status", so surface operating_status under it.
        status = try c.decodeLenient(String.self, forKey: .operating_status)
        provisioning_status = try c.decodeLenient(String.self, forKey: .provisioning_status)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(address, forKey: .address)
        try c.encode(protocol_port, forKey: .protocol_port)
        try c.encodeIfPresent(subnet_id, forKey: .subnet_id)
        try c.encodeIfPresent(weight, forKey: .weight)
        try c.encodeIfPresent(admin_state_up, forKey: .admin_state_up)
        try c.encodeIfPresent(pool_id, forKey: .pool_id)
        try c.encodeIfPresent(status, forKey: .operating_status)
        try c.encodeIfPresent(provisioning_status, forKey: .provisioning_status)
    }
}

/// Health monitor (`/v2/lbaas/healthmonitors`).
///
/// The parent pool arrives as `pools: [{id}]` and is sent as `pool_id`.
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
        case pools
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeOrZero(String.self, forKey: .id)
        name = try c.decodeLenient(String.self, forKey: .name)
        type = try c.decodeOrZero(String.self, forKey: .type)
        delay = try c.decodeLenient(Int.self, forKey: .delay)
        timeout = try c.decodeLenient(Int.self, forKey: .timeout)
        max_retries = try c.decodeLenient(Int.self, forKey: .max_retries)
        pool_id = try c.decodeLenient(String.self, forKey: .pool_id)
            ?? c.firstNestedID(from: .pools)
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

// MARK: - Create / update specs
//
// Bodies are hand-built JSON because the request shape differs from the
// response shape on three resources (see the file header). `omitKeys` carries
// the explicit-null semantics of an update PATCH: Octavia's PUT handlers read
// `to_dict(render_unsets=False)`, so a key that is absent means "leave alone"
// while a key set to null means "clear it". A spec therefore distinguishes
// "not set" (nil) from "clear" (listed in `omitKeys`).

/// Spec for creating a load balancer. Needs a VIP subnet id (or vip_port_id).
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
    /// Set the listener's default pool at create time (Octavia `ListenerPOST`
    /// accepts `default_pool_id`).
    public var default_pool_id: String?

    public init(name: String? = nil, protocolName: String = "HTTP", protocol_port: Int = 80, load_balancer_id: String? = nil, connection_limit: Int? = nil, default_pool_id: String? = nil) {
        self.name = name
        self._protocolName = protocolName
        self.protocol_port = protocol_port
        self.load_balancer_id = load_balancer_id
        self.connection_limit = connection_limit
        self.default_pool_id = default_pool_id
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        parts.append("\"protocol\":\"\(_protocolName)\"")
        parts.append("\"protocol_port\":\(protocol_port)")
        if let lb = load_balancer_id { parts.append("\"loadbalancer_id\":\"\(lb)\"") }
        if let cl = connection_limit { parts.append("\"connection_limit\":\(cl)") }
        if let dp = default_pool_id { parts.append("\"default_pool_id\":\"\(dp)\"") }
        return "{\"listener\":{" + parts.joined(separator: ",") + "}}"
    }
}

/// PATCH body for `PUT /v2/lbaas/listeners/{id}`.
///
/// `default_pool_id` is how a pool is bound to an existing listener; Octavia
/// validates that the pool belongs to the listener's load balancer.
public struct UpdateListenerSpec: Sendable {
    public var name: String?
    public var connection_limit: Int?
    public var default_pool_id: String?
    /// Pass `true` to send `"default_pool_id": null`, which unbinds the pool.
    public var clearDefaultPool: Bool = false

    public init(name: String? = nil, connection_limit: Int? = nil, default_pool_id: String? = nil, clearDefaultPool: Bool = false) {
        self.name = name
        self.connection_limit = connection_limit
        self.default_pool_id = default_pool_id
        self.clearDefaultPool = clearDefaultPool
    }

    public var isEmpty: Bool {
        name == nil && connection_limit == nil && default_pool_id == nil && !clearDefaultPool
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let cl = connection_limit { parts.append("\"connection_limit\":\(cl)") }
        if let dp = default_pool_id {
            parts.append("\"default_pool_id\":\"\(dp)\"")
        } else if clearDefaultPool {
            parts.append("\"default_pool_id\":null")
        }
        return "{\"listener\":{" + parts.joined(separator: ",") + "}}"
    }
}

public struct CreatePoolSpec: Sendable {
    public var name: String?
    public var _protocolName: String
    public var lb_algorithm: String
    public var load_balancer_id: String?
    /// Octavia's `PoolPOST` accepts `listener_id` and makes the new pool that
    /// listener's default pool (it then derives `loadbalancer_id` from the
    /// listener). Exactly one of the two must be supplied, or Octavia answers
    /// `400 ValidationException: Must provide at least one of: loadbalancer_id,
    /// listener_id` — the error the user hit in defect #6 because the schema
    /// dropped this field.
    public var listener_id: String?
    /// Wire name is `healthmonitor_id` (one word); `health_monitor_id` is the DB
    /// column name and is NOT accepted on create.
    public var health_monitor_id: String?

    public init(name: String? = nil, protocolName: String = "HTTP", lb_algorithm: String = "ROUND_ROBIN", load_balancer_id: String? = nil, listener_id: String? = nil, health_monitor_id: String? = nil) {
        self.name = name
        self._protocolName = protocolName
        self.lb_algorithm = lb_algorithm
        self.load_balancer_id = load_balancer_id
        self.listener_id = listener_id
        self.health_monitor_id = health_monitor_id
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        parts.append("\"protocol\":\"\(_protocolName)\"")
        parts.append("\"lb_algorithm\":\"\(lb_algorithm)\"")
        if let lb = load_balancer_id { parts.append("\"loadbalancer_id\":\"\(lb)\"") }
        if let l = listener_id { parts.append("\"listener_id\":\"\(l)\"") }
        if let hm = health_monitor_id { parts.append("\"healthmonitor_id\":\"\(hm)\"") }
        return "{\"pool\":{" + parts.joined(separator: ",") + "}}"
    }
}

/// PATCH body for `PUT /v2/lbaas/pools/{id}`.
///
/// Octavia's `PoolPUT` accepts name/description/lb_algorithm/session_persistence/
/// admin_state_up/tls fields — it does NOT accept `listener_id`, so binding a
/// pool to a listener is a listener update (`UpdateListenerSpec.default_pool_id`).
public struct UpdatePoolSpec: Sendable {
    public var name: String?
    public var description: String?
    public var lb_algorithm: String?

    public init(name: String? = nil, description: String? = nil, lb_algorithm: String? = nil) {
        self.name = name
        self.description = description
        self.lb_algorithm = lb_algorithm
    }

    public var isEmpty: Bool { name == nil && description == nil && lb_algorithm == nil }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let d = description { parts.append("\"description\":\"\(d)\"") }
        if let a = lb_algorithm { parts.append("\"lb_algorithm\":\"\(a)\"") }
        return "{\"pool\":{" + parts.joined(separator: ",") + "}}"
    }
}

/// Members are a pool sub-resource: `pool_id` selects the URL, never the body
/// (`POST /v2/lbaas/pools/{pool_id}/members`).
public struct CreateMemberSpec: Sendable {
    public var name: String?
    public var address: String
    public var protocol_port: Int
    public var subnet_id: String?
    public var weight: Int?
    public var admin_state_up: Bool?
    public var pool_id: String?

    public init(name: String? = nil, address: String, protocol_port: Int, subnet_id: String? = nil, weight: Int? = 1, admin_state_up: Bool? = true, pool_id: String? = nil) {
        self.name = name
        self.address = address
        self.protocol_port = protocol_port
        self.subnet_id = subnet_id
        self.weight = weight
        self.admin_state_up = admin_state_up
        self.pool_id = pool_id
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        parts.append("\"address\":\"\(address)\"")
        parts.append("\"protocol_port\":\(protocol_port)")
        if let s = subnet_id { parts.append("\"subnet_id\":\"\(s)\"") }
        if let w = weight { parts.append("\"weight\":\(w)") }
        if let up = admin_state_up { parts.append("\"admin_state_up\":\(up)") }
        return "{\"member\":{" + parts.joined(separator: ",") + "}}"
    }
}

/// PATCH body for `PUT /v2/lbaas/pools/{pool_id}/members/{member_id}`.
/// `MemberPUT` accepts name/weight/admin_state_up/backup/monitor_*.
public struct UpdateMemberSpec: Sendable {
    public var name: String?
    public var weight: Int?
    public var admin_state_up: Bool?

    public init(name: String? = nil, weight: Int? = nil, admin_state_up: Bool? = nil) {
        self.name = name
        self.weight = weight
        self.admin_state_up = admin_state_up
    }

    public var isEmpty: Bool { name == nil && weight == nil && admin_state_up == nil }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let w = weight { parts.append("\"weight\":\(w)") }
        if let up = admin_state_up { parts.append("\"admin_state_up\":\(up)") }
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
        return "{\"healthmonitor\":{" + parts.joined(separator: ",") + "}}"
    }
}

/// PATCH body for `PUT /v2/lbaas/healthmonitors/{id}`.
public struct UpdateHealthMonitorSpec: Sendable {
    public var name: String?
    public var delay: Int?
    public var timeout: Int?
    public var max_retries: Int?

    public init(name: String? = nil, delay: Int? = nil, timeout: Int? = nil, max_retries: Int? = nil) {
        self.name = name
        self.delay = delay
        self.timeout = timeout
        self.max_retries = max_retries
    }

    public var isEmpty: Bool { name == nil && delay == nil && timeout == nil && max_retries == nil }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let d = delay { parts.append("\"delay\":\(d)") }
        if let t = timeout { parts.append("\"timeout\":\(t)") }
        if let mr = max_retries { parts.append("\"max_retries\":\(mr)") }
        return "{\"healthmonitor\":{" + parts.joined(separator: ",") + "}}"
    }
}

// MARK: - Octavia-tolerant decoding

/// Octavia answers `"name": null`, `"vip_address": null`, `"weight": null`
/// etc. instead of omitting the key. `decodeIfPresent` throws on an explicit
/// null for a non-optional target, which is the exact failure that produced a
/// false 500 out of a successful create (defect #5). These helpers read a null
/// as "absent" and also accept the numeric-string form some clouds emit for
/// integers (Octavia's own api-ref examples post `"protocol_port": "443"`).
extension KeyedDecodingContainer {
    func decodeLenient<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        if type == String.self { return decodeLenientString(forKey: key) as? T }
        if type == Int.self { return decodeLenientInt(forKey: key) as? T }
        if type == Bool.self { return decodeLenientBool(forKey: key) as? T }
        guard contains(key) else { return nil }
        return try decodeIfPresent(T.self, forKey: key)
    }

    /// Decode a required string, treating an explicit null as the empty string
    /// so a missing scalar never fails a create that already succeeded.
    func decodeOrZero(_ type: String.Type, forKey key: Key) throws -> String {
        decodeLenientString(forKey: key) ?? ""
    }

    /// Pull `[{ "id": … }]`-style references out of an Octavia relationship key
    /// (`loadbalancers`, `listeners`, `pools`) and return the first id.
    func firstNestedID(from key: Key) -> String? {
        guard contains(key),
              let arr = try? decode([[String: String]].self, forKey: key) else { return nil }
        return arr.first?["id"]
    }

    private func decodeLenientString(forKey key: Key) -> String? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let b = try? decode(Bool.self, forKey: key) { return String(b) }
        if let d = try? decode(Double.self, forKey: key) { return String(d) }
        return nil
    }

    private func decodeLenientInt(forKey key: Key) -> Int? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let s = try? decode(String.self, forKey: key) { return Int(s) }
        return nil
    }

    private func decodeLenientBool(forKey key: Key) -> Bool? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let b = try? decode(Bool.self, forKey: key) { return b }
        guard let s = try? decode(String.self, forKey: key) else { return nil }
        switch s.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
