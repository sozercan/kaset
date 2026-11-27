import Foundation
import Testing
@testable import Kaset

@Suite("YouTubeHome Continue Watching refresh", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeHomeContinueWatchingRefreshTests {
    let mockClient: MockYouTubeClient
    let sut: YouTubeHomeViewModel

    init() {
        self.mockClient = MockYouTubeClient()
        self.sut = YouTubeHomeViewModel(
            client: self.mockClient,
            continueWatchingRefreshDelay: .zero,
            continueWatchingRefreshRetryDelay: .zero
        )
    }

    private func makeRefreshDelaysInstant() {}

    private func waitForCondition(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Watching a video to completion removes it from Continue Watching on return")
    func refreshRemovesFinishedVideo() async {
        self.makeRefreshDelaysInstant()
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
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)
    }

    @Test("Watching a video partway adds it to Continue Watching on return")
    func refreshAddsPartiallyWatchedVideo() async {
        self.makeRefreshDelaysInstant()
        self.mockClient.historyFeed = .empty
        await self.sut.load()
        #expect(self.sut.sections.contains { $0.kind == .continueWatching } == false)

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
        #expect(self.sut.sections.first?.kind == .continueWatching)
    }

    @Test("Watching more of a still-unfinished video updates its progress in the rail")
    func refreshUpdatesProgressForSameVideo() async {
        self.makeRefreshDelaysInstant()
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 30)

        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 55)],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 55
        }

        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 55)
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)
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

        self.sut.refreshContinueWatching(forGeneration: 0)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 0)

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

        self.sut.refreshContinueWatching(forGeneration: 1)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)

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

        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 55)],
            continuation: nil
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 55
        }
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)

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
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.map(\.videoId) == ["resume"])

        self.mockClient.historyForceRefreshError = YTMusicError.networkError(
            underlying: URLError(.timedOut)
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition { self.mockClient.getHistoryForceRefreshCount == 2 }

        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.map(\.videoId) == ["resume"])
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("A failed refresh does not advance the watermark, so a later return retries")
    func failedRefreshLeavesWatermarkRetryable() async {
        self.makeRefreshDelaysInstant()
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()

        self.mockClient.historyForceRefreshError = YTMusicError.networkError(
            underlying: URLError(.timedOut)
        )
        self.sut.refreshContinueWatching(forGeneration: 1)
        await self.waitForCondition { self.mockClient.getHistoryForceRefreshCount == 2 }

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
        #expect(self.mockClient.getHistoryForceRefreshCount == 3)
    }

    @Test("Cancelling the refresh mid-delay does not advance the watermark")
    func cancelledRefreshLeavesWatermarkRetryable() async {
        self.sut.continueWatchingRefreshDelayOverride = .seconds(60)
        self.sut.continueWatchingRefreshRetryDelayOverride = .zero
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()

        self.sut.refreshContinueWatching(forGeneration: 1)
        self.sut.cancelLoad()
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 0)

        self.sut.continueWatchingRefreshDelayOverride = .zero
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
        self.sut.refreshContinueWatching(forGeneration: 1)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 0)
        #expect(self.sut.sections.isEmpty)
    }

    @Test("A watch during cold Home load forces a cache-bypassed rail refresh once loaded")
    func pendingRefreshRunsAfterColdLoad() async {
        self.makeRefreshDelaysInstant()
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        self.mockClient.historyForceRefreshFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 65)],
            continuation: nil
        )

        self.sut.refreshContinueWatching(forGeneration: 1)
        #expect(self.mockClient.getHistoryForceRefreshCount == 0)

        await self.sut.load()
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 65
        }

        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 65)
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)

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
        self.mockClient.homeFeedContinuation = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 2),
            continuation: nil
        )
        await self.sut.load()
        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.hasMoreVideos)

        let gate = RefreshTestGate()
        self.mockClient.beforeContinuationReturn = { await gate.wait() }
        let paging = Task { await self.sut.loadMore() }
        await self.waitForCondition { self.sut.loadingState == .loadingMore }
        #expect(self.sut.loadingState == .loadingMore)

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
        await self.waitForCondition { self.sut.loadingState == .loaded }

        self.sut.refreshContinueWatching(forGeneration: 1)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 0)

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
        self.sut.continueWatchingRefreshDelayOverride = .seconds(60)
        self.sut.continueWatchingRefreshRetryDelayOverride = .zero
        self.mockClient.historyFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 30)],
            continuation: nil
        )
        await self.sut.load()

        self.sut.refreshContinueWatching(forGeneration: 1)
        await Task.yield()
        #expect(self.mockClient.getHistoryForceRefreshCount == 0)

        self.sut.continueWatchingRefreshDelayOverride = .zero
        self.mockClient.historyForceRefreshFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "resume", watchedPercent: 75)],
            continuation: nil
        )

        await self.sut.refresh()
        await self.waitForCondition {
            self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 75
        }
        #expect(self.sut.sections.first { $0.kind == .continueWatching }?.videos.first?.watchedPercent == 75)
        #expect(self.mockClient.getHistoryForceRefreshCount == 1)
    }
}

private actor RefreshTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if self.isOpen {
            return
        }
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
