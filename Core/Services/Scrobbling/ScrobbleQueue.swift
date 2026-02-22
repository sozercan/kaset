import Foundation

/// Persistent queue for pending scrobbles.
/// Serializes to JSON in `~/Library/Application Support/Kaset/scrobble-queue.json`.
/// Thread safety is ensured by `@MainActor` callers (ScrobblingCoordinator).
@MainActor
final class ScrobbleQueue {
    private var items: [ScrobbleTrack] = []
    private let fileURL: URL
    private let logger = DiagnosticsLogger.scrobbling

    /// Maximum age for queued scrobbles (14 days). Last.fm rejects older submissions.
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60

    /// Number of pending scrobbles in the queue.
    var count: Int {
        self.items.count
    }

    /// Whether the queue has pending scrobbles.
    var isEmpty: Bool {
        self.items.isEmpty
    }

    /// All pending scrobble tracks (read-only).
    var pendingTracks: [ScrobbleTrack] {
        self.items
    }

    /// Creates a ScrobbleQueue with the given storage directory.
    /// - Parameter directory: Directory for queue file. Defaults to Application Support/Kaset.
    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        self.fileURL = dir.appendingPathComponent("scrobble-queue.json")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Load existing queue from disk
        self.loadFromDisk()
    }

    // MARK: - Queue Operations

    /// Adds a track to the end of the queue and persists to disk.
    func enqueue(_ track: ScrobbleTrack) {
        self.items.append(track)
        self.saveToDisk()
        self.logger.debug("Enqueued scrobble: \(track.title) by \(track.artist) (queue size: \(self.items.count))")
    }

    /// Returns up to `limit` tracks from the front of the queue without removing them.
    /// Use `markCompleted(_:)` to remove after successful submission.
    func dequeue(limit: Int) -> [ScrobbleTrack] {
        Array(self.items.prefix(limit))
    }

    /// Removes successfully submitted tracks from the queue by their IDs.
    func markCompleted(_ trackIds: Set<UUID>) {
        let beforeCount = self.items.count
        self.items.removeAll { trackIds.contains($0.id) }
        let removedCount = beforeCount - self.items.count
        if removedCount > 0 {
            self.saveToDisk()
            self.logger.debug("Marked \(removedCount) scrobbles as completed (queue size: \(self.items.count))")
        }
    }

    /// Removes scrobbles older than `maxAge` (14 days).
    /// Returns the number of pruned items.
    @discardableResult
    func pruneExpired() -> Int {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        let beforeCount = self.items.count
        self.items.removeAll { $0.timestamp < cutoff }
        let prunedCount = beforeCount - self.items.count
        if prunedCount > 0 {
            self.saveToDisk()
            self.logger.info("Pruned \(prunedCount) expired scrobbles (queue size: \(self.items.count))")
        }
        return prunedCount
    }

    /// Removes all items from the queue.
    func clear() {
        self.items.removeAll()
        self.saveToDisk()
        self.logger.info("Queue cleared")
    }

    // MARK: - Persistence

    /// Saves the current queue to disk.
    func save() {
        self.saveToDisk()
    }

    /// Loads the queue from disk (called during init).
    func load() {
        self.loadFromDisk()
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(self.items)
            try data.write(to: self.fileURL, options: .atomic)
        } catch {
            self.logger.error("Failed to save scrobble queue: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: self.fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            self.items = try decoder.decode([ScrobbleTrack].self, from: data)
            self.logger.info("Loaded \(self.items.count) pending scrobbles from disk")
        } catch {
            self.logger.error("Failed to load scrobble queue: \(error.localizedDescription)")
            self.items = []
        }
    }

    // MARK: - Default Directory

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Kaset")
    }
}
