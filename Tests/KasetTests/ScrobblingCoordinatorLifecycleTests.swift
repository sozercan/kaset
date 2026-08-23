import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct ScrobblingCoordinatorLifecycleTests {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrobblingCoordinatorLifecycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanupDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
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

    @Test("Track finalization cancels an in-flight now-playing request")
    func trackFinalizationCancelsInFlightNowPlaying() async throws {
        let directory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(directory) }

        let oldNowPlayingGate = AsyncGate()
        let service = MockScrobbleService()
        service.authState = .connected(username: "testuser")
        service.beforeNowPlayingReturn = { track in
            if track.title == "Old Track" {
                await oldNowPlayingGate.wait()
            }
        }
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        let parser = MixTracklistParser(youTubeClient: MockYouTubeClient())
        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "old", title: "Old Track", duration: 100)
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 100,
            observedVideoId: "old"
        )
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [service],
            queue: ScrobbleQueue(directory: directory),
            mixTracklistParser: parser,
            unknownDurationParseDelay: .seconds(1)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }
        await self.waitUntil { coordinator.nowPlayingTasks.count == 1 }

        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 0,
            observedVideoId: "next"
        )
        playerService.currentTrack = TestFixtures.makeSong(id: "next", title: "Next Track", duration: nil)
        coordinator.pollPlayerState()

        #expect(coordinator.nowPlayingTasks.isEmpty)
        await oldNowPlayingGate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(service.nowPlayingTracks.isEmpty)
    }

    @Test("A stalled deferred parse commits its fallback during normal runtime")
    func deferredParseTimeoutCommitsFallback() async throws {
        let directory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(directory) }

        let parseGate = AsyncGate()
        let youtubeClient = MockYouTubeClient()
        youtubeClient.watchNextData = .empty
        youtubeClient.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: youtubeClient)
        let service = MockScrobbleService()
        service.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings(scrobblePercentThreshold: 0.001)
        settings.setServiceEnabled("Mock", true)
        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(
            id: "regular",
            title: "Long Regular Track",
            duration: 700
        )
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 700,
            observedVideoId: "regular"
        )
        let queue = ScrobbleQueue(directory: directory)
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [service],
            queue: queue,
            mixTracklistParser: parser,
            mixParseTimeout: .milliseconds(200)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { youtubeClient.getWatchNextCallCount == 1 }
        playerService.progress = 1
        await self.waitUntil { coordinator.pendingWholeTrackPlays.count == 1 }
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 200,
            observedVideoId: "next"
        )
        playerService.currentTrack = TestFixtures.makeSong(id: "next", title: "Next Track", duration: 200)
        coordinator.pollPlayerState()

        await self.waitUntil { !coordinator.pendingMixFinalizations.isEmpty }
        await self.waitUntil { queue.count == 1 }
        #expect(queue.pendingTracks.first?.title == "Long Regular Track")
        #expect(coordinator.pendingMixFinalizations.isEmpty)

        await parseGate.open()
    }

    @Test("An active fallback parse timeout resumes short-track handling")
    func activeFallbackParseTimeoutResumesShortTrack() async throws {
        let directory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(directory) }

        let parseGate = AsyncGate()
        let youtubeClient = MockYouTubeClient()
        youtubeClient.watchNextData = .empty
        youtubeClient.beforeWatchNextReturn = { _ in await parseGate.wait() }
        let parser = MixTracklistParser(youTubeClient: youtubeClient)
        let service = MockScrobbleService()
        service.authState = .connected(username: "testuser")
        let settings = MockScrobblingSettings()
        settings.setServiceEnabled("Mock", true)
        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(
            id: "short",
            title: "Short Regular Track",
            duration: nil
        )
        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 240,
            observedVideoId: "short"
        )
        let coordinator = ScrobblingCoordinator(
            playerService: playerService,
            settingsManager: settings,
            services: [service],
            queue: ScrobbleQueue(directory: directory),
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(20),
            mixParseTimeout: .milliseconds(20)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        await self.waitUntil { youtubeClient.getWatchNextCallCount == 1 }
        await self.waitUntil { service.nowPlayingTracks.count == 1 }

        #expect(service.nowPlayingTracks.first?.title == "Short Regular Track")
        #expect(coordinator.mixParseTask == nil)
        await parseGate.open()
    }

    @Test("Delayed fallback parsing waits for a fresh same-ID playback sample")
    func delayedFallbackParseWaitsForFreshSameIDSample() async throws {
        let directory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(directory) }

        let youtubeClient = MockYouTubeClient()
        youtubeClient.watchNextData = .empty
        let parser = MixTracklistParser(youTubeClient: youtubeClient)
        let service = MockScrobbleService()
        service.authState = .connected(username: "testuser")
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
            services: [service],
            queue: ScrobbleQueue(directory: directory),
            mixTracklistParser: parser,
            unknownDurationParseDelay: .milliseconds(20)
        )
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }
        await self.waitUntil { service.nowPlayingTracks.count == 1 }

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
        try await Task.sleep(for: .milliseconds(50))
        #expect(youtubeClient.getWatchNextCallCount == 0)

        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 700,
            observedVideoId: "shared"
        )
        coordinator.pollPlayerState()
        await self.waitUntil { youtubeClient.getWatchNextCallCount == 1 }

        #expect(youtubeClient.requestedWatchNextVideoIds == ["shared"])
    }
}
