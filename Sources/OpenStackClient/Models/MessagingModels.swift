import Foundation

// MARK: - ZaQar (messaging) models — phase 2
//
// Keystone service type: `messaging`. IAD3 advertises the catalog endpoint at
// the host root; the API is project-scoped under `/v1/<project>/queues`, so the
// client injects the token's project into the path (`basePath` is empty). List
// returns a bare JSON array of queue *names*; a single queue returns the
// metadata object.

public struct ZaQarQueue: Sendable, Codable, Identifiable {
    public let id: String   // == name (queues are addressed by name)
    public var name: String
    public var messagesCount: Int?
    public var oldestMessageTimestamp: String?
    public var createdAt: String?

    public init(
        id: String,
        name: String? = nil,
        messagesCount: Int? = nil,
        oldestMessageTimestamp: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.messagesCount = messagesCount
        self.oldestMessageTimestamp = oldestMessageTimestamp
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case messagesCount = "messages_count"
        case oldestMessageTimestamp = "oldest_message_timestamp"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .name) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        messagesCount = try c.decodeIfPresent(Int.self, forKey: .messagesCount)
        oldestMessageTimestamp = try c.decodeIfPresent(String.self, forKey: .oldestMessageTimestamp)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(messagesCount, forKey: .messagesCount)
        try c.encodeIfPresent(oldestMessageTimestamp, forKey: .oldestMessageTimestamp)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}
