import CryptoKit
import Foundation

@MainActor
final class APICache {
    static let shared = APICache()

    struct WriteTicket {
        fileprivate let cacheGeneration: Int
        fileprivate let scopedInvalidationOrder: UInt64
        fileprivate let requestOrder: UInt64
    }

    struct WriteReservation {
        fileprivate let key: String
        fileprivate let ticket: WriteTicket
    }

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

    enum TTL {
        static let home: TimeInterval = 5 * 60
        static let playlist: TimeInterval = 30 * 60
        static let artist: TimeInterval = 60 * 60
        static let search: TimeInterval = 2 * 60
        static let library: TimeInterval = 5 * 60
        static let lyrics: TimeInterval = 24 * 60 * 60
        static let songMetadata: TimeInterval = 30 * 60
    }

    private static let maxEntries = 50

    private var cache: [String: CacheEntry]

    private var nextWriteOrder: UInt64 = 0
    private var nextScopedInvalidationOrder: UInt64 = 0
    private var activeWriteOrders: Set<UInt64> = []
    private var latestWriteOrders: [String: UInt64] = [:]
    private var latestScopedInvalidationOrders: [String: UInt64] = [:]

    private var lastEvictionTime: Date = .distantPast

    private static let evictionInterval: TimeInterval = 30

    init() {
        self.cache = Dictionary(minimumCapacity: Self.maxEntries)
    }

    func get(key: String) -> [String: Any]? {
        guard var entry = cache[key] else { return nil }

        if entry.isExpired {
            self.cache.removeValue(forKey: key)
            return nil
        }

        entry.lastAccessed = Date()
        self.cache[key] = entry
        return entry.data
    }

    func set(key: String, data: [String: Any], ttl: TimeInterval) {
        let now = Date()

        if now.timeIntervalSince(self.lastEvictionTime) > Self.evictionInterval {
            self.evictExpiredEntries()
            self.lastEvictionTime = now
        }

        while self.cache.count >= Self.maxEntries {
            self.evictLeastRecentlyUsed()
        }

        self.cache[key] = CacheEntry(data: data, timestamp: now, ttl: ttl)
    }

    private static let rawDataBoxKey = "__APICacheRawData__"

    func getData(key: String) -> Data? {
        self.get(key: key)?[Self.rawDataBoxKey] as? Data
    }

    func setData(key: String, data: Data, ttl: TimeInterval) {
        self.set(key: key, data: [Self.rawDataBoxKey: data], ttl: ttl)
    }

    func prepareWrite(cacheGeneration: Int) -> WriteTicket? {
        guard cacheGeneration == self.generation else { return nil }
        self.nextWriteOrder &+= 1
        let ticket = WriteTicket(
            cacheGeneration: cacheGeneration,
            scopedInvalidationOrder: self.nextScopedInvalidationOrder,
            requestOrder: self.nextWriteOrder
        )
        self.activeWriteOrders.insert(ticket.requestOrder)
        return ticket
    }

    func beginWrite(for key: String, ticket: WriteTicket) -> WriteReservation? {
        guard ticket.cacheGeneration == self.generation,
              self.activeWriteOrders.contains(ticket.requestOrder),
              !self.wasInvalidated(ticket, for: key),
              ticket.requestOrder > (self.latestWriteOrders[key] ?? 0)
        else {
            return nil
        }
        self.latestWriteOrders[key] = ticket.requestOrder
        return WriteReservation(key: key, ticket: ticket)
    }

    func setIfCurrent(
        key: String,
        data: [String: Any],
        ttl: TimeInterval,
        reservation: WriteReservation
    ) {
        guard self.isCurrent(reservation, for: key) else { return }
        self.set(key: key, data: data, ttl: ttl)
    }

    func setDataIfCurrent(
        key: String,
        data: Data,
        ttl: TimeInterval,
        reservation: WriteReservation
    ) {
        guard self.isCurrent(reservation, for: key) else { return }
        self.setData(key: key, data: data, ttl: ttl)
    }

    func finishWrite(_ ticket: WriteTicket) {
        guard ticket.cacheGeneration == self.generation else {
            return
        }
        self.activeWriteOrders.remove(ticket.requestOrder)
        self.pruneWriteOrderState()
    }

    private static let logger = DiagnosticsLogger.api

    static func stableCacheKey(endpoint: String, body: [String: Any], brandId: String = "") -> String? {
        guard JSONSerialization.isValidJSONObject(body) else {
            self.logger.error("APICache: Skipping cache key for non-JSON-serializable body on \(endpoint)")
            return nil
        }

        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            Self.logger.error("APICache: Failed to serialize body for cache key: \(error.localizedDescription)")
            return nil
        }

        var hashData = jsonData
        if !brandId.isEmpty {
            hashData.append(0)
            hashData.append(Data(brandId.utf8))
        }

        let hash = SHA256.hash(data: hashData)
        let hashString = hash.prefix(16).compactMap { String(format: "%02x", $0) }.joined()
        return "\(endpoint):\(hashString)"
    }

    private(set) var generation = 0

    func invalidateAll() {
        self.cache.removeAll()
        self.generation &+= 1
        self.invalidateAllPendingWrites()
    }

    func invalidate(matching prefix: String) {
        self.cache = self.cache.filter { !$0.key.hasPrefix(prefix) }
        self.invalidatePendingWrites(matching: [prefix])
    }

    func invalidateMutationCaches() {
        let mutationPrefixes = [
            "browse:",
            "next:",
            "like:",
            "playlist/get_add_to_playlist:",
        ]
        self.cache = self.cache.filter { entry in
            !mutationPrefixes.contains { entry.key.hasPrefix($0) }
        }
        self.invalidatePendingWrites(matching: mutationPrefixes)
    }

    var stats: (count: Int, expired: Int) {
        let expired = self.cache.values.filter(\.isExpired).count
        return (self.cache.count, expired)
    }

    private func evictExpiredEntries() {
        self.cache = self.cache.filter { !$0.value.isExpired }
    }

    private func evictLeastRecentlyUsed() {
        guard let lruKey = cache.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key else {
            return
        }
        self.cache.removeValue(forKey: lruKey)
    }

    private func isCurrent(_ reservation: WriteReservation, for key: String) -> Bool {
        reservation.key == key
            && reservation.ticket.cacheGeneration == self.generation
            && self.activeWriteOrders.contains(reservation.ticket.requestOrder)
            && !self.wasInvalidated(reservation.ticket, for: key)
            && self.latestWriteOrders[key] == reservation.ticket.requestOrder
    }

    private func invalidateAllPendingWrites() {
        self.activeWriteOrders.removeAll()
        self.latestWriteOrders.removeAll()
        self.latestScopedInvalidationOrders.removeAll()
    }

    private func invalidatePendingWrites(matching prefixes: [String]) {
        guard !prefixes.isEmpty else { return }

        self.nextScopedInvalidationOrder &+= 1
        let invalidationOrder = self.nextScopedInvalidationOrder
        for prefix in prefixes {
            self.latestScopedInvalidationOrders[prefix] = invalidationOrder
        }
        self.latestWriteOrders = self.latestWriteOrders.filter { entry in
            !prefixes.contains { entry.key.hasPrefix($0) }
        }
    }

    private func wasInvalidated(_ ticket: WriteTicket, for key: String) -> Bool {
        self.latestScopedInvalidationOrders.contains { entry in
            entry.value > ticket.scopedInvalidationOrder && key.hasPrefix(entry.key)
        }
    }

    private func pruneWriteOrderState() {
        guard let oldestActiveOrder = self.activeWriteOrders.min() else {
            self.latestWriteOrders.removeAll()
            return
        }
        self.latestWriteOrders = self.latestWriteOrders.filter { $0.value >= oldestActiveOrder }
    }
}
