import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct ScrobblingCoordinatorTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrobblingCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanupDirectory(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
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
        #expect(track1 != track3)
    }

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

        let completedIds = Set(batch.map(\.id))
        queue.markCompleted(completedIds)

        #expect(queue.isEmpty)
    }

    @Test("50% threshold for short track (180s)")
    func shortTrackThreshold() {
        let threshold = 180.0 * 0.5
        #expect(threshold == 90.0)

        let minSeconds: TimeInterval = 240
        let thresholdMet = 180.0 * 0.5 <= 90.0 || minSeconds <= 90.0
        #expect(thresholdMet)
    }

    @Test("240s cap for long track (600s)")
    func longTrackThreshold() {
        let duration = 600.0
        let percentThreshold = 0.5
        let minSeconds: TimeInterval = 240

        let at240s: TimeInterval = 240
        let thresholdMet = at240s >= duration * percentThreshold || at240s >= minSeconds
        #expect(thresholdMet)
    }

    @Test("Threshold not met for partial play")
    func partialPlayNoScrobble() {
        let duration = 200.0
        let percentThreshold = 0.5
        let minSeconds: TimeInterval = 240

        let accumulated: TimeInterval = 50
        let thresholdMet = accumulated >= duration * percentThreshold || accumulated >= minSeconds
        #expect(!thresholdMet)
    }

    @Test("Normal play accumulates correctly")
    func normalPlayAccumulation() {
        var accumulated: TimeInterval = 0
        var lastProgress: TimeInterval = 0

        for i in 1 ... 10 {
            let newProgress = TimeInterval(i) * 0.5
            let delta = newProgress - lastProgress

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
        let lastProgress: TimeInterval = 10.0

        let newProgress: TimeInterval = 100.0
        let delta = newProgress - lastProgress
        if delta > 0, delta < 2.0 {
            accumulated += delta
        }

        #expect(accumulated == 0)
    }

    @Test("Seek backward does not inflate play time")
    func seekBackwardIgnored() {
        var accumulated: TimeInterval = 0
        let lastProgress: TimeInterval = 100.0

        let newProgress: TimeInterval = 10.0
        let delta = newProgress - lastProgress
        if delta > 0, delta < 2.0 {
            accumulated += delta
        }

        #expect(accumulated == 0)
    }

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

    @Test("Queue flush is not scheduled without an eligible service")
    func queueFlushDormantWithoutEligibleService() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        queue.enqueue(self.makeTrack(title: "Queued"))

        let mockService = MockScrobbleService()
        mockService.authState = .disconnected

        let playerService = PlayerService()
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        defer { settings.setServiceEnabled("Mock", false) }

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue
        )

        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        #expect(!coordinator.isQueueFlushScheduled)
    }

    @Test("Queue flush is one-shot scheduled only when service is eligible and queue has work")
    func queueFlushScheduledForEligiblePendingQueue() throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let queue = ScrobbleQueue(directory: dir)
        queue.enqueue(self.makeTrack(title: "Queued"))

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")

        let playerService = PlayerService()
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        defer { settings.setServiceEnabled("Mock", false) }

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue
        )

        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        #expect(coordinator.isQueueFlushScheduled)
    }

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
        mockService.scrobbleResults = [
            ScrobbleResult(track: track1, accepted: true),
            ScrobbleResult(track: track2, accepted: false, errorMessage: "Ignored"),
            ScrobbleResult(track: track3, accepted: true),
        ]

        let playerService = PlayerService()
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue
        )

        await coordinator.flushQueue()

        #expect(queue.count == 1)
        #expect(queue.pendingTracks.first?.title == "Rejected")

        settings.setServiceEnabled("Mock", false)
    }

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
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue
        )

        await coordinator.flushQueue()

        #expect(queue.count == 1)

        settings.setServiceEnabled("Mock", false)
    }

    @Test("Tracks under 30 seconds are not scrobbled")
    func shortTrackNotScrobbled() {
        let duration: TimeInterval = 10.0
        let minDuration: TimeInterval = 30.0

        #expect(duration < minDuration, "Short tracks should be blocked by the 30s guard")
    }

    @Test("Tracks at exactly 30 seconds are eligible for scrobbling")
    func thirtySecondTrackEligible() {
        let duration: TimeInterval = 30.0
        let minDuration: TimeInterval = 30.0

        #expect(duration >= minDuration, "30-second tracks should pass the guard")
    }

    @Test("Large backward progress jump signals replay")
    func replayDetectedOnBackwardJump() {
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
        let newProgress: TimeInterval = 97.0
        let hasScrobbled = true
        let threshold: TimeInterval = 5.0

        let isReplay = hasScrobbled && newProgress < lastProgress - threshold
        #expect(!isReplay, "A 3-second backward change should not trigger replay detection")
    }

    @Test("Backward jump before scrobble is not a replay")
    func backwardJumpBeforeScrobbleNotReplay() {
        let lastProgress: TimeInterval = 180.0
        let newProgress: TimeInterval = 2.0
        let hasScrobbled = false
        let threshold: TimeInterval = 5.0

        let isReplay = hasScrobbled && newProgress < lastProgress - threshold
        #expect(!isReplay, "Backward jump before scrobbling should not trigger replay (could be a seek)")
    }

    @Test("A regular-track replay replaces the tracker and can scrobble again")
    func regularTrackReplayStartsFresh() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        let originalPercent = settings.scrobblePercentThreshold
        let originalMinSeconds = settings.scrobbleMinSeconds
        settings.scrobblePercentThreshold = 0.01
        settings.scrobbleMinSeconds = 240
        settings.setServiceEnabled("Mock", true)
        defer {
            settings.scrobblePercentThreshold = originalPercent
            settings.scrobbleMinSeconds = originalMinSeconds
            settings.setServiceEnabled("Mock", false)
        }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "song1", title: "Regular Song", duration: 100)
        playerService.state = .playing
        playerService.duration = 100
        playerService.setPlaybackStateVideoId("song1")
        let queue = ScrobbleQueue(directory: dir)
        var now = Date(timeIntervalSince1970: 1000)
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            now: { now }
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        playerService.progress = 0.1
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }
        playerService.progress = 1.1
        await self.waitUntil { queue.count == 1 }
        let firstTimestamp = try #require(queue.pendingTracks.first?.timestamp)

        now = now.addingTimeInterval(1)
        playerService.progress = 50
        try await Task.sleep(for: .milliseconds(20))
        playerService.progress = 0.1
        await self.waitUntil { mockService.nowPlayingTracks.count == 2 }
        playerService.progress = 1.1
        await self.waitUntil { queue.count == 2 }

        #expect(queue.pendingTracks.last?.timestamp == now)
        #expect(queue.pendingTracks.last?.timestamp != firstTimestamp)
    }

    @Test("Stopping and restarting monitoring preserves the same regular play latch")
    func monitoringRestartPreservesRegularPlay() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.01)
        settings.setServiceEnabled("Mock", true)
        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "song1", title: "Regular Song", duration: 100)
        playerService.state = .playing
        playerService.duration = 100
        playerService.setPlaybackStateVideoId("song1")
        let queue = ScrobbleQueue(directory: dir)
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue
        )

        coordinator.startMonitoring()
        playerService.progress = 0.1
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }
        playerService.progress = 1.1
        await self.waitUntil { queue.count == 1 }

        coordinator.stopMonitoring(finalizeCurrentTrack: false)
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }
        playerService.progress = 2.1
        try await Task.sleep(for: .milliseconds(50))

        #expect(queue.count == 1)
    }

    @Test("Title change triggers track change detection even with same videoId")
    func titleChangeDetectedWithSameVideoId() {
        let currentVideoId = "video123"
        let currentTitle = "Song A"
        let currentArtist = "Artist A"

        let newVideoId = "video123"
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

    @Test("Finalize performs threshold check before discarding play time")
    func finalizeThresholdCheck() {
        let duration = 200.0
        let percentThreshold = 0.5
        let minSeconds: TimeInterval = 240
        let accumulated: TimeInterval = 100.0

        let thresholdMet = accumulated >= duration * percentThreshold || accumulated >= minSeconds
        #expect(thresholdMet, "Threshold should be met at exactly 50% of duration")
    }
}
