import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct ScrobblingCoordinatorMixTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrobblingCoordinatorMixTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanupDirectory(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Mix-Mode Detection

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

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Regression: duration often arrives after the fallback parse. When the parsed bounds cannot
    /// prove a long video, classification must remain pending without refetching, then commit the
    /// already-parsed mix as soon as the current playback duration becomes authoritative.
    @Test("Mix parse stays pending until duration confirms it and fires exactly once")
    func mixParseWaitsForConfirmingDuration() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(
            chapters: self.makeMixChapters(entryDuration: 100)
        )
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        defer { settings.setServiceEnabled("Mock", false) }

        let playerService = PlayerService()
        // Track is playing, but duration hasn't loaded yet (the race the fix addresses).
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)
        playerService.state = .playing
        playerService.duration = 0
        playerService.setPlaybackStateVideoId("mix1")

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

        // First poll ran synchronously in startMonitoring; duration unknown → no fetch attempted.
        #expect(mockYouTube.getWatchNextCallCount == 0)
        await self.waitUntil { mockService.nowPlayingTracks.first?.title == "Long Mix" }
        #expect(mockService.nowPlayingTracks.first?.title == "Long Mix")

        // Duration becomes known — the observed change must commit the existing parse result.
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 3600,
            observedVideoId: "mix1"
        )
        await self.waitUntil { mockYouTube.getWatchNextCallCount >= 1 }
        #expect(mockYouTube.getWatchNextCallCount == 1)

        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        playerService.progress = 0.1
        await self.waitUntil { mockService.nowPlayingTracks.contains { $0.title == "Track 0" } }
        #expect(mockService.nowPlayingTracks.contains { $0.title == "Track 0" })

        // Further duration churn must not re-fetch (latched once per track).
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0.2,
            duration: 3601,
            observedVideoId: "mix1"
        )
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount > 1 }
        #expect(mockYouTube.getWatchNextCallCount == 1)
    }

    @Test("Mix fetch is not attempted for a track-scoped short duration")
    func mixFetchSkippedForShortTracks() async throws {
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
        defer { settings.setServiceEnabled("Mock", false) }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: 240)
        playerService.state = .playing
        playerService.duration = 3600 // May still be stale from the previous track.
        playerService.setPlaybackStateVideoId("short1")

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

        // The Song's own 4-minute duration is tied to this video and wins over stale player state.
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount >= 1 }
        #expect(mockYouTube.getWatchNextCallCount == 0)
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }
        #expect(mockService.nowPlayingTracks.first?.title == "Regular Song")
    }

    @Test("A provisional short player duration does not latch a long mix as not-mix")
    func provisionalShortDurationDoesNotLatchNotMix() async throws {
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
        defer { settings.setServiceEnabled("Mock", false) }

        let playerService = PlayerService()
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 10,
            duration: 240,
            observedVideoId: "previous"
        )
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)

        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [mockService],
            queue: ScrobbleQueue(directory: dir),
            mixTracklistParser: parser
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        try await Task.sleep(for: .milliseconds(50))
        #expect(mockYouTube.getWatchNextCallCount == 0)
        #expect(mockService.nowPlayingTracks.isEmpty)

        // Even another stale progress update must not make that duration current-track scoped.
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 11,
            duration: 240,
            observedVideoId: "previous"
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(mockYouTube.getWatchNextCallCount == 0)
        #expect(mockService.nowPlayingTracks.isEmpty)

        // The current video's real duration arrives later. Detection must still be unresolved so
        // it can parse the mix instead of remaining latched in whole-track mode.
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 3600,
            observedVideoId: "mix1"
        )
        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        playerService.progress = 0.1
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }

        #expect(mockService.nowPlayingTracks.first?.title == "Track 0")
    }

    @Test("A current playback update can resolve a player-only short duration")
    func playerOnlyShortDurationResolvesAfterPlaybackUpdate() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = .empty
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        defer { settings.setServiceEnabled("Mock", false) }

        let playerService = PlayerService()
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 100,
            duration: 3600,
            observedVideoId: "previous-long"
        )
        playerService.currentTrack = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: nil)

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

        try await Task.sleep(for: .milliseconds(50))
        #expect(mockYouTube.getWatchNextCallCount == 0)
        #expect(mockService.nowPlayingTracks.isEmpty)

        // PlayerService publishes progress and duration together for the current playback update.
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 240,
            observedVideoId: "short1"
        )
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }

        #expect(mockYouTube.getWatchNextCallCount == 1)
        #expect(mockService.nowPlayingTracks.first?.title == "Regular Song")
    }

    @Test("A duration-less track falls back through parsing and resumes regular handling")
    func durationlessTrackFallsBackAfterParse() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = .empty
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        defer { settings.setServiceEnabled("Mock", false) }

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
            unknownDurationParseDelay: .milliseconds(20)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }

        #expect(mockService.nowPlayingTracks.first?.title == "Unknown Duration")
    }

    @Test("A late short duration overrides an in-flight unknown-duration fallback parse")
    func lateShortDurationOverridesFallbackParse() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: self.makeMixChapters())
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        defer { settings.setServiceEnabled("Mock", false) }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
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

        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        playerService.currentTrack = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: 240)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 2,
            duration: 240,
            observedVideoId: "short1"
        )
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }

        #expect(mockService.nowPlayingTracks.first?.title == "Regular Song")
        #expect(mockYouTube.getWatchNextCompletionCount == 0)
        await parseGate.open()
    }

    @Test("A late short duration rejects a completed fallback mix classification")
    func lateShortDurationRejectsCompletedFallbackMix() async throws {
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
            progress: 1,
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
        await self.waitUntil { mockService.nowPlayingTracks.first?.title == "Regular Song" }
        #expect(mockService.nowPlayingTracks.first?.title == "Regular Song")

        playerService.currentTrack = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: 240)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 2,
            duration: 240,
            observedVideoId: "short1"
        )
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }

        #expect(mockService.nowPlayingTracks.first?.title == "Regular Song")
        #expect(mockService.nowPlayingTracks.count == 1)
    }

    @Test("Whole-track side effects wait while mix detection is pending")
    func wholeTrackSideEffectsWaitForMixDetection() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: self.makeMixChapters())
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        defer { settings.setServiceEnabled("Mock", false) }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Whole Mix", duration: 3600)
        playerService.state = .playing
        playerService.duration = 3600
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
        try await Task.sleep(for: .milliseconds(100))
        #expect(mockService.nowPlayingTracks.isEmpty)
        #expect(queue.isEmpty)

        await parseGate.open()
        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }
        playerService.progress = 0.1
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }

        #expect(mockService.nowPlayingTracks.first?.title == "Track 0")
        #expect(!mockService.nowPlayingTracks.contains { $0.title == "Whole Mix" })
    }

    @Test("Stale playback samples are not credited to the new video's mix")
    func stalePlaybackSamplesAreIgnored() async throws {
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
        let settings = MockScrobblingSettings()
        let originalPercent = settings.scrobblePercentThreshold
        settings.scrobblePercentThreshold = 0.001
        settings.setServiceEnabled("Mock", true)
        defer {
            settings.scrobblePercentThreshold = originalPercent
            settings.setServiceEnabled("Mock", false)
        }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Whole Mix", duration: 700)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 700,
            observedVideoId: "previous"
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
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 700,
            observedVideoId: "previous"
        )
        try await Task.sleep(for: .milliseconds(20))
        await parseGate.open()
        await self.waitUntil { mockYouTube.getWatchNextCompletionCount == 1 }

        #expect(queue.isEmpty)

        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 700,
            observedVideoId: "mix1"
        )
        await self.waitUntil { mockService.nowPlayingTracks.contains { $0.title == "Track 0" } }
    }

    @Test("An eligible regular video finalizes after a pending mix parse returns nil")
    func pendingRegularVideoFinalizesAfterParse() async throws {
        let dir = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(dir) }

        let parseGate = AsyncGate()
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = .empty
        mockYouTube.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        let originalPercent = settings.scrobblePercentThreshold
        let originalMinSeconds = settings.scrobbleMinSeconds
        settings.scrobblePercentThreshold = 0.001
        settings.scrobbleMinSeconds = 240
        settings.setServiceEnabled("Mock", true)
        defer {
            settings.scrobblePercentThreshold = originalPercent
            settings.scrobbleMinSeconds = originalMinSeconds
            settings.setServiceEnabled("Mock", false)
        }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "regular-long", title: "Long Regular Video", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 700,
            observedVideoId: "regular-long"
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

        // Leave the track while its parse is still pending. The next track must start normally,
        // while the qualifying previous listen waits for classification instead of being dropped.
        playerService.currentTrack = TestFixtures.makeSong(id: "next", title: "Next Song", duration: 200)
        playerService.duration = 200
        try await Task.sleep(for: .milliseconds(50))
        #expect(queue.isEmpty)

        coordinator.stopMonitoring()
        await parseGate.open()
        await self.waitUntil { queue.count == 1 }

        #expect(queue.pendingTracks.first?.title == "Long Regular Video")
    }

    @Test("A real mix that ends before parsing completes finalizes its qualifying sub-tracks")
    func pendingMixFinalizesSubTracksAfterExit() async throws {
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
        let settings = MockScrobblingSettings()
        let originalPercent = settings.scrobblePercentThreshold
        let originalMinSeconds = settings.scrobbleMinSeconds
        settings.scrobblePercentThreshold = 0.001
        settings.scrobbleMinSeconds = 240
        settings.setServiceEnabled("Mock", true)
        defer {
            settings.scrobblePercentThreshold = originalPercent
            settings.scrobbleMinSeconds = originalMinSeconds
            settings.setServiceEnabled("Mock", false)
        }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Whole Mix", duration: 700)
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
        playerService.progress = 1
        try await Task.sleep(for: .milliseconds(20))
        playerService.currentTrack = TestFixtures.makeSong(id: "next", title: "Next Song", duration: 200)
        playerService.duration = 200

        await parseGate.open()
        await self.waitUntil { queue.count == 1 }

        #expect(queue.pendingTracks.first?.title == "Track 0")
        #expect(!queue.pendingTracks.contains { $0.title == "Whole Mix" })
    }

    @Test("A duration-less mix keeps provisional playback when it exits during fallback parsing")
    func durationlessPendingMixFinalizesAfterExit() async throws {
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
        let settings = MockScrobblingSettings()
        let originalPercent = settings.scrobblePercentThreshold
        settings.scrobblePercentThreshold = 0.001
        settings.setServiceEnabled("Mock", true)
        defer {
            settings.scrobblePercentThreshold = originalPercent
            settings.setServiceEnabled("Mock", false)
        }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Whole Mix", duration: nil)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 0,
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
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 0,
            observedVideoId: "mix1"
        )
        try await Task.sleep(for: .milliseconds(20))
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
    }

    @Test("Playback captured during parsing seeds the active mix entry without duplicates")
    func pendingPlaybackSeedsActiveMixEntry() async throws {
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
        let settings = MockScrobblingSettings()
        let originalPercent = settings.scrobblePercentThreshold
        let originalMinSeconds = settings.scrobbleMinSeconds
        settings.scrobblePercentThreshold = 0.001
        settings.scrobbleMinSeconds = 240
        settings.setServiceEnabled("Mock", true)
        defer {
            settings.scrobblePercentThreshold = originalPercent
            settings.scrobbleMinSeconds = originalMinSeconds
            settings.setServiceEnabled("Mock", false)
        }

        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Whole Mix", duration: 700)
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
        playerService.progress = 1
        try await Task.sleep(for: .milliseconds(20))
        await parseGate.open()
        await self.waitUntil { queue.count == 1 }

        // Trigger live mix handling after the provisional listen already qualified Track 0.
        playerService.progress = 1.1
        await self.waitUntil { mockService.nowPlayingTracks.count == 1 }
        playerService.progress = 2.1
        try await Task.sleep(for: .milliseconds(50))

        #expect(queue.count == 1)
        #expect(queue.pendingTracks.first?.title == "Track 0")
    }
}
