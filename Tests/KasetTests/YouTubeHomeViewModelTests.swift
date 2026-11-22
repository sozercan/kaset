import Foundation
import Testing
@testable import Kaset

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
                MockYouTubeClient.makeVideo(videoId: "video-1"),
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
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Music", continuation: "music-topic")]
        self.mockClient.homeTopicFeeds = [
            "music-topic": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 1), continuation: nil),
        ]
        await self.sut.load()
        #expect(self.mockClient.homeFeedCallCount == 1)

        await self.sut.refresh()

        #expect(self.mockClient.homeFeedCallCount == 2)
        #expect(self.mockClient.homeBundleForceRefreshes == [false, true])
        #expect(self.mockClient.requestedTopicForceRefreshes == [false, true])
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)
        #expect(self.sut.loadingState == .loaded)
    }

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
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        let historyGate = AsyncGate()
        self.mockClient.beforeHistoryReturn = { await historyGate.wait() }

        async let loadDone: Void = self.sut.load()

        while !self.sut.sections.contains(where: { $0.kind == .topic }) {
            await Task.yield()
        }
        #expect(self.sut.sections.map(\.kind) == [.topic])

        await historyGate.open()
        await loadDone
        #expect(self.sut.sections.map(\.kind) == [.continueWatching, .topic])
    }

    @Test("Topic rails publish incrementally and still end in chip order")
    func railsPublishIncrementallyInOrder() async {
        self.mockClient.homeChips = [
            YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming"),
            YouTubeHomeChip(title: "Music", continuation: "tok-music"),
        ]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 3), continuation: nil),
            "tok-music": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 3), continuation: nil),
        ]

        let gamingGate = AsyncGate()
        self.mockClient.beforeTopicReturn = { continuation in
            if continuation == "tok-gaming" {
                await gamingGate.wait()
            }
        }

        async let loadDone: Void = self.sut.load()

        while self.sut.sections.first(where: { $0.kind == .topic })?.title != "Music" {
            await Task.yield()
        }
        #expect(self.sut.sections.map(\.title) == ["Music"])

        await gamingGate.open()
        await loadDone
        #expect(self.sut.sections.map(\.title) == ["Gaming", "Music"])
    }

    @Test("Cold load fetches only the first topic batch")
    func coldLoadFetchesOnlyFirstTopicBatch() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = (0 ..< 8).map { index in
            YouTubeHomeChip(title: "Topic \(index)", continuation: "tok-\(index)")
        }
        self.mockClient.homeTopicFeeds = Dictionary(uniqueKeysWithValues: (0 ..< 8).map { index in
            ("tok-\(index)", YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil))
        })

        await self.sut.load()

        #expect(Set(self.mockClient.requestedTopicContinuations) == Set(["tok-0", "tok-1"]))
        #expect(self.mockClient.requestedTopicContinuations.count == 2)
        #expect(self.sut.sections.filter { $0.kind == .topic }.map(\.title) == ["Topic 0", "Topic 1"])
        #expect(self.sut.hasMoreTopicRails)
        #expect(self.sut.isLoadingTopicRails == false)
    }

    @Test("Deferred topic rails load in explicit batches without duplicate requests")
    func deferredTopicRailsLoadInBatches() async throws {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = (0 ..< 6).map { index in
            YouTubeHomeChip(title: "Topic \(index)", continuation: "tok-\(index)")
        }
        self.mockClient.homeTopicFeeds = Dictionary(uniqueKeysWithValues: (0 ..< 6).map { index in
            ("tok-\(index)", YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil))
        })

        await self.sut.load()
        try #require(self.sut.hasMoreTopicRails)

        let batchStarted = AsyncGate()
        let releaseBatch = AsyncGate()
        self.mockClient.beforeTopicReturn = { continuation in
            guard continuation == "tok-2" || continuation == "tok-3" else { return }
            await batchStarted.open()
            await releaseBatch.wait()
        }
        async let firstBatch: Void = self.sut.loadMoreTopicRails()
        await batchStarted.wait()
        await self.sut.loadMoreTopicRails()
        await releaseBatch.open()
        await firstBatch
        self.mockClient.beforeTopicReturn = nil

        #expect(Set(self.mockClient.requestedTopicContinuations) == Set(["tok-0", "tok-1", "tok-2", "tok-3"]))
        #expect(self.mockClient.requestedTopicContinuations.count == 4)
        #expect(self.sut.sections.filter { $0.kind == .topic }.map(\.title) == [
            "Topic 0",
            "Topic 1",
            "Topic 2",
            "Topic 3",
        ])
        #expect(self.sut.hasMoreTopicRails)

        await self.sut.loadMoreTopicRails()
        #expect(Set(self.mockClient.requestedTopicContinuations) == Set([
            "tok-0",
            "tok-1",
            "tok-2",
            "tok-3",
            "tok-4",
            "tok-5",
        ]))
        #expect(self.mockClient.requestedTopicContinuations.count == 6)
        #expect(self.sut.hasMoreTopicRails == false)
    }

    @Test("Deferred topic auto-load skips empty batches")
    func deferredTopicAutoLoadSkipsEmptyBatches() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = (0 ..< 6).map { index in
            YouTubeHomeChip(title: "Topic \(index)", continuation: "tok-\(index)")
        }
        self.mockClient.homeTopicFeeds = [
            "tok-0": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
            "tok-1": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
            "tok-2": .empty,
            "tok-3": .empty,
            "tok-4": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
            "tok-5": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        await self.sut.load()
        await self.sut.loadMoreTopicRails()

        #expect(Set(self.mockClient.requestedTopicContinuations) == Set([
            "tok-0",
            "tok-1",
            "tok-2",
            "tok-3",
            "tok-4",
            "tok-5",
        ]))
        #expect(self.mockClient.requestedTopicContinuations.count == 6)
        #expect(self.sut.sections.filter { $0.kind == .topic }.map(\.title) == [
            "Topic 0",
            "Topic 1",
            "Topic 4",
            "Topic 5",
        ])
        #expect(self.sut.hasMoreTopicRails == false)
    }

    @Test("Deferred topic auto-load preserves successes and retries only failed chips")
    func deferredTopicAutoLoadPreservesSuccessesAndRetriesOnlyFailedChips() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = (0 ..< 6).map { index in
            YouTubeHomeChip(title: "Topic \(index)", continuation: "tok-\(index)")
        }
        self.mockClient.homeTopicFeeds = Dictionary(uniqueKeysWithValues: (0 ..< 6).map { index in
            ("tok-\(index)", YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil))
        })
        self.mockClient.homeTopicError = (
            continuation: "tok-2",
            error: YTMusicError.networkError(underlying: URLError(.timedOut))
        )

        await self.sut.load()
        await self.sut.loadMoreTopicRails()

        #expect(Set(self.mockClient.requestedTopicContinuations) == Set(["tok-0", "tok-1", "tok-2", "tok-3"]))
        #expect(self.mockClient.requestedTopicContinuations.count == 4)
        #expect(self.sut.sections.filter { $0.kind == .topic }.map(\.title) == ["Topic 0", "Topic 1", "Topic 3"])
        #expect(self.sut.hasMoreTopicRails)

        await self.sut.loadMoreTopicRails()

        #expect(self.mockClient.requestedTopicContinuations.count(where: { $0 == "tok-2" }) == 1)
        #expect(self.mockClient.requestedTopicContinuations.count(where: { $0 == "tok-3" }) == 1)
        #expect(self.mockClient.requestedTopicContinuations.contains("tok-4"))
        #expect(self.mockClient.requestedTopicContinuations.contains("tok-5"))
        #expect(self.sut.sections.filter { $0.kind == .topic }.map(\.title) == [
            "Topic 0",
            "Topic 1",
            "Topic 3",
            "Topic 4",
            "Topic 5",
        ])
        #expect(self.sut.hasMoreTopicRails)

        self.mockClient.homeTopicError = nil
        await self.sut.loadMoreTopicRails()

        #expect(self.mockClient.requestedTopicContinuations.count(where: { $0 == "tok-2" }) == 2)
        #expect(self.mockClient.requestedTopicContinuations.count(where: { $0 == "tok-3" }) == 1)
        #expect(self.sut.sections.filter { $0.kind == .topic }.map(\.title) == [
            "Topic 0",
            "Topic 1",
            "Topic 3",
            "Topic 4",
            "Topic 5",
            "Topic 2",
        ])
        #expect(self.sut.hasMoreTopicRails == false)
    }

    @Test("Deferred topic auto-load stops after a batch-wide request failure")
    func deferredTopicAutoLoadStopsAfterBatchWideFailure() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = (0 ..< 6).map { index in
            YouTubeHomeChip(title: "Topic \(index)", continuation: "tok-\(index)")
        }
        self.mockClient.homeTopicFeeds = Dictionary(uniqueKeysWithValues: (0 ..< 6).map { index in
            ("tok-\(index)", YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil))
        })

        await self.sut.load()
        let requestError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))
        self.mockClient.homeTopicErrors = [
            "tok-2": requestError,
            "tok-3": requestError,
            "tok-4": requestError,
            "tok-5": requestError,
        ]
        await self.sut.loadMoreTopicRails()

        #expect(Set(self.mockClient.requestedTopicContinuations) == Set(["tok-0", "tok-1", "tok-2", "tok-3"]))
        #expect(self.mockClient.requestedTopicContinuations.count == 4)
        #expect(self.mockClient.requestedTopicContinuations.contains("tok-4") == false)
        #expect(self.mockClient.requestedTopicContinuations.contains("tok-5") == false)
        #expect(self.sut.sections.filter { $0.kind == .topic }.map(\.title) == ["Topic 0", "Topic 1"])
        #expect(self.sut.hasMoreTopicRails)
    }

    @Test("Empty first topic batch walks queued chips before falling back")
    func emptyFirstTopicBatchWalksQueuedChips() async {
        self.mockClient.homeFeed = .empty
        self.mockClient.homeChips = (0 ..< 4).map { index in
            YouTubeHomeChip(title: "Topic \(index)", continuation: "tok-\(index)")
        }
        self.mockClient.homeTopicFeeds = [
            "tok-0": .empty,
            "tok-1": .empty,
            "tok-2": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
            "tok-3": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        await self.sut.load()

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.sections.filter { $0.kind == .topic }.map(\.title) == ["Topic 2", "Topic 3"])
        #expect(Set(self.mockClient.requestedTopicContinuations) == Set(["tok-0", "tok-1", "tok-2", "tok-3"]))
        #expect(self.mockClient.requestedTopicContinuations.count == 4)
        #expect(self.mockClient.destinationFeedCallCount == 0)
        #expect(self.sut.hasMoreTopicRails == false)
    }

    @Test("Grid, shelves, and chips come from a single coalesced home fetch")
    func homeFetchedOncePerLoad() async {
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

        #expect(self.mockClient.homeFeedCallCount == 1)
        #expect(self.mockClient.homeChipsCallCount == 0)
        #expect(self.sut.sections.map(\.kind) == [.shelf, .topic])
    }

    @Test("Shelf videos are excluded from the For You grid (no double render)")
    func shelfVideosExcludedFromGrid() async {
        let shelfVideo = MockYouTubeClient.makeVideo(videoId: "shelf-vid")
        let gridOnly = MockYouTubeClient.makeVideo(videoId: "grid-only")
        self.mockClient.homeFeed = YouTubeFeed(
            videos: [shelfVideo, gridOnly],
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

        #expect(self.sut.videos.map(\.videoId) == ["grid-only"])
        let shelf = self.sut.sections.first { $0.kind == .shelf }
        #expect(shelf?.videos.map(\.videoId) == ["shelf-vid"])
    }

    @Test("Pagination stays reachable when shelves empty the first grid page")
    func paginationReachableWithEmptyGrid() async {
        let shelfVideo = MockYouTubeClient.makeVideo(videoId: "shelf-vid")
        self.mockClient.homeFeed = YouTubeFeed(videos: [shelfVideo], continuation: "page2")
        self.mockClient.homeShelves = [
            YouTubeHomeSection(id: "shelf-1", title: "Breaking news", videos: [shelfVideo], kind: .shelf),
        ]
        self.mockClient.homeFeedContinuation = YouTubeFeed(
            videos: [shelfVideo, MockYouTubeClient.makeVideo(videoId: "page2-vid")],
            continuation: nil
        )

        await self.sut.load()
        #expect(self.sut.videos.isEmpty)
        #expect(self.sut.hasMoreVideos)

        await self.sut.loadMore()
        #expect(self.sut.videos.map(\.videoId) == ["page2-vid"])
        #expect(self.sut.hasMoreVideos == false)
    }

    @Test("loadMore walks past a fully-filtered continuation page")
    func loadMoreSkipsFullyFilteredPage() async {
        let shelfVideo = MockYouTubeClient.makeVideo(videoId: "shelf-vid")
        self.mockClient.homeFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "grid-0")],
            continuation: "more"
        )
        self.mockClient.homeShelves = [
            YouTubeHomeSection(id: "shelf-1", title: "Breaking news", videos: [shelfVideo], kind: .shelf),
        ]
        self.mockClient.homeContinuationPages = [
            YouTubeFeed(videos: [shelfVideo], continuation: "still-more"),
            YouTubeFeed(videos: [MockYouTubeClient.makeVideo(videoId: "pageB-vid")], continuation: nil),
        ]

        await self.sut.load()
        #expect(self.sut.videos.map(\.videoId) == ["grid-0"])
        #expect(self.sut.hasMoreVideos)

        await self.sut.loadMore()

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

    @Test("Empty signed-out home loads public guest fallback rails")
    func emptyHomeLoadsGuestFallbackRails() async {
        self.mockClient.homeFeed = .empty
        self.mockClient.homeChips = []
        self.mockClient.homeShelves = []
        self.mockClient.destinationFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "guest-public")],
            continuation: nil
        )

        await self.sut.load()

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.isEmpty)
        #expect(self.sut.hasMoreVideos == false)
        #expect(self.mockClient.destinationFeedCallCount == 4)
        #expect(self.sut.sections.map(\.id) == ["guest-news", "guest-sports", "guest-gaming", "guest-learning"])
        #expect(self.sut.sections.allSatisfy { $0.kind == .shelf })
        #expect(self.sut.sections.allSatisfy { $0.videos.map(\.videoId) == ["guest-public"] })
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
        self.mockClient.homeFeed = .empty
        self.mockClient.historyFeed = .empty
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }

        async let loadDone: Void = self.sut.load()

        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }
        #expect(self.sut.loadingState != .loaded)
        #expect(self.sut.sections.isEmpty)

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

        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }

        async let loadDone: Void = self.sut.load()

        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.sections.isEmpty)

        await gate.open()
        await loadDone
        #expect(self.sut.sections.map(\.kind) == [.topic])
    }

    @Test("Cancelling the load task does not abort the persistent load")
    func cancellingTaskDoesNotAbortLoad() async {
        self.mockClient.homeFeed = .empty
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }

        let task = Task { await self.sut.load() }

        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }
        task.cancel()
        await gate.open()
        await task.value

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

        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }
        let first = Task { await self.sut.load() }
        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }

        self.mockClient.beforeTopicReturn = nil
        await self.sut.refresh()
        await gate.open()
        _ = await first.value

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.sections.map(\.kind) == [.topic])
    }

    @Test("A stale run resuming after refresh does not break single-flight")
    func staleRunResumeKeepsSingleFlight() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }
        let first = Task { await self.sut.load() }
        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }

        self.mockClient.beforeTopicReturn = nil
        await self.sut.refresh()
        let fetchesAfterRefresh = self.mockClient.homeFeedCallCount

        await gate.open()
        _ = await first.value

        await self.sut.load()
        #expect(self.sut.loadingState == .loaded)
        #expect(self.mockClient.homeFeedCallCount == fetchesAfterRefresh)
    }

    @Test("A repeated load (task restart) preserves the rails without refetching")
    func repeatedLoadPreservesRails() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        await self.sut.load()
        #expect(self.sut.sections.map(\.kind) == [.topic])
        #expect(self.mockClient.homeFeedCallCount == 1)

        await self.sut.load()
        #expect(self.sut.sections.map(\.kind) == [.topic])
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.loadingState == .loaded)
        #expect(self.mockClient.homeFeedCallCount == 1)
    }

    @Test("Concurrent loads with the first cancelled still finish loaded (no stuck skeleton)")
    func concurrentLoadsFirstCancelledStillLoads() async {
        self.mockClient.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        self.mockClient.homeChips = [YouTubeHomeChip(title: "Gaming", continuation: "tok-gaming")]
        self.mockClient.homeTopicFeeds = [
            "tok-gaming": YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil),
        ]

        let gate = AsyncGate()
        self.mockClient.beforeTopicReturn = { _ in await gate.wait() }

        let first = Task { await self.sut.load() }
        while self.mockClient.requestedTopicContinuations.isEmpty {
            await Task.yield()
        }
        let second = Task { await self.sut.load() }
        await Task.yield()
        first.cancel()

        await gate.open()
        _ = await first.value
        await second.value

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.sections.map(\.kind) == [.topic])
        #expect(self.mockClient.homeFeedCallCount == 1)
    }
}
