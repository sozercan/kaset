import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct ScrobblingCoordinatorMixDurationResolutionTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrobblingCoordinatorMixDurationResolutionTests-\(UUID().uuidString)")
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

    private func makeMixChapters(
        videoId: String = "mix1",
        count: Int = 3,
        entryDuration: TimeInterval = 600
    ) -> [YouTubeChapter] {
        (0 ..< count).map { index in
            YouTubeChapter(
                videoId: videoId,
                title: "Artist \(index) - Track \(index)",
                startTime: TimeInterval(index) * entryDuration,
                endTime: TimeInterval(index + 1) * entryDuration,
                timeText: nil,
                thumbnailURL: nil
            )
        }
    }

    private func makeTracklist(
        videoId: String,
        entryDuration: TimeInterval
    ) -> MixTracklist {
        let entries = (0 ..< 3).map { index in
            MixTrackEntry(
                startTime: TimeInterval(index) * entryDuration,
                endTime: TimeInterval(index + 1) * entryDuration,
                title: "Track \(index)",
                artist: "Artist \(index)",
                source: .chapters
            )
        }
        return MixTracklist(videoId: videoId, entries: entries, source: .chapters)
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

    @Test("Pending whole-track scrobbles survive an awaiting-duration parse")
    func awaitingDurationPreservesPendingWholeTrackScrobble() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(
            chapters: self.makeMixChapters(videoId: "short1", entryDuration: 100)
        )
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.001)
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 240,
            observedVideoId: "short1"
        )
        let queue = ScrobbleQueue(directory: dir)
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(100)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        playerService.progress = 1
        await self.waitUntil { coordinator.pendingWholeTrackPlays.count == 1 }

        await parseGate.open()
        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }

        playerService.currentTrack = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: 240)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 2,
            duration: 240,
            observedVideoId: "short1"
        )
        await self.waitUntil { queue.count == 1 }

        #expect(queue.pendingTracks.first?.title == "Regular Song")
    }

    @Test("Exiting while duration is unconfirmed falls back to whole-track scrobbling")
    func awaitingDurationExitUsesWholeTrackFallback() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(
            chapters: self.makeMixChapters(videoId: "short1", entryDuration: 100)
        )
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.001)
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 240,
            observedVideoId: "short1"
        )
        let queue = ScrobbleQueue(directory: dir)
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(100)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        playerService.progress = 1
        await self.waitUntil { coordinator.pendingWholeTrackPlays.count == 1 }
        await parseGate.open()
        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }

        playerService.currentTrack = TestFixtures.makeSong(id: "next", title: "Next Song", duration: 200)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 200,
            observedVideoId: "next"
        )
        await self.waitUntil { queue.count == 1 }

        #expect(queue.pendingTracks.first?.title == "Regular Song")
        #expect(!queue.pendingTracks.contains { $0.title == "Track 0" })
    }

    @Test("Tracklist bounds confirm a mix without a parent duration")
    func tracklistBoundsResolveDurationlessMix() async throws {
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
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 0,
            observedVideoId: "mix1"
        )
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: ScrobbleQueue(directory: dir),
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(20)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        await self.waitUntil { mockService.nowPlayingTracks.contains { $0.title == "Track 0" } }

        #expect(mockService.nowPlayingTracks.contains { $0.title == "Track 0" })
        #expect(!mockService.nowPlayingTracks.contains { $0.title == "Long Mix" })
    }

    @Test("Restarting monitoring reschedules unknown-duration parsing")
    func monitoringRestartReschedulesDurationlessParse() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = .empty
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "unknown", title: "Unknown Duration", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 0,
            observedVideoId: "unknown"
        )

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: ScrobbleQueue(directory: dir),
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(40)
        )

        coordinator.startMonitoring()
        coordinator.stopMonitoring(finalizeCurrentTrack: false)
        try await Task.sleep(for: .milliseconds(60))
        #expect(mockYouTube.getWatchNextCallCount == 0)

        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }
        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }

        #expect(mockService.nowPlayingTracks.first?.title == "Unknown Duration")
    }

    @Test("Duration confirmation ignores a different player track")
    func durationConfirmationIgnoresDifferentPlayerTrack() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let playerService = PlayerService()
        let oldTrack = TestFixtures.makeSong(id: "old", title: "Old Track", duration: nil)
        playerService.currentTrack = oldTrack
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 0,
            observedVideoId: "old"
        )
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            services: [],
            queue: ScrobbleQueue(directory: dir),
            unknownDurationParseDelay: .milliseconds(20)
        )
        defer { coordinator.stopMonitoring() }
        coordinator.currentTrackVideoId = oldTrack.videoId
        coordinator.trackedSong = oldTrack
        coordinator.mixDetectionState = .awaitingDuration(
            self.makeTracklist(videoId: "old", entryDuration: 100)
        )
        coordinator.scheduleAwaitingDurationConfirmation(for: oldTrack)

        playerService.currentTrack = TestFixtures.makeSong(id: "next", title: "Next Track", duration: 240)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 240,
            observedVideoId: "next"
        )
        try await Task.sleep(for: .milliseconds(50))

        let stillAwaiting = if case .awaitingDuration = coordinator.mixDetectionState {
            true
        } else {
            false
        }
        #expect(stillAwaiting)
        #expect(!coordinator.durationConfirmationCompleted)
    }

    @Test("A short duration arriving after the grace period resolves regular playback")
    func lateShortDurationAfterGraceResolvesNotMix() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(
            chapters: self.makeMixChapters(videoId: "short1", entryDuration: 100)
        )
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 0,
            observedVideoId: "short1"
        )
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: ScrobbleQueue(directory: dir),
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(20)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        await self.waitUntil { coordinator.durationConfirmationCompleted }
        await self.waitUntil { mockService.nowPlayingTracks.first?.title == "Regular Song" }
        #expect(mockService.nowPlayingTracks.first?.title == "Regular Song")

        playerService.currentTrack = TestFixtures.makeSong(
            id: "short1",
            title: "Regular Song",
            duration: 240
        )
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 240,
            observedVideoId: "short1"
        )
        await self.waitUntil {
            if case .notMix = coordinator.mixDetectionState {
                true
            } else {
                false
            }
        }

        #expect(mockService.nowPlayingTracks.first?.title == "Regular Song")
        #expect(mockService.nowPlayingTracks.count == 1)
    }

    @Test("Tracklist bounds outrank a provisional short player duration")
    func tracklistBoundsOverrideProvisionalShortDuration() async throws {
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
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 240,
            observedVideoId: "mix1"
        )
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: ScrobbleQueue(directory: dir),
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(20)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockService.nowPlayingTracks.contains { $0.title == "Track 0" } }

        #expect(mockService.nowPlayingTracks.contains { $0.title == "Track 0" })
        #expect(!mockService.nowPlayingTracks.contains { $0.title == "Long Mix" })
    }

    @Test("Deferred finalization uses the same tracklist-bound precedence")
    func deferredFinalizationUsesTracklistBoundPrecedence() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: self.makeMixChapters())
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.001)
        settings.setServiceEnabled("Mock", true)

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Whole Mix", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 240,
            observedVideoId: "mix1"
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
        playerService.progress = 1
        await self.waitUntil { coordinator.pendingWholeTrackPlays.count == 1 }
        playerService.currentTrack = TestFixtures.makeSong(id: "next", title: "Next Song", duration: 200)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 200,
            observedVideoId: "next"
        )

        await parseGate.open()
        await self.waitUntil { queue.count == 1 }

        #expect(queue.pendingTracks.first?.title == "Track 0")
        #expect(!queue.pendingTracks.contains { $0.title == "Whole Mix" })
    }

    @Test("A replay snapshots the completed provisional play before replacement")
    func replaySnapshotsCompletedPendingWholeTrackPlay() async throws {
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
            title: "Regular Mix Candidate",
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
        for progress in 1 ... 9 {
            playerService.progress = TimeInterval(progress)
            try await Task.sleep(for: .milliseconds(10))
        }
        await self.waitUntil { coordinator.pendingWholeTrackPlays.count == 1 }
        #expect((coordinator.trackTracker?.accumulatedPlayTime ?? 0) >= 8)
        let completedPlayTimestamp = coordinator.pendingWholeTrackPlays[0].tracker.startTime

        playerService.progress = 0
        await self.waitUntil { coordinator.trackTracker?.startTime != completedPlayTimestamp }
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 700,
            observedVideoId: "regular"
        )
        await parseGate.open()
        await self.waitUntil { queue.count == 1 }

        #expect(queue.pendingTracks.first?.title == "Regular Mix Candidate")
        #expect(queue.pendingTracks.first?.timestamp == completedPlayTimestamp)
    }

    @Test("A metadata-only track transition waits for a fresh playback sample")
    func metadataOnlyTrackTransitionWaitsForFreshPlaybackSample() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(
            id: "shared",
            title: "Old Track",
            artistName: "Old Artist",
            duration: 100
        )
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 100,
            observedVideoId: "shared"
        )
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: ScrobbleQueue(directory: dir)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }

        // A queued old-track sample advances the bridge sequence immediately before metadata changes.
        // The new metadata identity must still require the next sample, not merely this latest one.
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 10,
            duration: 100,
            observedVideoId: "shared"
        )
        playerService.currentTrack = TestFixtures.makeSong(
            id: "shared",
            title: "New Track",
            artistName: "New Artist",
            duration: nil
        )
        coordinator.pollPlayerState()

        #expect(coordinator.trackedSong?.title == "New Track")
        #expect(mockService.nowPlayingTracks.count == 1)
        #expect(coordinator.trackedVideoDuration == nil)

        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 200,
            observedVideoId: "shared"
        )
        await self.waitUntil { mockService.nowPlayingTracks.count == 2 }

        #expect(mockService.nowPlayingTracks.last?.title == "New Track")
        #expect(coordinator.trackedVideoDuration == 200)
    }

    @Test("Async parse completion refreshes the current authoritative duration")
    func asyncParseCompletionRefreshesCurrentDuration() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = .empty
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.01)
        let playerService = PlayerService()
        let initialTrack = TestFixtures.makeSong(
            id: "regular",
            title: "Regular Track",
            duration: nil
        )
        playerService.currentTrack = initialTrack
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 40,
            observedVideoId: "regular"
        )
        let queue = ScrobbleQueue(directory: dir)
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [],
            queue: queue,
            mixTracklistParser: parser
        )
        defer { coordinator.stopMonitoring() }
        coordinator.currentTrackVideoId = initialTrack.videoId
        coordinator.trackedSong = initialTrack
        coordinator.trackedVideoDuration = 40
        coordinator.mixDetectionState = .unresolved
        var tracker = PlaybackScrobbleTracker(startTime: Date(), initialProgress: 0)
        tracker.creditVerifiedPlayTime(1)
        tracker.markScrobbled()
        coordinator.trackTracker = tracker
        coordinator.pendingWholeTrackPlays = [
            .init(tracker: tracker, song: initialTrack),
        ]
        coordinator.startMixParse(for: initialTrack, parser: parser, startedWithoutDuration: true)
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }

        let updatedTrack = TestFixtures.makeSong(
            id: "regular",
            title: "Regular Track",
            duration: 700
        )
        playerService.currentTrack = updatedTrack
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 700,
            observedVideoId: "regular"
        )
        await parseGate.open()
        await self.waitUntil {
            if case .notMix = coordinator.mixDetectionState {
                true
            } else {
                false
            }
        }

        #expect(coordinator.trackedVideoDuration == 700)
        #expect(coordinator.trackedSong?.duration == 700)
        #expect(queue.isEmpty)
        #expect(coordinator.trackTracker?.hasScrobbled == false)
    }

    @Test("A provisional short-duration decision upgrades when the player duration grows")
    func provisionalShortDecisionUpgradesToMix() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let chapters = [
            YouTubeChapter(videoId: "mix1", title: "Artist 0 - Track 0", startTime: 0, endTime: 100, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix1", title: "Artist 1 - Track 1", startTime: 100, endTime: 200, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix1", title: "Artist 2 - Track 2", startTime: 200, endTime: nil, timeText: nil, thumbnailURL: nil),
        ]
        let youtubeClient = MockYouTubeClient()
        youtubeClient.watchNextData = self.makeWatchNextData(chapters: chapters)
        let parser = MixTracklistParser(youTubeClient: youtubeClient)
        let service = MockScrobbleService()
        service.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 240,
            observedVideoId: "mix1"
        )
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [service],
            queue: ScrobbleQueue(directory: dir),
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(20)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { service.nowPlayingTracks.contains { $0.title == "Long Mix" } }
        #expect(!service.nowPlayingTracks.contains { $0.title == "Track 0" })

        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 3600,
            observedVideoId: "mix1"
        )
        await self.waitUntil { service.nowPlayingTracks.contains { $0.title == "Track 0" } }

        #expect(service.nowPlayingTracks.map(\.title).contains("Track 0"))
    }
}
