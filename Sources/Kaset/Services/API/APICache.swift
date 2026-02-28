import CryptoKit
import Foundation

/// Thread-safe cache for API responses with TTL and LRU eviction support.
/// Uses @MainActor since YTMusicClient is also @MainActor.
@MainActor
final class APICache {
    static let shared = APICache()

    struct CacheEntry {
        let data: [String: Any]
        let timestamp: Date
        let ttl: TimeInterval
        var lastAccessed: Date

        var isExpired: Bool {
            Date().timeIntervalSince(self.timestamp) > self.ttl
        }

        init(data: [String: Any], timestamp: Date, ttl: TimeInterval) {
            self.data = data
            self.timestamp = timestamp
            self.ttl = ttl
            self.lastAccessed = timestamp
        }
    }

    /// TTL values for different endpoint types.
    enum TTL {
        static let home: TimeInterval = 5 * 60 // 5 minutes
        static let playlist: TimeInterval = 30 * 60 // 30 minutes
        static let artist: TimeInterval = 60 * 60 // 1 hour
        static let search: TimeInterval = 2 * 60 // 2 minutes
        static let library: TimeInterval = 5 * 60 // 5 minutes
        static let lyrics: TimeInterval = 24 * 60 * 60 // 24 hours
        static let songMetadata: TimeInterval = 30 * 60 // 30 minutes
    }

    /// Maximum number of cached entries before LRU eviction kicks in.
    private static let maxEntries = 50

    /// Pre-allocated dictionary with initial capacity to reduce rehashing.
    private var cache: [String: CacheEntry]

    /// Timestamp of last eviction to avoid running on every access.
    private var lastEvictionTime: Date = .distantPast

    /// Minimum interval between automatic evictions (30 seconds).
    private static let evictionInterval: TimeInterval = 30

    private init() {
        // Pre-allocate capacity to avoid rehashing during normal operation
        self.cache = Dictionary(minimumCapacity: Self.maxEntries)
    }

    /// Gets cached data if available and not expired.
    func get(key: String) -> [String: Any]? {
        guard var entry = cache[key] else { return nil }

        if entry.isExpired {
            self.cache.removeValue(forKey: key)
            return nil
        }

        // Update last accessed time for LRU tracking
        entry.lastAccessed = Date()
        self.cache[key] = entry
        return entry.data
    }

    /// Stores data in the cache with the specified TTL.
    /// Evicts least recently used entries if cache is at capacity.
    func set(key: String, data: [String: Any], ttl: TimeInterval) {
        let now = Date()

        // Evict expired entries periodically (not on every set)
        if now.timeIntervalSince(self.lastEvictionTime) > Self.evictionInterval {
            self.evictExpiredEntries()
            self.lastEvictionTime = now
        }

        // Evict LRU entries if still at capacity
        while self.cache.count >= Self.maxEntries {
            self.evictLeastRecentlyUsed()
        }

        self.cache[key] = CacheEntry(data: data, timestamp: now, ttl: ttl)
    }

    private static let logger = DiagnosticsLogger.api

    /// Generates a stable, deterministic cache key from endpoint, request body, and brand ID.
    /// Uses SHA256 hash of sorted JSON to ensure consistency.
    /// Including brandId ensures cache isolation between accounts.
    static func stableCacheKey(endpoint: String, body: [String: Any], brandId: String = "") -> String {
        // Use JSONSerialization with .sortedKeys for deterministic output
        // This is more efficient than custom recursive string building
        let jsonData: Data
        do {
            // .sortedKeys available since macOS 10.13, we target macOS 26+
            jsonData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            // Log the error and use endpoint-only key to avoid collisions
            Self.logger.error("APICache: Failed to serialize body for cache key: \(error.localizedDescription)")
            // Return endpoint-only key with error marker to avoid collisions
            return "\(endpoint):serialization_error_\(body.count)"
        }

        // Include brand ID in hash to isolate cache between accounts
        var hashData = jsonData
        if !brandId.isEmpty {
            // Use NUL byte separator to avoid ambiguity between JSON and brandId bytes
            hashData.append(0)
            hashData.append(Data(brandId.utf8))
        }

        let hash = SHA256.hash(data: hashData)
        let hashString = hash.prefix(16).compactMap { String(format: "%02x", $0) }.joined()
        return "\(endpoint):\(hashString)"
    }

    /// Invalidates all cached entries.
    func invalidateAll() {
        self.cache.removeAll()
    }

    /// Invalidates entries matching the given prefix.
    func invalidate(matching prefix: String) {
        self.cache = self.cache.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Invalidates all caches affected by mutation operations (like, library, feedback).
    /// More efficient than multiple invalidate(matching:) calls as it iterates only once.
    func invalidateMutationCaches() {
        let mutationPrefixes = ["browse:", "next:", "like:"]
        self.cache = self.cache.filter { entry in
            !mutationPrefixes.contains { entry.key.hasPrefix($0) }
        }
    }

    /// Returns current cache statistics for debugging.
    var stats: (count: Int, expired: Int) {
        let expired = self.cache.values.filter(\.isExpired).count
        return (self.cache.count, expired)
    }

    // MARK: - Private Helpers

    /// Evicts all expired entries from the cache.
    private func evictExpiredEntries() {
        self.cache = self.cache.filter { !$0.value.isExpired }
    }

    /// Evicts the least recently used entry from the cache.
    private func evictLeastRecentlyUsed() {
        guard let lruKey = cache.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key else {
            return
        }
        self.cache.removeValue(forKey: lruKey)
    }
}
