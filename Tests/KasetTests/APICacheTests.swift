import Foundation
import Testing
@testable import Kaset

/// Tests for APICache.
@Suite(.serialized)
@MainActor
struct APICacheTests {
    var cache: APICache

    init() {
        self.cache = APICache.shared
        self.cache.invalidateAll()
    }

    @Test("Cache set and get")
    func cacheSetAndGet() {
        let data: [String: Any] = ["key": "value", "number": 42]
        cache.set(key: "test_key", data: data, ttl: 60)

        let retrieved = cache.get(key: "test_key")
        #expect(retrieved != nil)
        #expect(retrieved?["key"] as? String == "value")
        #expect(retrieved?["number"] as? Int == 42)
    }

    @Test("Cache get nonexistent returns nil")
    func cacheGetNonexistent() {
        let retrieved = cache.get(key: "nonexistent_key")
        #expect(retrieved == nil)
    }

    @Test("Cache invalidate all")
    func cacheInvalidateAll() {
        cache.set(key: "key1", data: ["a": 1], ttl: 60)
        cache.set(key: "key2", data: ["b": 2], ttl: 60)

        #expect(cache.get(key: "key1") != nil)
        #expect(cache.get(key: "key2") != nil)

        cache.invalidateAll()

        #expect(cache.get(key: "key1") == nil)
        #expect(cache.get(key: "key2") == nil)
    }

    @Test("Cache invalidate matching prefix")
    func cacheInvalidateMatchingPrefix() {
        cache.set(key: "home_section1", data: ["a": 1], ttl: 60)
        cache.set(key: "home_section2", data: ["b": 2], ttl: 60)
        cache.set(key: "search_results", data: ["c": 3], ttl: 60)

        cache.invalidate(matching: "home_")

        #expect(cache.get(key: "home_section1") == nil)
        #expect(cache.get(key: "home_section2") == nil)
        #expect(cache.get(key: "search_results") != nil)
    }

    @Test("Cache entry expiration")
    func cacheEntryExpiration() async throws {
        cache.set(key: "short_lived", data: ["test": true], ttl: 0.1)

        #expect(cache.get(key: "short_lived") != nil)

        try await Task.sleep(for: .milliseconds(150))

        #expect(cache.get(key: "short_lived") == nil)
    }

    @Test("Cache overwrite")
    func cacheOverwrite() {
        cache.set(key: "key", data: ["value": 1], ttl: 60)
        #expect(cache.get(key: "key")?["value"] as? Int == 1)

        cache.set(key: "key", data: ["value": 2], ttl: 60)
        #expect(cache.get(key: "key")?["value"] as? Int == 2)
    }

    @Test("Cache TTL constants are correct")
    func cacheTTLConstants() {
        #expect(APICache.TTL.home == 5 * 60)           // 5 minutes
        #expect(APICache.TTL.playlist == 30 * 60)       // 30 minutes
        #expect(APICache.TTL.artist == 60 * 60)         // 1 hour
        #expect(APICache.TTL.search == 2 * 60)          // 2 minutes
        #expect(APICache.TTL.library == 5 * 60)         // 5 minutes
        #expect(APICache.TTL.lyrics == 24 * 60 * 60)    // 24 hours
        #expect(APICache.TTL.songMetadata == 30 * 60)   // 30 minutes
    }

    @Test("Lyrics cache not invalidated by mutations")
    func lyricsCacheNotInvalidatedByMutations() {
        cache.set(key: "browse:lyrics_abc123", data: ["text": "lyrics content"], ttl: APICache.TTL.lyrics)
        cache.set(key: "next:song_abc123", data: ["title": "song"], ttl: APICache.TTL.songMetadata)

        cache.invalidate(matching: "next:")

        #expect(cache.get(key: "browse:lyrics_abc123") != nil)
        #expect(cache.get(key: "next:song_abc123") == nil)
    }

    @Test("Song metadata cache invalidated by mutations")
    func songMetadataCacheInvalidatedByMutations() {
        cache.set(key: "next:song_abc123", data: ["title": "song"], ttl: APICache.TTL.songMetadata)
        cache.set(key: "browse:home_section", data: ["section": "home"], ttl: APICache.TTL.home)

        cache.invalidate(matching: "browse:")
        cache.invalidate(matching: "next:")

        #expect(cache.get(key: "next:song_abc123") == nil)
        #expect(cache.get(key: "browse:home_section") == nil)
    }

    @Test("Cache entry isExpired property")
    func cacheEntryIsExpired() {
        let freshEntry = APICache.CacheEntry(
            data: [:],
            timestamp: Date(),
            ttl: 60
        )
        #expect(freshEntry.isExpired == false)

        let expiredEntry = APICache.CacheEntry(
            data: [:],
            timestamp: Date().addingTimeInterval(-120),
            ttl: 60
        )
        #expect(expiredEntry.isExpired == true)
    }

    @Test("Cache shared instance is singleton")
    func cacheSharedInstance() {
        #expect(APICache.shared != nil)
        let instance1 = APICache.shared
        let instance2 = APICache.shared
        #expect(instance1 === instance2)
    }
}
