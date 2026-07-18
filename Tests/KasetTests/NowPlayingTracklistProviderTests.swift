import Foundation
import Testing
@testable import Kaset

// MARK: - NowPlayingTracklistProviderTests

@Suite(.serialized, .tags(.service))
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

    private func makeProvider(
        chapters: [YouTubeChapter],
        retryDelay: Duration = .seconds(1),
        maxTransientRetryAttempts: Int = 1
    ) -> (NowPlayingTracklistProvider, MockYouTubeClient) {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: chapters)
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        return (
            NowPlayingTracklistProvider(
                parser: parser,
                retryDelay: retryDelay,
                maxTransientRetryAttempts: maxTransientRetryAttempts
            ),
            mockYouTube
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
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

    /// Regression: a `Song` can be minted with a stale short `duration` (the previous item's, before
    /// the WebView reports the new video's), so its baked-in duration stays below the mix gate. A
    /// later fresh player-duration update that crosses the threshold must still trigger the fetch —
    /// the stale baked-in value must not suppress it.
    @Test("A fresh player duration overrides a stale short baked-in track duration")
    func freshPlayerDurationOverridesStaleTrackDuration() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        // Baked-in duration is a stale short value (below the 10-minute gate).
        let track = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: 180)

        // Track-start with only the stale short duration → no fetch.
        provider.update(track: track, duration: 0)
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount >= 1 }
        #expect(mockYouTube.getWatchNextCallCount == 0)

        // The WebView reports the real (long) duration → fetch must fire despite the stale track value.
        provider.update(track: track, duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount >= 1 }
        #expect(mockYouTube.getWatchNextCallCount == 1)
    }

    @Test("A transient fetch failure retries once for the current video")
    func transientFailureRetriesCurrentVideo() async {
        let (provider, mockYouTube) = self.makeProvider(
            chapters: self.makeMixChapters(),
            retryDelay: .milliseconds(100)
        )
        mockYouTube.error = URLError(.timedOut)
        let track = TestFixtures.makeSong(id: "retry-mix", title: "Retry Mix", duration: 3600)

        provider.update(track: track, duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        mockYouTube.error = nil

        await self.waitUntil { mockYouTube.getWatchNextCallCount == 2 }
        await self.waitUntil { provider.tracklist != nil }

        #expect(mockYouTube.getWatchNextCallCount == 2)
        #expect(provider.tracklist?.videoId == "retry-mix")
    }

    @Test("A confirmed non-mix result does not retry")
    func confirmedNonMixDoesNotRetry() async {
        let (provider, mockYouTube) = self.makeProvider(
            chapters: self.makeMixChapters(count: 2),
            retryDelay: .milliseconds(20)
        )
        let track = TestFixtures.makeSong(id: "regular", title: "Regular", duration: 3600)

        provider.update(track: track, duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        await self.waitUntil(timeout: .milliseconds(100)) { mockYouTube.getWatchNextCallCount > 1 }

        #expect(mockYouTube.getWatchNextCallCount == 1)
        #expect(!provider.isParsing)
        #expect(provider.tracklist == nil)
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

    @Test("A cancelled ABA parse cannot clear the replacement parse")
    func cancelledABAParseDoesNotClearReplacement() async {
        let mix1Gate = AsyncGate()
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        mockYouTube.beforeWatchNextReturn = { videoId in
            if videoId == "mix1" {
                await mix1Gate.wait()
            }
        }

        // A: mix1's fetch is held in-flight.
        provider.update(track: TestFixtures.makeSong(id: "mix1", duration: 3600), duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }
        // B: switch to mix2, cancelling and removing A's now-unobserved parser request.
        provider.update(track: TestFixtures.makeSong(id: "mix2", duration: 3600), duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 2 }
        // A again: switching back must start a fresh mix1 request instead of joining cancelled work.
        provider.update(track: TestFixtures.makeSong(id: "mix1", duration: 3600), duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 3 }

        // Releasing mix1 resumes both the cancelled original and the current replacement request.
        // The current (replacement) generation must win; the stale one must not clear it.
        await mix1Gate.open()
        await self.waitUntil { provider.tracklist != nil }
        #expect(provider.tracklist?.videoId == "mix1")
        #expect(mockYouTube.getWatchNextCallCount == 3)
    }

    @Test("Invalid placeholder video IDs never start a parse")
    func invalidPlaceholderVideoIdsDoNotParse() {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())

        for videoId in ["", " \n ", "unknown"] {
            provider.update(track: TestFixtures.makeSong(id: videoId, duration: 3600), duration: 3600)
        }

        #expect(mockYouTube.getWatchNextCallCount == 0)
        #expect(provider.tracklist == nil)
    }

    @Test("The ten-minute boundary remains below the mix gate")
    func exactMinimumDurationDoesNotParse() {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())

        provider.update(track: TestFixtures.makeSong(id: "mix1", duration: 600), duration: 600)

        #expect(mockYouTube.getWatchNextCallCount == 0)
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
        player.updatePlaybackState(isPlaying: false, progress: 0, duration: 3600, observedVideoId: "mix1")

        await self.waitUntil { provider.tracklist != nil }
        #expect(provider.tracklist?.isMix == true)
    }

    /// Regression: `play(song:)` sets `currentTrack` before the WebView bridge reports the new video,
    /// so `duration` (and `playbackStateVideoId`) can still belong to the previous long item. A short
    /// track following a long one must not inherit that stale duration and cross the mix gate.
    @Test("A short track following a long item does not inherit the previous duration for mix gating")
    func shortTrackAfterLongDoesNotInheritDuration() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)

        // A long mix is playing and the bridge has confirmed its duration → fetch fires.
        player.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)
        player.updatePlaybackState(isPlaying: false, progress: 0, duration: 3600, observedVideoId: "mix1")
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }

        // Switch to a short track before the bridge reports it: duration still holds 3600 and
        // playbackStateVideoId still points at the mix, so the gate must not be crossed.
        player.currentTrack = TestFixtures.makeSong(id: "short1", title: "Regular Song", duration: nil)
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount >= 2 }
        #expect(mockYouTube.getWatchNextCallCount == 1)
        #expect(provider.tracklist == nil)
    }

    /// Regression: a video-id-only update is not an atomic playback observation. It must not certify
    /// an existing duration that may still belong to the previous video; a same-value duration is
    /// trusted only when the bridge reports the id and duration together.
    @Test("An ID-only update cannot certify an existing duration")
    func idOnlyUpdateCannotCertifyExistingDuration() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)

        // Duration is already correct, but provenance hasn't been confirmed for this track yet.
        player.duration = 3600
        player.currentTrack = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)
        await self.waitUntil(timeout: .milliseconds(150)) { mockYouTube.getWatchNextCallCount >= 1 }
        #expect(mockYouTube.getWatchNextCallCount == 0)

        // Advancing only the id must not promote the existing duration.
        player.setPlaybackStateVideoId("mix1")
        await self.waitUntil(timeout: .milliseconds(150)) { mockYouTube.getWatchNextCallCount >= 1 }
        #expect(mockYouTube.getWatchNextCallCount == 0)

        // The bridge then reports the same duration atomically with the id. This must drive the fetch
        // even though assigning the duration property again would not trigger didSet.
        player.recordPlaybackStateObservation(videoId: "mix1", duration: 3600)
        await self.waitUntil { mockYouTube.getWatchNextCallCount >= 1 }
        #expect(mockYouTube.getWatchNextCallCount == 1)
    }

    @Test("A correlated short observation cannot inherit the previous long duration")
    func correlatedShortObservationDoesNotInheritLongDuration() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)
        player.currentTrack = TestFixtures.makeSong(id: "mix1", duration: nil)
        player.updatePlaybackState(isPlaying: true, progress: 0, duration: 3600, observedVideoId: "mix1")
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }

        player.currentTrack = TestFixtures.makeSong(id: "short1", duration: nil)
        player.updatePlaybackState(isPlaying: true, progress: 0, duration: 240, observedVideoId: "short1")
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount > 1 }

        #expect(mockYouTube.getWatchNextCallCount == 1)
        #expect(provider.tracklist == nil)
    }

    @Test("Stale long track metadata cannot cross the mix gate before playback confirms duration")
    func staleLongTrackDurationDoesNotCrossMixGate() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)

        // A Song can outlive a stale persisted/API duration. Metadata alone must not launch the
        // mix parse because a later bridge observation may prove that this video is actually short.
        player.currentTrack = TestFixtures.makeSong(id: "short1", duration: 3600)
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount > 0 }
        #expect(mockYouTube.getWatchNextCallCount == 0)

        player.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 240,
            observedVideoId: "short1"
        )
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount > 0 }

        #expect(player.bestKnownDuration(for: player.currentTrack) == 240)
        #expect(mockYouTube.getWatchNextCallCount == 0)
        #expect(provider.tracklist == nil)

        // A later correlated long duration still re-drives the provider normally.
        player.updatePlaybackState(
            isPlaying: true,
            progress: 0,
            duration: 3600,
            observedVideoId: "short1"
        )
        await self.waitUntil { provider.tracklist?.isMix == true }
        #expect(mockYouTube.getWatchNextCallCount == 1)
        #expect(provider.tracklist?.isMix == true)
    }

    @Test("A matching zero observation cannot certify a mismatched long duration")
    func matchingZeroObservationDoesNotCertifyMismatchedDuration() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)
        player.currentTrack = TestFixtures.makeSong(id: "short1", duration: nil)

        player.updatePlaybackState(isPlaying: false, progress: 0, duration: 3600, observedVideoId: "old-mix")
        player.updatePlaybackState(isPlaying: false, progress: 0, duration: 0, observedVideoId: "short1")
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount > 0 }

        #expect(mockYouTube.getWatchNextCallCount == 0)
    }

    @Test("Native playback setup does not retag the previous media duration")
    func nativePlaybackSetupDoesNotRetagPreviousMediaDuration() async {
        let player = PlayerService()
        let previous = TestFixtures.makeSong(id: "previous-short", duration: 120)
        player.currentTrack = previous
        player.recordPlaybackStateObservation(videoId: previous.videoId, duration: 120)

        let next = TestFixtures.makeSong(id: "next-long", duration: 3600)
        let intent = player.beginMusicPlaybackIntent()
        await player.play(
            song: next,
            webLoadStrategy: .standard,
            queueEntryID: nil,
            fetchesMetadata: false,
            intent: intent
        )

        #expect(player.observedDuration(for: previous.videoId) == 120)
        #expect(player.bestKnownDuration(for: previous) == 120)
    }

    @Test("Nil empty and whitespace observations do not certify duration")
    func invalidObservedVideoIdsDoNotCertifyDuration() {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)
        player.currentTrack = TestFixtures.makeSong(id: "short1", duration: nil)

        for videoId: String? in [nil, "", " \n "] {
            player.updatePlaybackState(isPlaying: false, progress: 0, duration: 3600, observedVideoId: videoId)
        }

        #expect(player.playbackStateVideoId == nil)
        #expect(mockYouTube.getWatchNextCallCount == 0)
    }

    @Test("Metadata cannot bake an uncorrelated long duration into a short track")
    func metadataDoesNotBakeUncorrelatedDuration() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)
        player.currentTrack = TestFixtures.makeSong(id: "mix1", duration: nil)
        player.updatePlaybackState(isPlaying: true, progress: 0, duration: 3600, observedVideoId: "mix1")
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }

        player.updateTrackMetadata(
            title: "Short Track",
            artist: "Artist",
            thumbnailUrl: "",
            videoId: "short1"
        )
        await self.waitUntil(timeout: .milliseconds(200)) { mockYouTube.getWatchNextCallCount > 1 }

        #expect(player.currentTrack?.videoId == "short1")
        #expect(player.currentTrack?.duration == nil)
        #expect(mockYouTube.getWatchNextCallCount == 1)
    }

    @Test("Equal durations on consecutive videos remain independently correlated")
    func equalDurationsAcrossVideosDriveBothParses() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)
        player.currentTrack = TestFixtures.makeSong(id: "mix1", duration: nil)
        player.updatePlaybackState(isPlaying: true, progress: 0, duration: 3600, observedVideoId: "mix1")
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }

        player.currentTrack = TestFixtures.makeSong(id: "mix2", duration: nil)
        player.updatePlaybackState(isPlaying: true, progress: 0, duration: 3600, observedVideoId: "mix2")
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 2 }

        #expect(mockYouTube.requestedWatchNextVideoIds == ["mix1", "mix2"])
    }

    @Test("Restored duration is trusted for its restored video")
    func restoredDurationDrivesProvider() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)

        player.applyRestoredPlaybackSession(
            queue: [TestFixtures.makeSong(id: "mix1", duration: nil)],
            currentIndex: 0,
            progress: 120,
            duration: 3600
        )
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }

        #expect(mockYouTube.requestedWatchNextVideoIds == ["mix1"])
    }

    @Test("Repeat-one style same-video observations stay latched")
    func repeatedSameVideoObservationsStayLatched() async {
        let (provider, mockYouTube) = self.makeProvider(chapters: self.makeMixChapters())
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)
        player.currentTrack = TestFixtures.makeSong(id: "mix1", duration: nil)

        for progress in [0.0, 1800, 0, 1800] {
            player.updatePlaybackState(
                isPlaying: true,
                progress: progress,
                duration: 3600,
                observedVideoId: "mix1"
            )
        }
        await self.waitUntil { mockYouTube.getWatchNextCallCount == 1 }

        #expect(mockYouTube.getWatchNextCallCount == 1)
    }
}
