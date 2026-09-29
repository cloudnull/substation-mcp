import Foundation
import Testing
@testable import OpenStackClient

@Suite("Cache")
struct CacheTests {
    @Test func putGetRoundTrip() async {
        let cache = Cache(maxEntries: 100)
        let key = CacheKey(tokenID: "tok-1", region: "SAT0", resource: "servers", suffix: "f:status=ACTIVE")
        struct Server: Codable, Sendable { let id: String; let name: String }
        let server = Server(id: "srv-1", name: "web")
        await cache.put(key, ttl: .seconds(30), value: server)
        let result = await cache.get(key, ttl: .seconds(30), as: Server.self)
        #expect(result != nil)
        #expect(result?.id == "srv-1")
        #expect(result?.name == "web")
    }

    @Test func ttlExpiry() async {
        let cache = Cache(maxEntries: 100)
        let key = CacheKey(tokenID: "tok-1", region: "SAT0", resource: "servers", suffix: "")
        struct Item: Codable, Sendable { let v: Int }
        await cache.put(key, ttl: .milliseconds(50), value: Item(v: 1))
        let fresh = await cache.get(key, ttl: .milliseconds(50), as: Item.self)
        #expect(fresh != nil)
        #expect(fresh?.v == 1)
        // Wait past TTL
        try? await Task.sleep(for: .milliseconds(100))
        let expired = await cache.get(key, ttl: .milliseconds(50), as: Item.self)
        #expect(expired == nil)
    }

    @Test func lruEviction() async {
        let cache = Cache(maxEntries: 3)
        let keyA = CacheKey(tokenID: "t", region: "r", resource: "res", suffix: "a")
        let keyB = CacheKey(tokenID: "t", region: "r", resource: "res", suffix: "b")
        let keyC = CacheKey(tokenID: "t", region: "r", resource: "res", suffix: "c")
        let keyD = CacheKey(tokenID: "t", region: "r", resource: "res", suffix: "d")
        struct Item: Codable, Sendable { let v: Int }

        await cache.put(keyA, ttl: .seconds(30), value: Item(v: 1))
        await cache.put(keyB, ttl: .seconds(30), value: Item(v: 2))
        await cache.put(keyC, ttl: .seconds(30), value: Item(v: 3))
        // Access A to make it most-recently-used
        _ = await cache.get(keyA, ttl: .seconds(30), as: Item.self)
        // Put D → should evict B (least recently used)
        await cache.put(keyD, ttl: .seconds(30), value: Item(v: 4))

        #expect(await cache.get(keyB, ttl: .seconds(30), as: Item.self) == nil, "B should be evicted")
        #expect(await cache.get(keyA, ttl: .seconds(30), as: Item.self) != nil, "A should survive")
        #expect(await cache.get(keyC, ttl: .seconds(30), as: Item.self) != nil, "C should survive")
        #expect(await cache.get(keyD, ttl: .seconds(30), as: Item.self) != nil, "D should be present")
    }

    @Test func invalidateClearsResource() async {
        let cache = Cache(maxEntries: 100)
        let key1 = CacheKey(tokenID: "t", region: "r", resource: "servers", suffix: "a")
        let key2 = CacheKey(tokenID: "t", region: "r", resource: "servers", suffix: "b")
        let key3 = CacheKey(tokenID: "t", region: "r", resource: "images", suffix: "a")
        struct Item: Codable, Sendable { let v: Int }

        await cache.put(key1, ttl: .seconds(30), value: Item(v: 1))
        await cache.put(key2, ttl: .seconds(30), value: Item(v: 2))
        await cache.put(key3, ttl: .seconds(30), value: Item(v: 3))

        await cache.invalidate(resource: "servers", tokenID: "t", region: "r")

        #expect(await cache.get(key1, ttl: .seconds(30), as: Item.self) == nil)
        #expect(await cache.get(key2, ttl: .seconds(30), as: Item.self) == nil)
        #expect(await cache.get(key3, ttl: .seconds(30), as: Item.self) != nil, "images should survive")
    }

    @Test func differentTokensDoNotShare() async {
        let cache = Cache(maxEntries: 100)
        let keyA = CacheKey(tokenID: "tok-A", region: "r", resource: "servers", suffix: "")
        let keyB = CacheKey(tokenID: "tok-B", region: "r", resource: "servers", suffix: "")
        struct Item: Codable, Sendable { let v: Int }

        await cache.put(keyA, ttl: .seconds(30), value: Item(v: 1))
        let fromB = await cache.get(keyB, ttl: .seconds(30), as: Item.self)
        #expect(fromB == nil, "Different token IDs must not share entries")
    }

    @Test func statsHitsIncrement() async {
        let cache = Cache(maxEntries: 100)
        let key = CacheKey(tokenID: "t", region: "r", resource: "res", suffix: "")
        struct Item: Codable, Sendable { let v: Int }

        // Miss
        _ = await cache.get(key, ttl: .seconds(30), as: Item.self)
        var stats = await cache.stats
        #expect(stats.misses == 1)
        #expect(stats.hits == 0)

        await cache.put(key, ttl: .seconds(30), value: Item(v: 1))
        // Hit
        _ = await cache.get(key, ttl: .seconds(30), as: Item.self)
        stats = await cache.stats
        #expect(stats.hits == 1)
        #expect(stats.misses == 1)
    }
}
