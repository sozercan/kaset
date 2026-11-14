import Foundation
import Testing
@testable import Kaset

/// Tests for APICache.
@Suite(.serialized, .tags(.service))
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
        self.cache.set(key: "test_key", data: data, ttl: 60)

        let retrieved = self.cache.get(key: "test_key")
        #expect(retrieved != nil)
        #expect(retrieved?["key"] as? String == "value")
        #expect(retrieved?["number"] as? Int == 42)
    }

    @Test("Cache get nonexistent returns nil")
    func cacheGetNonexistent() {
        let retrieved = self.cache.get(key: "nonexistent_key")
        #expect(retrieved == nil)
    }

    @Test("Raw data set and get round-trips")
    func cacheDataSetAndGet() {
        let bytes = Data("a 2MB-ish home response would go here".utf8)
        self.cache.setData(key: "raw_key", data: bytes, ttl: 60)

        #expect(self.cache.getData(key: "raw_key") == bytes)
        // Missing key is nil, and a dict-typed entry is not mistaken for data.
        #expect(self.cache.getData(key: "nonexistent_raw") == nil)
        self.cache.set(key: "dict_key", data: ["k": 1], ttl: 60)
        #expect(self.cache.getData(key: "dict_key") == nil)
    }

    @Test("invalidateAll bumps the generation counter")
    func invalidateAllBumpsGeneration() {
        // Callers capture the generation before an async fetch and refuse to
        // write a stale response if it changed (account switch / sign-out /
        // session expiry), even when the cache-scope key is unchanged.
        let before = self.cache.generation
        self.cache.invalidateAll()
        #expect(self.cache.generation == before + 1)
        self.cache.invalidateAll()
        #expect(self.cache.generation == before + 2)
    }

    @Test("Cache invalidate all")
    func cacheInvalidateAll() {
        self.cache.set(key: "key1", data: ["a": 1], ttl: 60)
        self.cache.set(key: "key2", data: ["b": 2], ttl: 60)

        #expect(self.cache.get(key: "key1") != nil)
        #expect(self.cache.get(key: "key2") != nil)

        self.cache.invalidateAll()

        #expect(self.cache.get(key: "key1") == nil)
        #expect(self.cache.get(key: "key2") == nil)
    }

    @Test("Cache invalidate matching prefix")
    func cacheInvalidateMatchingPrefix() {
        self.cache.set(key: "home_section1", data: ["a": 1], ttl: 60)
        self.cache.set(key: "home_section2", data: ["b": 2], ttl: 60)
        self.cache.set(key: "search_results", data: ["c": 3], ttl: 60)

        self.cache.invalidate(matching: "home_")

        #expect(self.cache.get(key: "home_section1") == nil)
        #expect(self.cache.get(key: "home_section2") == nil)
        #expect(self.cache.get(key: "search_results") != nil)
    }

    @Test("Cache entry expiration")
    func cacheEntryExpiration() async throws {
        self.cache.set(key: "short_lived", data: ["test": true], ttl: 0.1)

        #expect(self.cache.get(key: "short_lived") != nil)

        try await Task.sleep(for: .milliseconds(150))

        #expect(self.cache.get(key: "short_lived") == nil)
    }

    @Test("Cache overwrite")
    func cacheOverwrite() {
        self.cache.set(key: "key", data: ["value": 1], ttl: 60)
        #expect(self.cache.get(key: "key")?["value"] as? Int == 1)

        self.cache.set(key: "key", data: ["value": 2], ttl: 60)
        #expect(self.cache.get(key: "key")?["value"] as? Int == 2)
    }

    @Test("Older in-flight responses cannot overwrite the newest cache write")
    func newestWriteReservationWins() throws {
        let generation = self.cache.generation
        let olderTicket = try #require(self.cache.prepareWrite(cacheGeneration: generation))
        let newerTicket = try #require(self.cache.prepareWrite(cacheGeneration: generation))
        let older = try #require(self.cache.beginWrite(for: "key", ticket: olderTicket))
        let newer = try #require(self.cache.beginWrite(for: "key", ticket: newerTicket))

        self.cache.setIfCurrent(
            key: "key",
            data: ["value": "newer"],
            ttl: 60,
            reservation: newer
        )
        self.cache.finishWrite(newerTicket)
        self.cache.setIfCurrent(
            key: "key",
            data: ["value": "older"],
            ttl: 60,
            reservation: older
        )
        self.cache.finishWrite(olderTicket)

        #expect(self.cache.get(key: "key")?["value"] as? String == "newer")
    }

    @Test("Request order survives out-of-order cache-key resolution")
    func writeTicketOrderWinsBeforeKeyClaim() throws {
        let generation = self.cache.generation
        let olderTicket = try #require(self.cache.prepareWrite(cacheGeneration: generation))
        let newerTicket = try #require(self.cache.prepareWrite(cacheGeneration: generation))
        let newer = try #require(self.cache.beginWrite(for: "key", ticket: newerTicket))

        self.cache.setIfCurrent(
            key: "key",
            data: ["value": "newer"],
            ttl: 60,
            reservation: newer
        )
        self.cache.finishWrite(newerTicket)

        let lateOlderClaim = self.cache.beginWrite(for: "key", ticket: olderTicket)
        #expect(lateOlderClaim == nil)
        self.cache.finishWrite(olderTicket)
        #expect(self.cache.get(key: "key")?["value"] as? String == "newer")
    }

    @Test("Matching invalidation rejects tickets prepared before key resolution")
    func invalidationRejectsPreparedWriteTicket() throws {
        let ticket = try #require(
            self.cache.prepareWrite(cacheGeneration: self.cache.generation)
        )

        self.cache.invalidate(matching: "key")

        #expect(self.cache.beginWrite(for: "key", ticket: ticket) == nil)
        self.cache.finishWrite(ticket)
    }

    @Test("Scoped invalidation cancels only matching active writes")
    func scopedInvalidationCancelsOnlyMatchingActiveWrites() throws {
        let browseKey = "browse:home"
        let youtubeKey = "yt:data:browse"
        self.cache.set(key: browseKey, data: ["value": "old"], ttl: 60)
        self.cache.set(key: youtubeKey, data: ["value": "old"], ttl: 60)

        let generation = self.cache.generation
        let browseTicket = try #require(self.cache.prepareWrite(cacheGeneration: generation))
        let youtubeTicket = try #require(self.cache.prepareWrite(cacheGeneration: generation))
        let browseWrite = try #require(self.cache.beginWrite(for: browseKey, ticket: browseTicket))
        let youtubeWrite = try #require(self.cache.beginWrite(for: youtubeKey, ticket: youtubeTicket))

        self.cache.invalidate(matching: "yt:")
        self.cache.setIfCurrent(
            key: browseKey,
            data: ["value": "fresh"],
            ttl: 60,
            reservation: browseWrite
        )
        self.cache.setIfCurrent(
            key: youtubeKey,
            data: ["value": "stale"],
            ttl: 60,
            reservation: youtubeWrite
        )
        self.cache.finishWrite(browseTicket)
        self.cache.finishWrite(youtubeTicket)

        #expect(self.cache.get(key: browseKey)?["value"] as? String == "fresh")
        #expect(self.cache.get(key: youtubeKey) == nil)
    }

    @Test("Mutation invalidation preserves unrelated active writes")
    func mutationInvalidationPreservesUnrelatedActiveWrite() throws {
        let key = "yt:data:browse"
        self.cache.set(key: key, data: ["value": "old"], ttl: 60)
        let ticket = try #require(
            self.cache.prepareWrite(cacheGeneration: self.cache.generation)
        )
        let write = try #require(self.cache.beginWrite(for: key, ticket: ticket))

        self.cache.invalidateMutationCaches()
        self.cache.setIfCurrent(
            key: key,
            data: ["value": "fresh"],
            ttl: 60,
            reservation: write
        )
        self.cache.finishWrite(ticket)

        #expect(self.cache.get(key: key)?["value"] as? String == "fresh")
    }

    @Test("Cache TTL constants are correct")
    func cacheTTLConstants() {
        #expect(APICache.TTL.home == 5 * 60) // 5 minutes
        #expect(APICache.TTL.playlist == 30 * 60) // 30 minutes
        #expect(APICache.TTL.artist == 60 * 60) // 1 hour
        #expect(APICache.TTL.search == 2 * 60) // 2 minutes
        #expect(APICache.TTL.library == 5 * 60) // 5 minutes
        #expect(APICache.TTL.lyrics == 24 * 60 * 60) // 24 hours
        #expect(APICache.TTL.songMetadata == 30 * 60) // 30 minutes
    }

    @Test("Cache keys change when API request language changes")
    func stableCacheKeyChangesWhenRequestLanguageChanges() {
        let englishBody: [String: Any] = [
            "browseId": "FEmusic_home",
            "context": [
                "client": [
                    "hl": "en",
                    "gl": "US",
                ],
            ],
        ]
        let koreanBody: [String: Any] = [
            "browseId": "FEmusic_home",
            "context": [
                "client": [
                    "hl": "ko",
                    "gl": "US",
                ],
            ],
        ]

        let englishKey = APICache.stableCacheKey(endpoint: "browse", body: englishBody)
        let koreanKey = APICache.stableCacheKey(endpoint: "browse", body: koreanBody)

        #expect(englishKey != koreanKey)
    }

    @Test("Lyrics cache not invalidated by mutations")
    func lyricsCacheNotInvalidatedByMutations() {
        self.cache.set(key: "browse:lyrics_abc123", data: ["text": "lyrics content"], ttl: APICache.TTL.lyrics)
        self.cache.set(key: "next:song_abc123", data: ["title": "song"], ttl: APICache.TTL.songMetadata)

        self.cache.invalidate(matching: "next:")

        #expect(self.cache.get(key: "browse:lyrics_abc123") != nil)
        #expect(self.cache.get(key: "next:song_abc123") == nil)
    }

    @Test("Song metadata cache invalidated by mutations")
    func songMetadataCacheInvalidatedByMutations() {
        self.cache.set(key: "next:song_abc123", data: ["title": "song"], ttl: APICache.TTL.songMetadata)
        self.cache.set(key: "browse:home_section", data: ["section": "home"], ttl: APICache.TTL.home)

        self.cache.invalidate(matching: "browse:")
        self.cache.invalidate(matching: "next:")

        #expect(self.cache.get(key: "next:song_abc123") == nil)
        #expect(self.cache.get(key: "browse:home_section") == nil)
    }

    @Test("Mutation invalidation clears add-to-playlist options")
    func mutationInvalidationClearsAddToPlaylistOptions() {
        self.cache.set(key: "browse:library", data: ["type": "library"], ttl: APICache.TTL.library)
        self.cache.set(key: "next:song_abc123", data: ["title": "song"], ttl: APICache.TTL.songMetadata)
        self.cache.set(key: "like:status_abc123", data: ["status": "LIKE"], ttl: APICache.TTL.songMetadata)
        self.cache.set(
            key: "playlist/get_add_to_playlist:abc123",
            data: ["playlists": []],
            ttl: APICache.TTL.library
        )
        self.cache.set(key: "search:query", data: ["results": []], ttl: APICache.TTL.search)

        self.cache.invalidateMutationCaches()

        #expect(self.cache.get(key: "browse:library") == nil)
        #expect(self.cache.get(key: "next:song_abc123") == nil)
        #expect(self.cache.get(key: "like:status_abc123") == nil)
        #expect(self.cache.get(key: "playlist/get_add_to_playlist:abc123") == nil)
        #expect(self.cache.get(key: "search:query") != nil)
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
