import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
@MainActor
struct NowPlayingTracklistProviderTests {
    // MARK: - Fixtures

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

    private func makeProvider(chapters: [YouTubeChapter]) -> (NowPlayingTracklistProvider, MockYouTubeClient) {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: chapters)
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        return (NowPlayingTracklistProvider(parser: parser), mockYouTube)
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

    // MARK: - Fetch Gating

    /// Regression: the tracklist fetch is gated on track duration, which YouTube reports a beat after
    /// the track object appears. A one-shot check at track-start always missed, so every mix silently
    /// fell back to whole-video scrobbling. The provider must retry as duration settles, then fire
    /// exactly once per video.
    @Test("Fetch is deferred until duration is known, then fires exactly once")
    func fetchDeferredUntilDurationKnown() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let track = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)

        // Duration unknown at track-start → no fetch.
        provider.update(track: track, duration: 0)
        #expect(mockYouTube.getWatchNextCallCount == 0)

        // Duration becomes known and crosses the mix threshold → fetch fires.
        provider.update(track: track, duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount >= 1 }
        #expect(mockYouTube.getWatchNextCallCount == 1)

        // Further duration churn must not re-fetch (latched once per video).
        provider.update(track: track, duration: 3601)
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount > 1 }
        #expect(mockYouTube.getWatchNextCallCount == 1)
    }

    @Test("Fetch is not attempted for short tracks even once duration is known")
    func fetchSkippedForShortTracks() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let track = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: nil)

        // A 4-minute track never crosses the 10-minute mix threshold.
        provider.update(track: track, duration: 240)
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount >= 1 }
        #expect(mockYouTube.getWatchNextCallCount == 0)
    }

    @Test("A stale fetch does not block the next video's fetch")
    func staleFetchDoesNotBlockNextVideo() async {
        let firstRequestGate = AsyncGate()
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        mockYouTube.beforeWatchNextReturn = { videoId in
            if videoId == "mix1" {
                await firstRequestGate.wait()
            }
        }

        provider.update(track: TestFixtures.makeSong(id: "mix1", title: "First Mix", duration: 3600), duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        #expect(mockYouTube.requestedWatchNextVideoIds == ["mix1"])

        // The first request remains suspended while playback moves to another long mix. The new
        // video must start its own parse immediately rather than waiting for the stale request.
        provider.update(track: TestFixtures.makeSong(id: "mix2", title: "Second Mix", duration: 3600), duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 2 }

        #expect(mockYouTube.requestedWatchNextVideoIds == ["mix1", "mix2"])
        await firstRequestGate.open()
    }

    // MARK: - Result

    @Test("A parsed mix is exposed as a tracklist with resolvable entries")
    func exposesParsedTracklist() async throws {
        let (provider, _) = self.makeProvider(chapters: self.makeMixChapters(count: 3))
        let track = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: 1800)

        provider.update(track: track, duration: 1800)
        await self.waitUntil { provider.tracklist != nil }

        let tracklist = try #require(provider.tracklist)
        #expect(tracklist.isMix)
        #expect(tracklist.entries.count == 3)
        #expect(provider.currentEntry(at: 0)?.title == "Track 0")
        #expect(provider.currentEntry(at: 650)?.title == "Track 1")
    }

    @Test("Switching to a non-mix track clears the previous tracklist")
    func videoChangeResetsTracklist() async {
        let (provider, _) = self.makeProvider(chapters: self.makeMixChapters())
        let mix = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: 1800)
        provider.update(track: mix, duration: 1800)
        await self.waitUntil { provider.tracklist != nil }
        #expect(provider.tracklist != nil)

        let short = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: 200)
        provider.update(track: short, duration: 200)
        #expect(provider.tracklist == nil)
    }

    // MARK: - Driver Integration

    /// The provider is driven by PlayerService's `currentTrack`/`duration` observers, independent of
    /// scrobbling. A change to either must reach the provider and resolve segments.
    @Test("PlayerService drives the provider when track and duration change")
    func playerServiceDrivesProvider() async {
        let (provider, _) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)

        player.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)
        player.duration = 3600

        await self.waitUntil { provider.tracklist != nil }
        #expect(provider.tracklist?.isMix == true)
    }
}
