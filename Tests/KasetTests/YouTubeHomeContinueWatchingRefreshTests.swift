import Foundation
import Testing
@testable import Kaset

// MARK: - YouTubeHomeContinueWatchingRefreshTests

/// Covers the post-watch Continue Watching rail refresh: returning to Home after
/// watching a video rebuilds only that rail (a finished video drops out, a
/// partially-watched one appears or updates its progress), gated on the player's
/// watch-activity generation, cache-bypassed, and resilient to transient fetch failures.
@Suite("YouTubeHome Continue Watching refresh", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeHomeContinueWatchingRefreshTests {
    let mockClient: MockYouTubeClient
    let sut: YouTubeHomeViewModel

    init() {
        self.mockClient = MockYouTubeClient()
        self.sut = YouTubeHomeViewModel(client: self.mockClient)
        // The refresh delays are global statics; reset them to instant on every
        // test so a test that sets a long delay (e.g. the cancellation test)
        // can't leak it into another test running in parallel.
        Self.resetRefreshDelays()
    }

    /// Resets the post-watch refresh delays to instant so tests don't wait real
    /// seconds and never inherit another test's delay override.
    private static func resetRefreshDelays() {
        YouTubeHomeViewModel.continueWatchingRefreshDelay = .zero
        YouTubeHomeViewModel.continueWatchingRefreshRetryDelay = .zero
    }

    /// Shrinks the post-watch refresh delays so tests don't wait real seconds.
    /// Idempotent with the `init()` reset; kept for explicit intent at call sites.
    private func makeRefreshDelaysInstant() {
        Self.resetRefreshDelays()
    }

    /// Awaits the view model's in-flight Continue Watching rebuild (if any) by
    /// polling for the expected state. Uses short real sleeps (not bare yields)
    /// so a refresh task that suspends on `Task.sleep` reliably completes even
    /// under load, bounded (~2s) so a genuine bug still fails fast.
    private func waitForCondition(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Watching a video to completion removes it from Continue Watching on return")
    func refreshRemovesFinishedVideo() async {
        self.makeRefreshDelaysInstant()
        // Initial load: two resumable videos, including the one about to finish.
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "watching", watchedPercent: 40),
                MockYouTubeClient.makeVideo(videoId: "other", watchedPercent: 20),
            ],
            continuation: nil
        )
        await self.sut.load()
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.map(\.videoId)
            == ["watching", "other"])

        // The user watches "watching" to the end; fresh history now reports it
        // finished (>=96), so it should drop out of the rail.
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "watching", watchedPercent: 100),
                MockYouTubeClient.makeVideo(videoId: "other", watchedPercent: 20),
            ],
            continuation: nil
        )

        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.map(\.videoId) == ["other"]
        }

        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.map(\.videoId) == ["other"])
        #expect(self.mockClient.getHistoryForceRefreshCount == 1) // bypassed the cache
    }

    @Test("Watching a video partway adds it to Continue Watching on return")
    func refreshAddsPartiallyWatchedVideo() async {
        self.makeRefreshDelaysInstant()
        // Initial load: nothing resumable yet, so no Continue Watching rail.
        self.mockClient.historyFeed = .empty
        await self.sut.load()
        #expect(self.sut.sections.contains { $0.kind == .continueWatching } == false)

        // The user watches "fresh" partway; fresh history now reports progress.
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "fresh", watchedPercent: 35)],
            continuation: nil
        )

        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            self.sut.sections.contains { $0.kind == .continueWatching }
        }

        let rail = self.sut.sections.first { $0.kind == .continueWatching }
        #expect(rail?.videos.map(\.videoId) == ["fresh"])
        // Continue Watching must lead the section list.
        #expect(self.sut.sections.first?.kind == .continueWatching)
    }

    @Test("Watching more of a still-unfinished video updates its progress in the rail")
    func refreshUpdatesProgressForSameVideo() async {
        self.makeRefreshDelaysInstant()
        // Initial load: one resumable video at 30%.
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 30)

        // The user watches more without finishing: same video, same position,
        // higher percent. An id-only change check would miss this.
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 55)],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 55
        }

        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 55)
        #expect(self.mockClient.getHistoryForceRefreshCount == 1) // updated on the first try, no retry
    }

    @Test("Refresh rebuilds only Continue Watching, leaving grid, shelves, and topics intact")
    func refreshLeavesOtherSectionsUntouched() async {
        self.makeRefreshDelaysInstant()
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 4),
            continuation: nil
        )
        self.mockClient.homeShelves = [
            YouTubeHomeSection(
                id: "shelf-1-Breaking news",
                title: "Breaking news",
                videos: MockYouTubeClient.makeVideos(count: 2),
                kind: .shelf
            ),
        ]
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 3), continuation: nil),
        ]
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()
        let gridBefore = self.sut.videos.map(\.videoId)
        #expect(self.sut.sections.map(\.kind) == [.continueWatching, .shelf, .topic])

        // A new watch updates history; only the rail should change.
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30),
                MockYouTubeClient.makeVideo(videoId: "new-resume", watchedPercent: 60),
            ],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            (self.sut.sections.first { $0.kind == .continueWatching }?.videos.count ?? 0) == 2
        }

        // Grid, shelf, topic untouched and still in order; no skeleton flash.
        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.map(\.videoId) == gridBefore)
        #expect(self.sut.sections.map(\.kind) == [.continueWatching, .shelf, .topic])
        #expect(self.sut.sections.first { $0.kind == .shelf }?.title == "Breaking news")
        #expect(self.sut.sections.first { $0.kind == .topic }?.title == "Gaming")
    }

    @Test("Refresh is gated on the watch-activity generation advancing")
    func refreshGatesOnWatchActivityGeneration() async {
        self.makeRefreshDelaysInstant()
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()

        // No activity yet (generation 0): nothing was watched, so no fetch.
        self.sut.refreshContinueWatching(forGeneration: 0)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 0)

        // First watch (generation 1) updates the rail (a new resumable video appears),
        // so the rebuild sees a change on its first try and does not retry.
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30),
                MockYouTubeClient.makeVideo(videoId: "newly", watchedPercent: 45),
            ],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            (self.sut.sections.first { $0.kind == .continueWatching }?.videos.count ?? 0) == 2
        }
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)

        // Returning again with no new activity (same generation) does not re-fetch.
        self.sut.refreshContinueWatching(forGeneration: 1)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)

        // A strictly higher generation (e.g. a later partial watch, after an
        // earlier generation was already reflected) must still fire. This is the
        // invariant that makes the single set-only generation safe: reflecting
        // one generation never blocks a later one — so a bare start followed by a
        // partial watch always refreshes.
        self.mockClient.historyForceRefreshFeed = YouTubeFeed(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30),
                MockYouTubeClient.makeVideo(videoId: "newly", watchedPercent: 70),
            ],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 2)
        await self.waitForCondition { self.mockClient.getHistoryForceRefreshCount == 2 }
        #expect(self.mockClient.getHistoryForceRefreshCount == 2)
    }

    @Test("Re-watching the same video still refreshes when the generation advances")
    func refreshFiresOnSameVideoRewatch() async {
        self.makeRefreshDelaysInstant()
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()

        // First watch of "resume" advances it to 55%.
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 55)],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 55
        }
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)

        // The user opens the SAME video again and finishes it. The videoId is
        // unchanged, but the generation advanced (2), so the rail must still
        // refresh — and the now-finished video drops out.
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 100)],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 2)
        await self.waitForCondition {
            self.sut.sections.contains { $0.kind == .continueWatching } == false
        }
        #expect(self.sut.sections.contains { $0.kind == .continueWatching } == false)
        #expect(self.mockClient.getHistoryForceRefreshCount == 2)
    }

    @Test("A failed refresh keeps the existing Continue Watching rail")
    func refreshFailurePreservesRail() async {
        self.makeRefreshDelaysInstant()
        // Initial load builds a rail from cached history (no forced refresh).
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.map(\.videoId) == ["resume"])

        // The post-watch forced refresh fails (transient network/auth/API). The
        // existing rail must be preserved, not wiped.
        self.mockClient.historyForceRefreshError = YTMusicError.networkError(
            underlying: URLError(.timedOut)
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        // Two forced attempts: the first fails, the retry fires and also fails.
        await self.waitForCondition { self.mockClient.getHistoryForceRefreshCount == 2 }

        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.map(\.videoId) == ["resume"])
        #expect(self.sut.loadingState == .loaded) // no skeleton flash
    }

    @Test("A failed refresh does not advance the watermark, so a later return retries")
    func failedRefreshLeavesWatermarkRetryable() async {
        self.makeRefreshDelaysInstant()
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()

        // First post-watch refresh fails on both the attempt and the retry.
        self.mockClient.historyForceRefreshError = YTMusicError.networkError(
            underlying: URLError(.timedOut)
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition { self.mockClient.getHistoryForceRefreshCount == 2 }

        // The user returns again with the SAME generation. Because the failed
        // refresh did not advance the watermark, this must fetch again (not skip), and
        // now it succeeds and updates the rail.
        self.mockClient.historyForceRefreshError = nil
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 70)],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 70
        }
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 70)
        #expect(self.mockClient.getHistoryForceRefreshCount == 3) // 2 failed + 1 successful
    }

    @Test("Cancelling the refresh mid-delay does not advance the watermark")
    func cancelledRefreshLeavesWatermarkRetryable() async {
        // Non-zero delay so the refresh is cancellable while still sleeping.
        YouTubeHomeViewModel.continueWatchingRefreshDelay = .seconds(60)
        YouTubeHomeViewModel.continueWatchingRefreshRetryDelay = .zero
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()

        // Trigger a refresh, then cancel it (e.g. account switch / discard) while
        // it is still in its propagation delay — before any fetch happened.
        self.sut.refreshContinueWatching(forGeneration: 1)
        self.sut.cancelLoad()
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 0) // never reached the fetch

        // A later return with the SAME count must NOT be skipped: the cancelled
        // attempt didn't advance the watermark. Use instant delays now so it lands.
        YouTubeHomeViewModel.continueWatchingRefreshDelay = .zero
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 80)],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 80
        }
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 80)
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)
    }

    @Test("Refresh before the home feed has loaded does not fetch immediately")
    func refreshBeforeLoadDefersFetch() async {
        self.makeRefreshDelaysInstant()
        // No load() yet — loadingState is .idle. The trigger is queued as
        // pending rather than fetching now (or being dropped).
        self.sut.refreshContinueWatching(forGeneration: 1)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 0)
        #expect(self.sut.sections.isEmpty)
    }

    @Test("A watch during cold Home load forces a cache-bypassed rail refresh once loaded")
    func pendingRefreshRunsAfterColdLoad() async {
        self.makeRefreshDelaysInstant()
        // Warm, PRE-watch history that the cached initial load would build the
        // rail from (30%).
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        // The forced (post-watch) refresh returns DIFFERENT data (65%), so the
        // rebuild is a single deterministic `.updated` with no retry — the
        // assertions below are not observing a transient pre-retry count.
        self.mockClient.historyForceRefreshFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 65)],
            continuation: nil
        )

        // The user watched the video, then opened Home cold — the trigger fires
        // while Home is still idle, so it is queued as pending (no fetch yet).
        self.sut.refreshContinueWatching(forGeneration: 1)
        #expect(self.mockClient.getHistoryForceRefreshCount == 0)

        // Loading the feed must, on completion, consume the pending count and run
        // the cache-bypassed refetch, so the rail shows post-watch progress (65%)
        // rather than the warm cached 30%.
        await self.sut.load()
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 65
        }

        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 65)
        #expect(self.mockClient.getHistoryForceRefreshCount == 1) // single updated fetch, no retry

        // The pending generation is consumed: a later return with the same generation is a
        // no-op (no second forced fetch).
        self.sut.refreshContinueWatching(forGeneration: 1)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)
    }

    @Test("A refresh during pagination (.loadingMore) rebuilds the rail in place")
    func refreshDuringLoadingMoreRunsInPlace() async {
        self.makeRefreshDelaysInstant()
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        // A continuation page is available so `loadMore()` can run. The mock
        // reports "has more" from `homeFeedContinuation`, so set it before load.
        self.mockClient.homeFeedContinuation = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 2),
            continuation: nil
        )
        await self.sut.load()
        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.hasMoreVideos)

        // Hold the pagination request open so the model sits in `.loadingMore`.
        let gate = RefreshTestGate()
        self.mockClient.beforeContinuationReturn = { await gate.wait() }
        let paging = Task { await self.sut.loadMore() }
        await self.waitForCondition { self.sut.loadingState == .loadingMore }
        #expect(self.sut.loadingState == .loadingMore)

        // A return-to-Home refresh during pagination must rebuild the rail in
        // place (pagination only appends grid videos, never the rail) — not park
        // as pending and get stranded until the next navigation.
        self.mockClient.historyForceRefreshFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 80)],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 80
        }
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 80)
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)

        await gate.open()
        await paging.value
    }

    @Test("A refresh while the initial rails are streaming defers, then runs once settled")
    func refreshDuringInitialStreamingDefers() async {
        self.makeRefreshDelaysInstant()
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        // Hold the Continue Watching history fetch open so `performLoad` stays in
        // its rail-streaming window when the refresh trigger arrives.
        let gate = RefreshTestGate()
        self.mockClient.beforeHistoryReturn = { await gate.wait() }
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        self.mockClient.historyForceRefreshFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 90)],
            continuation: nil
        )

        let loading = Task { await self.sut.load() }
        await self.waitForCondition { self.sut.loadingState == .loaded } // grid published, still streaming

        // The trigger arrives mid-stream — it must defer (no forced fetch yet)
        // rather than race the streamer as a second writer to `sections`.
        self.sut.refreshContinueWatching(forGeneration: 1)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 0)

        // Let streaming finish; `performLoad` then drains the pending count and
        // runs the cache-bypassed refresh, landing the post-watch progress (90%).
        await gate.open()
        await loading.value
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 90
        }
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 90)
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)
    }

    @Test("refresh() preserves a still-delayed post-watch refresh so the reload reflects it")
    func refreshPreservesInFlightPostWatchRefresh() async {
        // Non-zero delay so the post-watch refresh is still in its propagation
        // delay (in flight) when refresh() interrupts it.
        YouTubeHomeViewModel.continueWatchingRefreshDelay = .seconds(60)
        YouTubeHomeViewModel.continueWatchingRefreshRetryDelay = .zero
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()

        // A post-watch refresh is scheduled (generation 1) but sits in its delay.
        self.sut.refreshContinueWatching(forGeneration: 1)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 0) // still delayed

        // Fresh post-watch history; the reload's drained pending refresh must use
        // the forced (cache-bypassed) path and reflect it.
        YouTubeHomeViewModel.continueWatchingRefreshDelay = .zero
        self.mockClient.historyForceRefreshFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 75)],
            continuation: nil
        )

        // A pull-to-refresh / error-retry interrupts the still-delayed refresh.
        // Its target generation must survive into the reload, which then drains it.
        await self.sut.refresh()
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 75
        }
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 75)
        #expect(self.mockClient.getHistoryForceRefreshCount == 1) // the preserved generation forced a refetch
    }
}

// MARK: - RefreshTestGate

/// A one-shot async gate: `wait()` suspends until `open()` is called. Local to
/// this suite (the one in YouTubeHomeViewModelTests is file-private there).
private actor RefreshTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if self.isOpen { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func open() {
        self.isOpen = true
        let pending = self.waiters
        self.waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
