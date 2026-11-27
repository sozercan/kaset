import Foundation

@MainActor
final class ScrobbleQueue {
    private var items: [ScrobbleTrack] = []
    private let fileURL: URL
    private let logger = DiagnosticsLogger.scrobbling

    static let maxAge: TimeInterval = 14 * 24 * 60 * 60

    var count: Int {
        self.items.count
    }

    var isEmpty: Bool {
        self.items.isEmpty
    }

    var pendingTracks: [ScrobbleTrack] {
        self.items
    }

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        self.fileURL = dir.appendingPathComponent("scrobble-queue.json")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        self.loadFromDisk()
    }

    func enqueue(_ track: ScrobbleTrack) {
        self.items.append(track)
        self.saveToDisk()
        self.logger.debug("Enqueued scrobble: \(track.title) by \(track.artist) (queue size: \(self.items.count))")
    }

    func dequeue(limit: Int) -> [ScrobbleTrack] {
        Array(self.items.prefix(limit))
    }

    func markCompleted(_ trackIds: Set<UUID>) {
        let beforeCount = self.items.count
        self.items.removeAll { trackIds.contains($0.id) }
        let removedCount = beforeCount - self.items.count
        if removedCount > 0 {
            self.saveToDisk()
            self.logger.debug("Marked \(removedCount) scrobbles as completed (queue size: \(self.items.count))")
        }
    }

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

    func clear() {
        self.items.removeAll()
        self.saveToDisk()
        self.logger.info("Queue cleared")
    }

    func save() {
        self.saveToDisk()
    }

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

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Kaset")
    }
}
