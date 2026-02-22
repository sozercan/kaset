import Foundation
import Testing
@testable import Kaset

@Suite("ScrobbleQueue", .serialized, .tags(.service))
@MainActor
struct ScrobbleQueueTests {
    /// Creates a temporary directory for queue file storage during tests.
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrobbleQueueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Cleans up a temporary directory after test use.
    private func cleanupDirectory(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Creates a test ScrobbleTrack with sensible defaults.
    private func makeTrack(
        title: String = "Test Song",
        artist: String = "Test Artist",
        album: String? = "Test Album",
        duration: TimeInterval? = 200,
        timestamp: Date = Date(),
        videoId: String? = "test-video-id"
    ) -> ScrobbleTrack {
        ScrobbleTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            timestamp: timestamp,
            videoId: videoId
        )
    }

    // MARK: - Basic Operations

    @Test("Empty queue has zero count")
    func emptyQueue() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        #expect(queue.isEmpty)
        #expect(queue.isEmpty)
        #expect(queue.pendingTracks.isEmpty)
    }

    @Test("Enqueue adds track to queue")
    func enqueueAddsTrack() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        let track = self.makeTrack()

        queue.enqueue(track)

        #expect(queue.count == 1)
        #expect(!queue.isEmpty)
        #expect(queue.pendingTracks.first?.title == "Test Song")
    }

    @Test("Enqueue multiple tracks preserves order")
    func enqueueMultiplePreservesOrder() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        let track1 = self.makeTrack(title: "Song 1")
        let track2 = self.makeTrack(title: "Song 2")
        let track3 = self.makeTrack(title: "Song 3")

        queue.enqueue(track1)
        queue.enqueue(track2)
        queue.enqueue(track3)

        #expect(queue.count == 3)
        #expect(queue.pendingTracks[0].title == "Song 1")
        #expect(queue.pendingTracks[1].title == "Song 2")
        #expect(queue.pendingTracks[2].title == "Song 3")
    }

    // MARK: - Dequeue

    @Test("Dequeue returns items without removing them")
    func dequeueDoesNotRemove() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        queue.enqueue(self.makeTrack(title: "Song 1"))
        queue.enqueue(self.makeTrack(title: "Song 2"))

        let batch = queue.dequeue(limit: 1)

        #expect(batch.count == 1)
        #expect(batch.first?.title == "Song 1")
        #expect(queue.count == 2) // Not removed
    }

    @Test("Dequeue respects limit")
    func dequeueRespectsLimit() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        for i in 0 ..< 10 {
            queue.enqueue(self.makeTrack(title: "Song \(i)"))
        }

        let batch = queue.dequeue(limit: 3)
        #expect(batch.count == 3)
        #expect(queue.count == 10)
    }

    @Test("Dequeue with limit larger than queue returns all items")
    func dequeueLargerThanQueue() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        queue.enqueue(self.makeTrack(title: "Song 1"))
        queue.enqueue(self.makeTrack(title: "Song 2"))

        let batch = queue.dequeue(limit: 50)
        #expect(batch.count == 2)
    }

    // MARK: - Mark Completed

    @Test("MarkCompleted removes specified tracks")
    func markCompletedRemovesTracks() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        let track1 = self.makeTrack(title: "Song 1")
        let track2 = self.makeTrack(title: "Song 2")
        let track3 = self.makeTrack(title: "Song 3")

        queue.enqueue(track1)
        queue.enqueue(track2)
        queue.enqueue(track3)

        queue.markCompleted(Set([track1.id, track3.id]))

        #expect(queue.count == 1)
        #expect(queue.pendingTracks.first?.title == "Song 2")
    }

    @Test("MarkCompleted with unknown IDs does nothing")
    func markCompletedUnknownIds() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        queue.enqueue(self.makeTrack())

        queue.markCompleted(Set([UUID()]))

        #expect(queue.count == 1)
    }

    // MARK: - Persistence

    @Test("Queue persists across instances")
    func persistenceRoundTrip() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        // Write
        let queue1 = ScrobbleQueue(directory: dir)
        let track = self.makeTrack(title: "Persisted Song", artist: "Persisted Artist", album: "Persisted Album")
        queue1.enqueue(track)

        // Read in new instance
        let queue2 = ScrobbleQueue(directory: dir)

        #expect(queue2.count == 1)
        #expect(queue2.pendingTracks.first?.title == "Persisted Song")
        #expect(queue2.pendingTracks.first?.artist == "Persisted Artist")
        #expect(queue2.pendingTracks.first?.album == "Persisted Album")
        #expect(queue2.pendingTracks.first?.id == track.id)
    }

    @Test("Queue preserves timestamp across persistence")
    func timestampPersistence() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let timestamp = Date(timeIntervalSince1970: 1_708_560_000)
        let track = self.makeTrack(timestamp: timestamp)

        let queue1 = ScrobbleQueue(directory: dir)
        queue1.enqueue(track)

        let queue2 = ScrobbleQueue(directory: dir)
        #expect(queue2.pendingTracks.first?.timestamp == timestamp)
    }

    // MARK: - Pruning

    @Test("PruneExpired removes scrobbles older than 14 days")
    func pruneExpiredTracks() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)

        // Add an old track (15 days ago)
        let oldTrack = self.makeTrack(
            title: "Old Song",
            timestamp: Date().addingTimeInterval(-15 * 24 * 60 * 60)
        )
        queue.enqueue(oldTrack)

        // Add a recent track
        let recentTrack = self.makeTrack(title: "Recent Song", timestamp: Date())
        queue.enqueue(recentTrack)

        let pruned = queue.pruneExpired()

        #expect(pruned == 1)
        #expect(queue.count == 1)
        #expect(queue.pendingTracks.first?.title == "Recent Song")
    }

    @Test("PruneExpired keeps tracks within 14 days")
    func pruneKeepsRecentTracks() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)

        // Add a track from 13 days ago (should survive)
        let track = self.makeTrack(
            title: "Almost Expired",
            timestamp: Date().addingTimeInterval(-13 * 24 * 60 * 60)
        )
        queue.enqueue(track)

        let pruned = queue.pruneExpired()

        #expect(pruned == 0)
        #expect(queue.count == 1)
    }

    @Test("PruneExpired returns zero when nothing to prune")
    func pruneEmptyQueue() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        let pruned = queue.pruneExpired()
        #expect(pruned == 0)
    }

    // MARK: - Clear

    @Test("Clear removes all items")
    func clearRemovesAll() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        for i in 0 ..< 5 {
            queue.enqueue(self.makeTrack(title: "Song \(i)"))
        }

        queue.clear()

        #expect(queue.isEmpty)
        #expect(queue.isEmpty)
    }

    @Test("Clear persists empty state")
    func clearPersistsEmptyState() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue1 = ScrobbleQueue(directory: dir)
        queue1.enqueue(self.makeTrack())
        queue1.clear()

        let queue2 = ScrobbleQueue(directory: dir)
        #expect(queue2.isEmpty)
    }

    // MARK: - ScrobbleTrack from Song

    @Test("ScrobbleTrack initializes from Song correctly")
    func scrobbleTrackFromSong() {
        let song = TestFixtures.makeSong(
            id: "abc123",
            title: "Blinding Lights",
            artistName: "The Weeknd",
            duration: 200
        )
        let timestamp = Date()
        let track = ScrobbleTrack(from: song, timestamp: timestamp)

        #expect(track.title == "Blinding Lights")
        #expect(track.artist == "The Weeknd")
        #expect(track.duration == 200)
        #expect(track.videoId == "abc123")
        #expect(track.timestamp == timestamp)
    }

    // MARK: - Edge Cases

    @Test("Queue handles missing file gracefully")
    func missingFileGraceful() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        // Queue should start empty when no file exists
        let queue = ScrobbleQueue(directory: dir)
        #expect(queue.isEmpty)
    }

    @Test("Queue handles corrupted file gracefully")
    func corruptedFileGraceful() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        // Write corrupt data
        let fileURL = dir.appendingPathComponent("scrobble-queue.json")
        try Data("not valid json {{[".utf8).write(to: fileURL)

        // Queue should handle gracefully and start empty
        let queue = ScrobbleQueue(directory: dir)
        #expect(queue.isEmpty)
    }
}
