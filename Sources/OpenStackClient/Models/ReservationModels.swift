import Foundation

// MARK: - Blazar (reservation) models — phase 2
//
// Keystone service type: `reservation`. IAD3 catalog endpoint carries `/v1`.
// List responses are keyed envelopes (`{"reservations":[...]}`), single items
// return the bare object.

public struct BlazarReservation: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var status: String
    public var allocationID: String?
    public var flavorID: String?
    public var instanceID: String?
    public var created: String?
    public var updated: String?
    public var expired: String?

    public init(
        id: String,
        name: String? = nil,
        status: String = "BUILDING",
        allocationID: String? = nil,
        flavorID: String? = nil,
        instanceID: String? = nil,
        created: String? = nil,
        updated: String? = nil,
        expired: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.allocationID = allocationID
        self.flavorID = flavorID
        self.instanceID = instanceID
        self.created = created
        self.updated = updated
        self.expired = expired
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, created, updated, expired
        case allocationID = "allocation_id"
        case flavorID = "flavor_id"
        case instanceID = "instance_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "BUILDING"
        allocationID = try c.decodeIfPresent(String.self, forKey: .allocationID)
        flavorID = try c.decodeIfPresent(String.self, forKey: .flavorID)
        instanceID = try c.decodeIfPresent(String.self, forKey: .instanceID)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        expired = try c.decodeIfPresent(String.self, forKey: .expired)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(allocationID, forKey: .allocationID)
        try c.encodeIfPresent(flavorID, forKey: .flavorID)
        try c.encodeIfPresent(instanceID, forKey: .instanceID)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encodeIfPresent(updated, forKey: .updated)
        try c.encodeIfPresent(expired, forKey: .expired)
    }
}

public struct BlazarAllocation: Sendable, Codable, Identifiable {
    public let id: String
    public var status: String
    public var nodeID: String?
    public var reservationID: String?
    public var created: String?

    public init(id: String, status: String = "ACTIVE", nodeID: String? = nil, reservationID: String? = nil, created: String? = nil) {
        self.id = id
        self.status = status
        self.nodeID = nodeID
        self.reservationID = reservationID
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case id, status, created
        case nodeID = "node_id"
        case reservationID = "reservation_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "ACTIVE"
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID)
        reservationID = try c.decodeIfPresent(String.self, forKey: .reservationID)
        created = try c.decodeIfPresent(String.self, forKey: .created)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(nodeID, forKey: .nodeID)
        try c.encodeIfPresent(reservationID, forKey: .reservationID)
        try c.encodeIfPresent(created, forKey: .created)
    }
}

/// Spec for creating a Blazar reservation.
public struct CreateBlazarReservationSpec: Sendable {
    public var name: String?
    public var flavorID: String?
    public var expiry: String?
    public var requiredAny: [[String: String]]

    public init(name: String? = nil, flavorID: String? = nil, expiry: String? = nil, requiredAny: [[String: String]] = []) {
        self.name = name
        self.flavorID = flavorID
        self.expiry = expiry
        self.requiredAny = requiredAny
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let flavorID { parts.append("\"flavor_id\":\"\(flavorID)\"") }
        if let expiry { parts.append("\"expired_at\":\"\(expiry)\"") }
        if !requiredAny.isEmpty {
            let cond = requiredAny.map { cond in
                let pairs = cond.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
                return "{\(pairs)}"
            }.joined(separator: ",")
            parts.append("\"node_selector\":{\"required_any\":[\(cond)]}")
        }
        return "{\"reservation\":{" + parts.joined(separator: ",") + "}}"
    }
}
