import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct ScrobblingCoordinatorMixPlaybackTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrobblingCoordinatorMixPlaybackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanupDirectory(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeWatchNextData(chapters: [YouTubeChapter]) -> WatchNextData {
        WatchNextData(
            videoTitle: "Long Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            chapters: chapters
        )
    }

    private func makeMixChapters(videoId: String = "mix1", count: Int = 3) -> [YouTubeChapter] {
        (0 ..< count).map { index in
            YouTubeChapter(
                videoId: videoId,
                title: "Artist \(index) - Track \(index)",
                startTime: TimeInterval(index) * 600,
                endTime: TimeInterval(index + 1) * 600,
                timeText: nil,
                thumbnailURL: nil
            )
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A stale mix fetch does not block the next track's fetch")
    func staleMixFetchDoesNotBlockNextTrack() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let firstRequestGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: self.makeMixChapters())
        mockYouTube.beforeWatchNextReturn = { videoId in
            if videoId == "mix1" {
                await firstRequestGate.wait()
            }
        }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        defer { settings.setServiceEnabled("Mock", false) }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "First Mix", duration: 3600)
        playerService.state = .playing
        playerService.duration = 3600
        playerService.setPlaybackStateVideoId("mix1")

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: ScrobbleQueue(directory: dir),
            mixTracklistParser: parser
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        #expect(mockYouTube.requestedWatchNextVideoIds == ["mix1"])

        // The first request remains suspended while playback moves to another long mix. The new
        // track must start its own parse immediately rather than waiting for the stale request.
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 3600,
            observedVideoId: "mix2"
        )
        playerService.currentTrack = TestFixtures.makeSong(id: "mix2", title: "Second Mix", duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 2 }

        #expect(mockYouTube.requestedWatchNextVideoIds == ["mix1", "mix2"])
        await firstRequestGate.open()
    }

    @Test("Forward seeks preserve a scrobbled mix latch while backward replays start fresh")
    func mixSeekAndReplayLatches() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let chapters = [
            YouTubeChapter(videoId: "mix1", title: "Artist 0 - Track 0", startTime: 0, endTime: 100, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix1", title: "Artist 1 - Track 1", startTime: 100, endTime: 610, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix1", title: "Artist 2 - Track 2", startTime: 610, endTime: nil, timeText: nil, thumbnailURL: nil),
        ]
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: chapters)
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

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
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: 700)
        playerService.state = .playing
        playerService.duration = 700
        playerService.setPlaybackStateVideoId("mix1")
        let queue = ScrobbleQueue(directory: dir)

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            mixTracklistParser: parser
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        playerService.progress = 0.1
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }
        playerService.progress = 1.1
        await self.waitUntil { queue.count == 1 }
        #expect(coordinator.mixEntryScrobbledIds.count == 1)
        let firstTimestamp = queue.pendingTracks.first?.timestamp

        // Leaving the entry and seeking back into its middle preserves the original latch.
        playerService.progress = 110
        await self.waitUntil { mockService.nowPlayingTracks.count == 2 }
        #expect(coordinator.mixEntryScrobbledIds.count == 1)
        #expect(coordinator.trackTracker?.hasScrobbled == false)
        playerService.progress = 50
        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.mixEntryScrobbledIds.count == 1)
        playerService.progress = 51
        try await Task.sleep(for: .milliseconds(100))
        #expect(queue.count == 1)
        #expect(mockService.nowPlayingTracks.count == 3)

        // A forward seek within the already-scrobbled entry must not re-arm it.
        playerService.progress = 70
        try await Task.sleep(for: .milliseconds(20))
        playerService.progress = 71
        try await Task.sleep(for: .milliseconds(100))
        #expect(queue.count == 1)
        #expect(mockService.nowPlayingTracks.count == 3)

        // An ordinary rewind within the entry is still the same play and must preserve latches.
        playerService.progress = 40
        try await Task.sleep(for: .milliseconds(20))
        playerService.progress = 41
        try await Task.sleep(for: .milliseconds(100))
        #expect(queue.count == 1)
        #expect(mockService.nowPlayingTracks.count == 3)

        // Restarting near the entry's beginning is a real replay: it gets a fresh tracker/timestamp
        // and may scrobble the entry once more after meeting the threshold again.
        playerService.progress = 1
        try await Task.sleep(for: .milliseconds(20))
        playerService.progress = 2
        await self.waitUntil { queue.count == 2 }

        #expect(mockService.nowPlayingTracks.count == 4)
        #expect(queue.pendingTracks.last?.timestamp != firstTimestamp)
    }

    @Test("A seek before parsing completes does not seed pre-seek playback")
    func pendingSeekDoesNotSeedOldCredit() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let chapters = [
            YouTubeChapter(videoId: "mix1", title: "Artist 0 - Track 0", startTime: 0, endTime: 100, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix1", title: "Artist 1 - Track 1", startTime: 100, endTime: 200, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix1", title: "Artist 2 - Track 2", startTime: 200, endTime: 300, timeText: nil, thumbnailURL: nil),
        ]
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: chapters)
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.015)
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: 700)
        playerService.state = .playing
        playerService.duration = 700
        playerService.setPlaybackStateVideoId("mix1")
        let queue = ScrobbleQueue(directory: dir)

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            mixTracklistParser: parser
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        playerService.progress = 0.6
        try await Task.sleep(for: .milliseconds(20))
        playerService.progress = 50
        try await Task.sleep(for: .milliseconds(20))
        await parseGate.open()
        await self.waitUntil {
            if case .mix = coordinator.mixDetectionState {
                return true
            }
            return false
        }

        playerService.progress = 51
        try await Task.sleep(for: .milliseconds(50))
        #expect(queue.isEmpty)

        playerService.progress = 52
        await self.waitUntil { queue.count == 1 }
        #expect(queue.pendingTracks.first?.title == "Track 0")
    }

    @Test("Final mix entry metadata uses the parent video duration when its end is missing")
    func finalMixEntryDurationUsesVideoDuration() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let chapters = [
            YouTubeChapter(videoId: "mix1", title: "Artist 0 - Track 0", startTime: 0, endTime: 300, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix1", title: "Artist 1 - Track 1", startTime: 300, endTime: 610, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix1", title: "Artist 2 - Track 2", startTime: 610, endTime: nil, timeText: nil, thumbnailURL: nil),
        ]
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: chapters)
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        defer { settings.setServiceEnabled("Mock", false) }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 700,
            observedVideoId: "mix1"
        )

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: ScrobbleQueue(directory: dir),
            mixTracklistParser: parser
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        playerService.progress = 610.1
        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }

        #expect(mockService.nowPlayingTracks.first?.title == "Track 2")
        #expect(mockService.nowPlayingTracks.first?.duration == 90)
    }

    @Test("The final delta to an explicit chapter end is credited before a gap")
    func chapterEndDeltaIsCredited() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let chapters = [
            YouTubeChapter(videoId: "mix1", title: "Artist 0 - Track 0", startTime: 0, endTime: 100, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix1", title: "Artist 1 - Track 1", startTime: 120, endTime: 220, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix1", title: "Artist 2 - Track 2", startTime: 220, endTime: 320, timeText: nil, thumbnailURL: nil),
        ]
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: chapters)
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.01)
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: 700)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 99,
            duration: 700,
            observedVideoId: "mix1"
        )
        let queue = ScrobbleQueue(directory: dir)
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            mixTracklistParser: parser
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }
        playerService.progress = 100
        await self.waitUntil { queue.count == 1 }

        #expect(queue.pendingTracks.first?.title == "Track 0")
    }

    @Test("A provisional short duration can grow before whole-track classification commits")
    func playerDurationGrowthBeforeConfirmation() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: self.makeMixChapters())
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Growing Mix", duration: 0)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 240,
            observedVideoId: "mix1"
        )

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: ScrobbleQueue(directory: dir),
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(100)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        try await Task.sleep(for: .milliseconds(20))
        #expect(mockService.nowPlayingTracks.isEmpty)

        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 2,
            duration: 3600,
            observedVideoId: "mix1"
        )
        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        await self.waitUntil { mockService.nowPlayingTracks.contains { $0.title == "Track 0" } }
        #expect(!mockService.nowPlayingTracks.contains { $0.title == "Growing Mix" })
    }

    @Test("Regular-track replays remain separate while mix parsing is pending")
    func pendingRegularTrackReplaysStaySeparate() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = .empty
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.001)
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "regular", title: "Long Regular", duration: 700)
        playerService.state = .playing
        playerService.duration = 700
        playerService.setPlaybackStateVideoId("regular")
        let queue = ScrobbleQueue(directory: dir)

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            mixTracklistParser: parser
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        playerService.progress = 1
        try await Task.sleep(for: .milliseconds(20))
        playerService.progress = 10
        try await Task.sleep(for: .milliseconds(20))
        playerService.progress = 0
        try await Task.sleep(for: .milliseconds(20))
        playerService.progress = 1
        try await Task.sleep(for: .milliseconds(20))

        await parseGate.open()
        await self.waitUntil { queue.count == 2 }

        #expect(queue.pendingTracks.allSatisfy { $0.title == "Long Regular" })
        #expect(queue.pendingTracks[0].timestamp != queue.pendingTracks[1].timestamp)
    }

    @Test("Pending whole-track thresholds are revalidated when duration grows")
    func pendingWholeTrackThresholdRevalidatesDuration() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = .empty
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.001)
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "regular", title: "Long Regular", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 700,
            observedVideoId: "regular"
        )
        let queue = ScrobbleQueue(directory: dir)
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            mixTracklistParser: parser
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        playerService.progress = 1
        try await Task.sleep(for: .milliseconds(20))
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 3600,
            observedVideoId: "regular"
        )
        await parseGate.open()
        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(queue.isEmpty)
        #expect(coordinator.trackTracker?.hasScrobbled == false)
    }

    @Test("Duration growth clears a provisional latch before a rewind splits the play")
    func durationGrowthRevalidatesLatchBeforeReplayDetection() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = .empty
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.01)
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(
            id: "regular",
            title: "Growing Regular Track",
            duration: nil
        )
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 40,
            observedVideoId: "regular"
        )
        let queue = ScrobbleQueue(directory: dir)
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(20)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        for progress in 1 ... 6 {
            playerService.progress = TimeInterval(progress)
            try await Task.sleep(for: .milliseconds(10))
        }
        await self.waitUntil { coordinator.pendingWholeTrackPlays.count == 1 }

        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 700,
            observedVideoId: "regular"
        )
        await self.waitUntil {
            coordinator.pendingWholeTrackPlays.isEmpty
                && coordinator.trackTracker?.hasScrobbled == false
        }

        playerService.progress = 1
        try await Task.sleep(for: .milliseconds(10))
        playerService.progress = 2
        await self.waitUntil { coordinator.pendingWholeTrackPlays.count == 1 }

        await parseGate.open()
        await self.waitUntil { queue.count == 1 }

        #expect(queue.pendingTracks.first?.title == "Growing Regular Track")
    }

    @Test("Termination uses a bounded fallback when mix parsing stalls")
    func terminationTimeoutPersistsFallback() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = .empty
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.001)
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "regular", title: "Long Regular", duration: 700)
        playerService.state = .playing
        playerService.duration = 700
        playerService.setPlaybackStateVideoId("regular")
        let queue = ScrobbleQueue(directory: dir)
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            mixTracklistParser: parser
        )
        coordinator.startMonitoring()

        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        playerService.progress = 1
        try await Task.sleep(for: .milliseconds(20))
        await coordinator.prepareForTermination(timeout: .milliseconds(20))

        #expect(queue.count == 1)
        #expect(queue.pendingTracks.first?.title == "Long Regular")
        await parseGate.open()
    }
}
