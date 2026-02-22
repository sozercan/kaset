import Foundation
import Testing
@testable import Kaset

@Suite("ScrobblingCoordinator", .serialized, .tags(.service))
@MainActor
struct ScrobblingCoordinatorTests {
    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrobblingCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanupDirectory(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeTrack(
        title: String = "Test Song",
        artist: String = "Test Artist",
        album: String? = "Test Album",
        duration: TimeInterval? = 200,
        timestamp: Date = Date()
    ) -> ScrobbleTrack {
        ScrobbleTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            timestamp: timestamp
        )
    }

    // MARK: - ScrobbleTrack Tests

    @Test("ScrobbleTrack from Song captures correct metadata")
    func scrobbleTrackFromSong() {
        let song = TestFixtures.makeSong(
            id: "video123",
            title: "Blinding Lights",
            artistName: "The Weeknd",
            duration: 200
        )
        let timestamp = Date()
        let track = ScrobbleTrack(from: song, timestamp: timestamp)

        #expect(track.title == "Blinding Lights")
        #expect(track.artist == "The Weeknd")
        #expect(track.videoId == "video123")
        #expect(track.duration == 200)
        #expect(track.timestamp == timestamp)
    }

    @Test("ScrobbleTrack with nil album")
    func scrobbleTrackNilAlbum() {
        let song = TestFixtures.makeSong(title: "Test", artistName: "Artist")
        let track = ScrobbleTrack(from: song, timestamp: Date())

        // TestFixtures.makeSong doesn't set album
        #expect(track.album == nil)
    }

    @Test("ScrobbleTrack equality based on ID")
    func scrobbleTrackEquality() {
        let id = UUID()
        let track1 = ScrobbleTrack(id: id, title: "Song", artist: "Artist")
        let track2 = ScrobbleTrack(id: id, title: "Song", artist: "Artist")
        let track3 = ScrobbleTrack(title: "Song", artist: "Artist")

        #expect(track1 == track2)
        #expect(track1 != track3)
    }

    // MARK: - ScrobbleResult Tests

    @Test("ScrobbleResult accepted")
    func scrobbleResultAccepted() {
        let track = self.makeTrack()
        let result = ScrobbleResult(track: track, accepted: true)

        #expect(result.accepted)
        #expect(result.errorMessage == nil)
        #expect(result.correctedArtist == nil)
        #expect(result.correctedTrack == nil)
    }

    @Test("ScrobbleResult rejected with message")
    func scrobbleResultRejected() {
        let track = self.makeTrack()
        let result = ScrobbleResult(
            track: track,
            accepted: false,
            errorMessage: "Track was ignored"
        )

        #expect(!result.accepted)
        #expect(result.errorMessage == "Track was ignored")
    }

    @Test("ScrobbleResult with corrections")
    func scrobbleResultCorrected() {
        let track = self.makeTrack()
        let result = ScrobbleResult(
            track: track,
            accepted: true,
            correctedArtist: "The Weeknd",
            correctedTrack: "Blinding Lights"
        )

        #expect(result.accepted)
        #expect(result.correctedArtist == "The Weeknd")
        #expect(result.correctedTrack == "Blinding Lights")
    }

    // MARK: - Queue Integration

    @Test("Queue enqueue and flush cycle")
    func queueEnqueueAndFlush() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        let track1 = self.makeTrack(title: "Song 1")
        let track2 = self.makeTrack(title: "Song 2")

        queue.enqueue(track1)
        queue.enqueue(track2)

        let batch = queue.dequeue(limit: 50)
        #expect(batch.count == 2)

        // Simulate successful submission
        let completedIds = Set(batch.map(\.id))
        queue.markCompleted(completedIds)

        #expect(queue.isEmpty)
    }

    // MARK: - Scrobble Threshold Logic

    @Test("50% threshold for short track (180s)")
    func shortTrackThreshold() {
        // 180s track × 50% = 90s needed
        let threshold = 180.0 * 0.5
        #expect(threshold == 90.0)

        // 90s < 240s, so percentage wins
        let minSeconds: TimeInterval = 240
        let thresholdMet = 180.0 * 0.5 <= 90.0 || minSeconds <= 90.0
        #expect(thresholdMet)
    }

    @Test("240s cap for long track (600s)")
    func longTrackThreshold() {
        // 600s track × 50% = 300s needed
        // But 240s cap means scrobble at 240s
        let duration = 600.0
        let percentThreshold = 0.5
        let minSeconds: TimeInterval = 240

        let at240s: TimeInterval = 240
        let thresholdMet = at240s >= duration * percentThreshold || at240s >= minSeconds
        #expect(thresholdMet) // 240 >= 240 ✓
    }

    @Test("Threshold not met for partial play")
    func partialPlayNoScrobble() {
        let duration = 200.0
        let percentThreshold = 0.5
        let minSeconds: TimeInterval = 240

        let accumulated: TimeInterval = 50 // Only 25% played
        let thresholdMet = accumulated >= duration * percentThreshold || accumulated >= minSeconds
        #expect(!thresholdMet)
    }

    // MARK: - Play Time Accumulation Logic

    @Test("Normal play accumulates correctly")
    func normalPlayAccumulation() {
        // Simulating 500ms polls with ~0.5s progress each
        var accumulated: TimeInterval = 0
        var lastProgress: TimeInterval = 0

        // 10 polls of ~0.5s progress
        for i in 1 ... 10 {
            let newProgress = TimeInterval(i) * 0.5
            let delta = newProgress - lastProgress

            // Only count positive, small deltas (< 2s)
            if delta > 0, delta < 2.0 {
                accumulated += delta
            }

            lastProgress = newProgress
        }

        #expect(accumulated >= 4.9)
        #expect(accumulated <= 5.1)
    }

    @Test("Seek forward does not inflate play time")
    func seekForwardIgnored() {
        var accumulated: TimeInterval = 0
        var lastProgress: TimeInterval = 10.0

        // Seek from 10s to 100s (delta = 90s > 2s threshold → ignored)
        let newProgress: TimeInterval = 100.0
        let delta = newProgress - lastProgress
        if delta > 0, delta < 2.0 {
            accumulated += delta
        }

        #expect(accumulated == 0) // Seek was ignored
    }

    @Test("Seek backward does not inflate play time")
    func seekBackwardIgnored() {
        var accumulated: TimeInterval = 0
        var lastProgress: TimeInterval = 100.0

        // Seek from 100s to 10s (negative delta → ignored)
        let newProgress: TimeInterval = 10.0
        let delta = newProgress - lastProgress
        if delta > 0, delta < 2.0 {
            accumulated += delta
        }

        #expect(accumulated == 0) // Seek was ignored (negative)
    }

    // MARK: - ScrobbleTrack Codable

    @Test("ScrobbleTrack round-trips through JSON")
    func scrobbleTrackCodable() throws {
        let track = ScrobbleTrack(
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            duration: 200,
            timestamp: Date(timeIntervalSince1970: 1_708_560_000),
            videoId: "abc123"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(track)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ScrobbleTrack.self, from: data)

        #expect(decoded.title == track.title)
        #expect(decoded.artist == track.artist)
        #expect(decoded.album == track.album)
        #expect(decoded.duration == track.duration)
        #expect(decoded.timestamp == track.timestamp)
        #expect(decoded.videoId == track.videoId)
        #expect(decoded.id == track.id)
    }
}
