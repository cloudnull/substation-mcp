import Foundation

/// Key for cache entries. Token-ID-keyed so two tenants never share an entry.
public struct CacheKey: Hashable, Sendable {
    public let tokenID: String
    public let region: String
    public let resource: String
    public let suffix: String

    public init(tokenID: String, region: String, resource: String, suffix: String = "") {
        self.tokenID = tokenID
        self.region = region
        self.resource = resource
        self.suffix = suffix
    }
}

/// Token-ID-keyed TTL/LRU cache with invalidation.
/// Stored as JSON Data (values already decoded from the wire once).
public actor Cache {
    private struct Entry {
        let data: Data
        let expires: ContinuousClock.Instant
        let lastAccess: Int
    }

    private var storage: [CacheKey: Entry] = [:]
    private var accessCounter: Int = 0
    private let maxEntries: Int
    private var hits: Int = 0
    private var misses: Int = 0
    private let clock: ContinuousClock

    public init(maxEntries: Int = 2000, clock: ContinuousClock = ContinuousClock()) {
        self.maxEntries = maxEntries
        self.clock = clock
    }

    public func get<T: Codable & Sendable>(
        _ key: CacheKey,
        ttl: Duration,
        as type: T.Type
    ) async -> T? {
        guard let entry = storage[key] else {
            misses += 1
            return nil
        }

        let now = clock.now
        if now >= entry.expires {
            storage[key] = nil
            misses += 1
            return nil
        }

        // Update last-access for LRU
        accessCounter += 1
        storage[key] = Entry(data: entry.data, expires: entry.expires, lastAccess: accessCounter)
        hits += 1
        OSMetrics.cacheHit(resource: key.resource)

        return try? JSONDecoder().decode(T.self, from: entry.data)
    }

    public func put<T: Codable & Sendable>(
        _ key: CacheKey,
        ttl: Duration,
        value: T
    ) async {
        accessCounter += 1
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        let expires = clock.now + ttl
        storage[key] = Entry(data: data, expires: expires, lastAccess: accessCounter)

        // Evict LRU entries if over capacity
        if storage.count > maxEntries {
            evictLRU()
        }
    }

    /// Clears all keys for the given resource+tokenID+region combination.
    public func invalidate(resource: String, tokenID: String, region: String) async {
        let keysToRemove = storage.keys.filter {
            $0.resource == resource && $0.tokenID == tokenID && $0.region == region
        }
        for key in keysToRemove {
            storage[key] = nil
        }
    }

    public var stats: (hits: Int, misses: Int) {
        (hits: hits, misses: misses)
    }

    private func evictLRU() {
        let excess = storage.count - maxEntries
        guard excess > 0 else { return }
        let sorted = storage.sorted { $0.value.lastAccess < $1.value.lastAccess }
        let toRemove = sorted.prefix(excess)
        for (key, _) in toRemove {
            storage[key] = nil
        }
    }
}
