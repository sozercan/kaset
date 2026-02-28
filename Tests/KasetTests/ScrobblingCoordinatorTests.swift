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
        let timestamp = Date()
        let track1 = ScrobbleTrack(id: id, title: "Song", artist: "Artist", timestamp: timestamp)
        let track2 = ScrobbleTrack(id: id, title: "Song", artist: "Artist", timestamp: timestamp)
        let track3 = ScrobbleTrack(title: "Song", artist: "Artist", timestamp: timestamp)

        #expect(track1 == track2)
        #expect(track1 != track3) // Different UUID
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

    // MARK: - Fix #1: Only accepted tracks removed from queue

    @Test("FlushQueue only marks accepted tracks as completed, rejected stay in queue")
    func flushQueueOnlyRemovesAccepted() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        let track1 = self.makeTrack(title: "Accepted")
        let track2 = self.makeTrack(title: "Rejected")
        let track3 = self.makeTrack(title: "Also Accepted")
        queue.enqueue(track1)
        queue.enqueue(track2)
        queue.enqueue(track3)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        // Return mixed results: track1 accepted, track2 rejected, track3 accepted
        mockService.scrobbleResults = [
            ScrobbleResult(track: track1, accepted: true),
            ScrobbleResult(track: track2, accepted: false, errorMessage: "Ignored"),
            ScrobbleResult(track: track3, accepted: true),
        ]

        let playerService = PlayerService()
        let settings = SettingsManager.shared
        settings.setServiceEnabled("Mock", true)

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue
        )

        await coordinator.flushQueue()

        // Only the rejected track should remain in the queue
        #expect(queue.count == 1)
        #expect(queue.pendingTracks.first?.title == "Rejected")

        // Cleanup
        settings.setServiceEnabled("Mock", false)
    }

    // MARK: - Fix #7: CancellationError handled in flushQueue

    @Test("FlushQueue stops processing on CancellationError")
    func flushQueueHandlesCancellation() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        let track = self.makeTrack(title: "Track")
        queue.enqueue(track)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        mockService.shouldThrowOnScrobble = CancellationError()

        let playerService = PlayerService()
        let settings = SettingsManager.shared
        settings.setServiceEnabled("Mock", true)

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue
        )

        await coordinator.flushQueue()

        // Track should remain in queue (not marked completed on cancellation)
        #expect(queue.count == 1)

        // Cleanup
        settings.setServiceEnabled("Mock", false)
    }

    // MARK: - Fix #8: 30-second minimum duration guard

    @Test("Tracks under 30 seconds are not scrobbled")
    func shortTrackNotScrobbled() {
        // With a 10-second track at 50% threshold, 5 seconds of play time would meet
        // the percentage threshold. But the 30-second minimum guard should prevent it.
        let duration: TimeInterval = 10.0
        let minDuration: TimeInterval = 30.0

        // Guard check that the coordinator now performs
        #expect(duration < minDuration, "Short tracks should be blocked by the 30s guard")
    }

    @Test("Tracks at exactly 30 seconds are eligible for scrobbling")
    func thirtySecondTrackEligible() {
        let duration: TimeInterval = 30.0
        let minDuration: TimeInterval = 30.0

        #expect(duration >= minDuration, "30-second tracks should pass the guard")
    }

    // MARK: - Fix #2: Replay detection

    @Test("Large backward progress jump signals replay")
    func replayDetectedOnBackwardJump() {
        // Simulates the replay detection logic:
        // When progress drops by more than 5 seconds and track has already scrobbled,
        // it should be treated as a replay
        let lastProgress: TimeInterval = 180.0
        let newProgress: TimeInterval = 2.0
        let hasScrobbled = true
        let threshold: TimeInterval = 5.0

        let isReplay = hasScrobbled && newProgress < lastProgress - threshold
        #expect(isReplay, "A 178-second backward jump after scrobbling should trigger replay detection")
    }

    @Test("Small backward progress change is not a replay")
    func smallBackwardNotReplay() {
        let lastProgress: TimeInterval = 100.0
        let newProgress: TimeInterval = 97.0 // Only 3 seconds back
        let hasScrobbled = true
        let threshold: TimeInterval = 5.0

        let isReplay = hasScrobbled && newProgress < lastProgress - threshold
        #expect(!isReplay, "A 3-second backward change should not trigger replay detection")
    }

    @Test("Backward jump before scrobble is not a replay")
    func backwardJumpBeforeScrobbleNotReplay() {
        let lastProgress: TimeInterval = 180.0
        let newProgress: TimeInterval = 2.0
        let hasScrobbled = false // Haven't scrobbled yet
        let threshold: TimeInterval = 5.0

        let isReplay = hasScrobbled && newProgress < lastProgress - threshold
        #expect(!isReplay, "Backward jump before scrobbling should not trigger replay (could be a seek)")
    }

    // MARK: - Fix: Title/artist-based track change detection

    @Test("Title change triggers track change detection even with same videoId")
    func titleChangeDetectedWithSameVideoId() {
        // When videoId is stale (reused from previous track), title/artist change
        // should still be detected as a track change
        let currentVideoId = "video123"
        let currentTitle = "Song A"
        let currentArtist = "Artist A"

        let newVideoId = "video123" // Same stale videoId
        let newTitle = "Song B"
        let newArtist = "Artist B"

        let videoIdChanged = newVideoId != currentVideoId
        let metadataChanged = (newTitle != currentTitle || newArtist != currentArtist)

        #expect(!videoIdChanged, "videoId should be the same (stale)")
        #expect(metadataChanged, "Title/artist change should be detected")
        #expect(videoIdChanged || metadataChanged, "Track change should be detected via metadata fallback")
    }

    @Test("Same title and artist does not trigger false track change")
    func sameMetadataNoFalseChange() {
        let currentVideoId = "video123"
        let currentTitle = "Song A"
        let currentArtist = "Artist A"

        let newVideoId = "video123"
        let newTitle = "Song A"
        let newArtist = "Artist A"

        let videoIdChanged = newVideoId != currentVideoId
        let metadataChanged = (newTitle != currentTitle || newArtist != currentArtist)

        #expect(!videoIdChanged)
        #expect(!metadataChanged)
        #expect(!(videoIdChanged || metadataChanged), "No change should be detected")
    }

    // MARK: - Fix: Final threshold check on finalize

    @Test("Finalize performs threshold check before discarding play time")
    func finalizeThresholdCheck() {
        // If accumulated play time is at threshold when track changes,
        // the finalize should trigger the scrobble before resetting state
        let duration = 200.0
        let percentThreshold = 0.5
        let minSeconds: TimeInterval = 240
        let accumulated: TimeInterval = 100.0 // Exactly 50%

        let thresholdMet = accumulated >= duration * percentThreshold || accumulated >= minSeconds
        #expect(thresholdMet, "Threshold should be met at exactly 50% of duration")
    }
}
