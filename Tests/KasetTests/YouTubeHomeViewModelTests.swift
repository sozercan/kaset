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

    @Test("A cancelled load aborts instead of publishing empty rails")
    func cancelledLoadAbortsRails() async {
        // Empty grid so the worst case is exercised: a cancelled load must not
        // mark the empty grid `.loaded` or publish empty sections.
        self.mockClient.homeFeed = .empty
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        // Hold the topic rail open until the test cancels the load.
        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }

        let task = Task { await self.sut.load() }

        // Wait until the rail fetch is in flight, then cancel mid-load.
        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }
        task.cancel()
        await gate.open()
        await task.value

        // The load was cancelled: it must reset to idle and publish nothing,
        // rather than leaving an empty grid `.loaded` with no rails.
        #expect(self.sut.loadingState == .idle)
        #expect(self.sut.sections.isEmpty)
    }

    @Test("A reload clears stale rails before showing the new grid")
    func reloadClearsStaleRailsBeforeNewGrid() async {
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

        // Second load (e.g. a `.task` restart) with the rail held open: the new
        // grid must publish with the stale rail already cleared, not lingering.
        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }

        async let reloadDone: Void = self.sut.load()
        while self.mockClient.requestedTopicContinuations.count < 2 {
            await Task.yield()
        }

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.sections.isEmpty) // stale rail cleared, not shown above the new grid

        await gate.open()
        await reloadDone
        #expect(self.sut.sections.map(\.kind) == [.topic]) // fresh rail repopulates
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
