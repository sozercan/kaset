import Foundation
import Testing
@testable import Kaset

// MARK: - YouTubeHomeViewModelTests

@Suite("YouTubeHomeViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeHomeViewModelTests {
    let mockClient: MockYouTubeClient
    let sut: YouTubeHomeViewModel

    init() {
        self.mockClient = MockYouTubeClient()
        self.sut = YouTubeHomeViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle and empty")
    func initialState() {
        #expect(self.sut.loadingState == .idle)
        #expect(self.sut.videos.isEmpty)
    }

    @Test("Load populates videos from the client")
    func loadPopulatesVideos() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )

        await self.sut.load()

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.hasMoreVideos == false)
    }

    @Test("Load failure surfaces an error state")
    func loadFailure() async {
        self.mockClient.error = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.sut.load()

        if case .error = self.sut.loadingState {
            // expected
        } else {
            Issue.record("Expected error state, got \(self.sut.loadingState)")
        }
        #expect(self.sut.videos.isEmpty)
    }

    @Test("LoadMore appends new videos and skips duplicates")
    func loadMoreAppendsAndDeduplicates() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 2),
            continuation: "token"
        )
        self.mockClient.homeFeedContinuation = YouTubeFeed(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "video-1"), // duplicate
                MockYouTubeClient.makeVideo(videoId: "video-new"),
            ],
            continuation: nil
        )

        await self.sut.load()
        #expect(self.sut.hasMoreVideos)

        await self.sut.loadMore()

        #expect(self.sut.videos.map(\.videoId) == ["video-0", "video-1", "video-new"])
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("Refresh reloads from scratch")
    func refreshReloads() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 1),
            continuation: nil
        )
        await self.sut.load()
        #expect(self.mockClient.homeFeedCallCount == 1)

        await self.sut.refresh()

        #expect(self.mockClient.homeFeedCallCount == 2)
        #expect(self.sut.loadingState == .loaded)
    }

    // MARK: - Sections

    @Test("Continue Watching keeps only videos started but not finished")
    func continueWatchingFiltersByProgress() async {
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "started", watchedPercent: 40),
                MockYouTubeClient.makeVideo(videoId: "edge-1", watchedPercent: 1),
                MockYouTubeClient.makeVideo(videoId: "edge-95", watchedPercent: 95),
                MockYouTubeClient.makeVideo(videoId: "finished", watchedPercent: 96),
                MockYouTubeClient.makeVideo(videoId: "fully", watchedPercent: 100),
                MockYouTubeClient.makeVideo(videoId: "not-started", watchedPercent: nil),
                MockYouTubeClient.makeVideo(videoId: "zero", watchedPercent: 0),
                MockYouTubeClient.makeVideo(videoId: "short", isShort: true, watchedPercent: 50),
                MockYouTubeClient.makeVideo(videoId: "live", isLive: true, watchedPercent: 50),
            ],
            continuation: nil
        )

        await self.sut.load()

        let section = self.sut.sections.first { $0.kind == .continueWatching }
        #expect(section != nil)
        #expect(section?.videos.map(\.videoId) == ["started", "edge-1", "edge-95"])
    }

    @Test("Continue Watching section is omitted when nothing is resumable")
    func continueWatchingOmittedWhenEmpty() async {
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "finished", watchedPercent: 100)],
            continuation: nil
        )

        await self.sut.load()

        #expect(self.sut.sections.contains { $0.kind == .continueWatching } == false)
    }

    @Test("Sections are ordered: continue watching, shelves, then topics")
    func sectionOrdering() async {
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
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
        self.mockClient.homeChips = [
            YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming"),
            YouTubeHomeChip(title: "Music", continuation: "tok-music"),
        ]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 3), continuation: nil),
            "tok-music": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 3), continuation: nil),
        ]

        await self.sut.load()

        #expect(self.sut.sections.map(\.kind) == [.continueWatching, .shelf, .topic, .topic])
        #expect(self.sut.sections.map(\.title) == ["Continue Watching", "Breaking news", "Gaming", "Music"])
    }

    @Test("Topic rails publish without waiting for a slow history fetch")
    func railsDoNotWaitForHistory() async {
        // Regression: Continue Watching reads watch history (a separate, possibly
        // slow/retrying request). It must NOT gate the topic rails — otherwise a
        // slow history call delays every row and, with an empty grid, keeps the
        // skeleton up. The history rail slots in at the front once it resolves.
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        // Hold history open until the test releases it.
        let historyGate = AsyncGate()
        self.mockClient.beforeHistoryReturn = { await historyGate.wait() }

        async let loadDone: Void = self.sut.load()

        // The topic rail must appear while history is still blocked.
        while !self.sut.sections.contains(where: { $0.kind == .topic }) {
            await Task.yield()
        }
        #expect(self.sut.sections.map(\.kind) == [.topic]) // no Continue Watching yet

        // Release history; it slots in at the front.
        await historyGate.open()
        await loadDone
        #expect(self.sut.sections.map(\.kind) == [.continueWatching, .topic])
    }

    @Test("Topic rails publish incrementally and still end in chip order")
    func railsPublishIncrementallyInOrder() async {
        // Perceived-latency fix: rails stream in as each browse resolves (a row
        // shows as soon as ANY topic lands, not after the slowest), but the
        // published array always honors chip order. Here the FIRST chip resolves
        // LAST, so the second chip's rail must appear first and the first chip's
        // rail must slot in above it once it lands.
        self.mockClient.homeChips = [
            YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming"), // chip index 0
            YouTubeHomeChip(title: "Music", continuation: "tok-music"), // chip index 1
        ]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 3), continuation: nil),
            "tok-music": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 3), continuation: nil),
        ]

        // Hold the FIRST chip (Gaming) open until Music has been published, so
        // completion order is the reverse of chip order.
        let gamingGate = AsyncGate()
        self.mockClient.beforeTopicReturn = { continuation in
            if continuation == "tok-gaming" {
                await gamingGate.wait()
            }
        }

        async let loadDone: Void = self.sut.load()

        // Wait until Music has been published as the sole (out-of-order) rail.
        while self.sut.sections.first(where: { $0.kind == .topic })?.title != "Music" {
            await Task.yield()
        }
        #expect(self.sut.sections.map(\.title) == ["Music"]) // later chip shown first

        // Release Gaming; it must slot ABOVE Music to restore chip order.
        await gamingGate.open()
        await loadDone
        #expect(self.sut.sections.map(\.title) == ["Gaming", "Music"])
    }

    @Test("Grid, shelves, and chips come from a single coalesced home fetch")
    func homeFetchedOncePerLoad() async {
        // The grid, the titled shelves, and the chips that drive the topic rails
        // all live in one FEwhat_to_watch response; load() must fetch+parse it
        // once (getHomeBundle), not three times. Regression guard for the
        // load-time fix.
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
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
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        await self.sut.load()

        // One coalesced home fetch produced the grid, the shelf, and the chips.
        #expect(self.mockClient.homeFeedCallCount == 1)
        #expect(self.mockClient.homeChipsCallCount == 0) // chips came from the bundle, not a separate call
        #expect(self.sut.sections.map(\.kind) == [.shelf, .topic])
    }

    @Test("Shelf videos are excluded from the For You grid (no double render)")
    func shelfVideosExcludedFromGrid() async {
        // The parser collects shelf videos into feed.videos too; the shelf rail
        // surfaces them again. The grid must drop the shelf videos so they are
        // not rendered twice (once in the rail, once under "For you").
        let shelfVideo = MockYouTubeClient.makeVideo(videoId: "shelf-vid")
        let gridOnly = MockYouTubeClient.makeVideo(videoId: "grid-only")
        self.mockClient.homeFeed = YouTubeFeed(
            videos: [shelfVideo, gridOnly], // shelf-vid appears in both feed.videos and the shelf
            continuation: nil
        )
        self.mockClient.homeShelves = [
            YouTubeHomeSection(
                id: "shelf-1-Breaking news",
                title: "Breaking news",
                videos: [shelfVideo],
                kind: .shelf
            ),
        ]

        await self.sut.load()

        // Grid keeps only the non-shelf video; the shelf rail still has it.
        #expect(self.sut.videos.map(\.videoId) == ["grid-only"])
        let shelf = self.sut.sections.first { $0.kind == .shelf }
        #expect(shelf?.videos.map(\.videoId) == ["shelf-vid"])
    }

    @Test("Pagination stays reachable when shelves empty the first grid page")
    func paginationReachableWithEmptyGrid() async {
        // First page: every flat video also belongs to a shelf, so the grid is
        // empty after dedup — but a continuation exists. hasMoreVideos must stay
        // true so the view keeps the pagination sentinel and loadMore() works.
        let shelfVideo = MockYouTubeClient.makeVideo(videoId: "shelf-vid")
        self.mockClient.homeFeed = YouTubeFeed(videos: [shelfVideo], continuation: "page2")
        self.mockClient.homeShelves = [
            YouTubeHomeSection(id: "shelf-1", title: "Breaking news", videos: [shelfVideo], kind: .shelf),
        ]
        // Page 2 brings a fresh grid-only video (plus a shelf dup to verify the
        // shelf filter also applies to continuation pages).
        self.mockClient.homeFeedContinuation = YouTubeFeed(
            videos: [shelfVideo, MockYouTubeClient.makeVideo(videoId: "page2-vid")],
            continuation: nil
        )

        await self.sut.load()
        #expect(self.sut.videos.isEmpty) // first page fully filtered into the shelf
        #expect(self.sut.hasMoreVideos) // continuation still reachable

        await self.sut.loadMore()
        // Page 2's non-shelf video appears; the shelf dup is filtered out.
        #expect(self.sut.videos.map(\.videoId) == ["page2-vid"])
        #expect(self.sut.hasMoreVideos == false)
    }

    @Test("loadMore walks past a fully-filtered continuation page")
    func loadMoreSkipsFullyFilteredPage() async {
        let shelfVideo = MockYouTubeClient.makeVideo(videoId: "shelf-vid")
        // Grid starts non-empty so the sentinel exists.
        self.mockClient.homeFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "grid-0")],
            continuation: "more"
        )
        self.mockClient.homeShelves = [
            YouTubeHomeSection(id: "shelf-1", title: "Breaking news", videos: [shelfVideo], kind: .shelf),
        ]
        // Page A is entirely shelf videos (filters to nothing) but more remains;
        // page B has a real video. A single loadMore() must reach page B rather
        // than stalling on the empty page (the sentinel would not re-fire).
        self.mockClient.homeContinuationPages = [
            YouTubeFeed(videos: [shelfVideo], continuation: "still-more"),
            YouTubeFeed(videos: [MockYouTubeClient.makeVideo(videoId: "pageB-vid")], continuation: nil),
        ]

        await self.sut.load()
        #expect(self.sut.videos.map(\.videoId) == ["grid-0"])
        #expect(self.sut.hasMoreVideos)

        await self.sut.loadMore()

        // Walked past the fully-filtered page A to surface page B's video.
        #expect(self.sut.videos.map(\.videoId) == ["grid-0", "pageB-vid"])
        #expect(self.sut.hasMoreVideos == false)
    }

    @Test("A failing topic fetch omits only that rail")
    func failingTopicOmitsOnlyThatRail() async {
        self.mockClient.homeChips = [
            YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming"),
            YouTubeHomeChip(title: "Music", continuation: "tok-music"),
        ]
        self.mockClient.homeTopicFeeds = [
            "tok-music": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 3), continuation: nil),
        ]
        // Gaming throws; Music succeeds. (Note: `error` on the mock is global,
        // so use the per-continuation topic error to fail just one rail.)
        self.mockClient.homeTopicError = (
            continuation: "tok-gaming",
            error: YTMusicError.networkError(underlying: URLError(.timedOut))
        )

        await self.sut.load()

        let topics = self.sut.sections.filter { $0.kind == .topic }
        #expect(topics.map(\.title) == ["Music"])
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("Empty topic feeds are dropped")
    func emptyTopicFeedsDropped() async {
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = ["tok-gaming": .empty]

        await self.sut.load()

        #expect(self.sut.sections.contains { $0.kind == .topic } == false)
    }

    @Test("Topic-only sections still load when the grid is empty")
    func sectionsRenderWithEmptyGrid() async {
        self.mockClient.homeFeed = .empty
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        await self.sut.load()

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.isEmpty)
        #expect(self.sut.sections.map(\.kind) == [.topic])
    }

    @Test("Empty grid does not flash loaded before the topic rails arrive")
    func emptyGridDoesNotFlashLoadedEarly() async {
        // Regression: the first group result is often history returning nil (no
        // resumable watch history). With an empty grid and no shelves, flipping
        // `.loaded` on that empty first result would flash the "No
        // recommendations" state before the topic rows arrive. The skeleton must
        // stay until there is real content.
        self.mockClient.homeFeed = .empty // empty grid, no shelves
        self.mockClient.historyFeed = .empty // history resolves to nil (not resumable)
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        // Hold the topic rail open so we can observe the pre-rail state.
        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }

        async let loadDone: Void = self.sut.load()

        // Wait until the topic fetch is in flight (history has resolved to nil).
        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }
        // The empty history result must NOT have cleared the skeleton.
        #expect(self.sut.loadingState != .loaded)
        #expect(self.sut.sections.isEmpty)

        // Release the rail; now content exists and the model loads.
        await gate.open()
        await loadDone
        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.sections.map(\.kind) == [.topic])
    }

    @Test("The recommendation grid renders without waiting on slow topic rails")
    func gridRendersBeforeSlowRails() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        // Gate the topic rail open until the test releases it, simulating a
        // slow chip browse. The grid must publish before this resolves.
        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }

        async let loadDone: Void = self.sut.load()

        // Spin until the topic fetch is in flight (the rail is now blocked).
        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }

        // Grid is already rendered even though the rail has not returned.
        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.sections.isEmpty)

        // Release the rail and let load() finish; the section now appears.
        await gate.open()
        await loadDone
        #expect(self.sut.sections.map(\.kind) == [.topic])
    }

    @Test("Cancelling the load task does not abort the persistent load")
    func cancellingTaskDoesNotAbortLoad() async {
        // The view model outlives the view (it lives in YouTubeViewModelStore),
        // and SwiftUI restarts/cancels `.task` during launch/layout churn. A
        // cancelled `.task` closure must NOT abort the load — otherwise the
        // model is left stuck at `.idle` with nothing running (the cold-launch
        // stuck-skeleton bug). The load runs in an unstructured task that
        // survives outer cancellation and completes once.
        self.mockClient.homeFeed = .empty
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        // Hold the topic rail open until the test cancels the outer task.
        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }

        let task = Task { await self.sut.load() }

        // Wait until the rail fetch is in flight, then cancel the outer task.
        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }
        task.cancel()
        await gate.open()
        await task.value

        // The persistent load completed despite the outer cancellation: the
        // topic rail is published and the model is loaded, so returning to Home
        // shows content immediately instead of a stuck skeleton.
        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.sections.map(\.kind) == [.topic])
    }

    @Test("refresh() cancels the in-flight load and reloads from scratch")
    func refreshCancelsInFlightAndReloads() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        // Hold the first load's rail open, then refresh() while it is in flight.
        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }
        let first = Task { await self.sut.load() }
        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }

        // refresh() must cancel the stalled in-flight load and start fresh.
        self.mockClient.beforeTopicReturn = nil // second load's rail returns immediately
        await self.sut.refresh()
        await gate.open() // release the abandoned first load
        _ = await first.value

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.sections.map(\.kind) == [.topic])
    }

    @Test("A stale run resuming after refresh does not break single-flight")
    func staleRunResumeKeepsSingleFlight() async {
        // Regression for the unconditional `defer { loadTask = nil }`: when
        // refresh() cancels run #1 and starts run #2, run #1 resuming (its
        // network await throws on cancel) must NOT null run #2's handle. If it
        // did, a later load() would see loadTask == nil and start a DUPLICATE
        // getHomeBundle fetch. We assert exactly one extra fetch after the new
        // run settles and a subsequent load() is a no-op.
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        // Hold run #1's rail open so it is mid-flight when refresh() cancels it.
        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }
        let first = Task { await self.sut.load() }
        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }

        // refresh() cancels run #1 and runs #2 to completion (rail unblocked).
        self.mockClient.beforeTopicReturn = nil
        await self.sut.refresh()
        let fetchesAfterRefresh = self.mockClient.homeFeedCallCount

        // Release the abandoned run #1; its late `defer` must not clear run #2's
        // handle (token-gated). loadingState is now `.loaded`.
        await gate.open()
        _ = await first.value

        // A subsequent load() must be a no-op (state is .loaded) — no duplicate
        // fetch slips through from a nulled handle.
        await self.sut.load()
        #expect(self.sut.loadingState == .loaded)
        #expect(self.mockClient.homeFeedCallCount == fetchesAfterRefresh)
    }

    @Test("A repeated load (task restart) preserves the rails without refetching")
    func repeatedLoadPreservesRails() async {
        // Regression: SwiftUI restarts `.task` whenever the Home view's identity
        // changes (the YouTube detail column is `.id(selection)`, so navigating
        // away and back recreates the view while the view model persists). A
        // re-entrant load used to wipe the just-loaded rails and refetch them
        // slowly while the cached grid won instantly, so the rails never showed.
        // load() must now be idempotent: a restart is a no-op that keeps the
        // rails in place.
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        // First load fully populates a topic rail.
        await self.sut.load()
        #expect(self.sut.sections.map(\.kind) == [.topic])
        #expect(self.mockClient.homeFeedCallCount == 1)

        // A second load (e.g. a `.task` restart) is a no-op: the rails and grid
        // stay put and nothing is refetched. `refresh()` is the explicit reload.
        await self.sut.load()
        #expect(self.sut.sections.map(\.kind) == [.topic]) // rails preserved, not wiped
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.loadingState == .loaded)
        #expect(self.mockClient.homeFeedCallCount == 1) // no refetch
    }

    @Test("Concurrent loads with the first cancelled still finish loaded (no stuck skeleton)")
    func concurrentLoadsFirstCancelledStillLoads() async {
        // Reproduces the cold-launch deadlock the trace exposed: SwiftUI fired
        // `.task` twice ~18 ms apart; the restart cancelled the first load while
        // the second bailed on the old idle-guard, and the first's cancellation
        // reset state to `.idle` — leaving the model stuck with nothing running.
        // The single-flight load must survive: both callers coalesce onto one
        // run that completes regardless of the first task's cancellation.
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        // Hold the rail open so both `.task` firings overlap the in-flight load.
        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }

        let first = Task { await self.sut.load() } // .task fire #1
        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }
        let second = Task { await self.sut.load() } // .task fire #2 (the restart)
        await Task.yield()
        first.cancel() // SwiftUI cancels the superseded first closure

        await gate.open()
        _ = await first.value
        await second.value

        // Not stuck: the load completed and published grid + rail.
        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.sections.map(\.kind) == [.topic])
        #expect(self.mockClient.homeFeedCallCount == 1) // coalesced to one fetch
    }
}

// MARK: - AsyncGate

/// A one-shot async gate: `wait()` suspends until `open()` is called.
private actor AsyncGate {
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
