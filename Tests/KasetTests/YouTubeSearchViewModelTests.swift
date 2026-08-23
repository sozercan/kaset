import Foundation
import Testing
@testable import Kaset

// MARK: - YouTubeSearchViewModelTests

@Suite("YouTubeSearchViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeSearchViewModelTests {
    let mockClient: MockYouTubeClient
    let sut: YouTubeSearchViewModel

    init() {
        self.mockClient = MockYouTubeClient()
        self.sut = YouTubeSearchViewModel(client: self.mockClient)
    }

    @Test("Search sends the query and selected filter to the client")
    func searchSendsQueryAndFilter() async {
        self.mockClient.searchResponse = YouTubeSearchResponse(
            videos: MockYouTubeClient.makeVideos(count: 2),
            channels: [],
            playlists: [],
            continuation: nil
        )
        self.sut.query = "swift"
        self.sut.selectedFilter = .videos

        await self.sut.search()

        #expect(self.mockClient.lastSearchQuery == "swift")
        #expect(self.mockClient.lastSearchFilter == .videos)
        #expect(self.sut.results.videos.count == 2)
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("Empty query does not hit the client")
    func emptyQuerySkipsSearch() async {
        self.sut.query = "   "

        await self.sut.search()

        #expect(self.mockClient.searchCallCount == 0)
        #expect(self.sut.loadingState == .idle)
    }

    @Test("Clearing the query resets results")
    func clearingQueryResets() async {
        self.mockClient.searchResponse = YouTubeSearchResponse(
            videos: MockYouTubeClient.makeVideos(count: 1),
            channels: [],
            playlists: [],
            continuation: nil
        )
        self.sut.query = "swift"
        await self.sut.search()
        #expect(!self.sut.results.isEmpty)

        self.sut.query = ""

        #expect(self.sut.results.isEmpty)
        #expect(self.sut.loadingState == .idle)
    }

    @Test("Search failure surfaces an error state")
    func searchFailure() async {
        self.mockClient.error = YTMusicError.authExpired
        self.sut.query = "swift"

        await self.sut.search()

        if case .error = self.sut.loadingState {
            // expected
        } else {
            Issue.record("Expected error state, got \(self.sut.loadingState)")
        }
    }

    @Test("LoadMore appends continuation results without duplicates")
    func loadMoreAppends() async {
        self.mockClient.searchResponse = YouTubeSearchResponse(
            videos: MockYouTubeClient.makeVideos(count: 2),
            channels: [],
            playlists: [],
            continuation: "token"
        )
        self.mockClient.searchContinuation = YouTubeSearchResponse(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "video-0"), // duplicate
                MockYouTubeClient.makeVideo(videoId: "video-extra"),
            ],
            channels: [],
            playlists: [],
            continuation: nil
        )
        self.sut.query = "swift"
        await self.sut.search()

        await self.sut.loadMore()

        #expect(self.sut.results.videos.map(\.videoId) == ["video-0", "video-1", "video-extra"])
        #expect(self.sut.results.continuation == nil)
    }

    @Test("Concurrent submits coalesce to one in-flight search")
    func concurrentSubmitsCoalesce() async {
        let gate = AsyncGate()
        self.mockClient.searchResponse = YouTubeSearchResponse(
            videos: [MockYouTubeClient.makeVideo(videoId: "coalesced")],
            channels: [],
            playlists: [],
            continuation: nil
        )
        self.mockClient.beforeSearchReturn = { _, _ in await gate.wait() }
        self.sut.query = "swift"

        let first = Task { await self.sut.search() }
        await self.waitUntil(self.mockClient.searchCallCount == 1)

        let second = Task { await self.sut.search() }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(self.mockClient.searchCallCount == 1)

        await gate.open()
        await first.value
        await second.value
        #expect(self.sut.results.videos.map(\.videoId) == ["coalesced"])
    }

    @Test("Cancelling one coalesced search waiter does not cancel shared request")
    func cancellingOneCoalescedSearchWaiterDoesNotCancelSharedRequest() async {
        let gate = AsyncGate()
        self.mockClient.searchResponse = YouTubeSearchResponse(
            videos: [MockYouTubeClient.makeVideo(videoId: "survived")],
            channels: [],
            playlists: [],
            continuation: "next-token"
        )
        self.mockClient.beforeSearchReturn = { _, _ in await gate.wait() }
        self.sut.query = "swift"

        let first = Task { await self.sut.search() }
        await self.waitUntil(self.mockClient.searchCallCount == 1)
        let second = Task { await self.sut.search() }
        await Task.yield()

        first.cancel()
        await Task.yield()
        #expect(self.mockClient.searchCallCount == 1)

        await gate.open()
        await first.value
        await second.value

        #expect(self.sut.results.videos.map(\.videoId) == ["survived"])
        #expect(self.sut.results.continuation == "next-token")
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("Late results from an older query cannot overwrite the newer query")
    func lateOlderQueryCannotOverwriteNewerQuery() async {
        let oldQueryGate = AsyncGate()
        self.mockClient.searchResponsesByRequest = [
            MockYouTubeClient.searchKey(query: "swift", filter: .all): YouTubeSearchResponse(
                videos: [MockYouTubeClient.makeVideo(videoId: "old-query")],
                channels: [],
                playlists: [],
                continuation: "old-token"
            ),
            MockYouTubeClient.searchKey(query: "swiftui", filter: .all): YouTubeSearchResponse(
                videos: [MockYouTubeClient.makeVideo(videoId: "new-query")],
                channels: [],
                playlists: [],
                continuation: "new-token"
            ),
        ]
        self.mockClient.beforeSearchReturn = { query, _ in
            if query == "swift" {
                await oldQueryGate.wait()
            }
        }

        self.sut.query = "swift"
        let oldSearch = Task { await self.sut.search() }
        await self.waitUntil(self.mockClient.lastSearchQuery == "swift")

        self.sut.query = "swiftui"
        await self.sut.search()

        #expect(self.sut.results.videos.map(\.videoId) == ["new-query"])
        #expect(self.sut.results.continuation == "new-token")

        await oldQueryGate.open()
        await oldSearch.value

        #expect(self.sut.results.videos.map(\.videoId) == ["new-query"])
        #expect(self.sut.results.continuation == "new-token")
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("Stale pagination cannot append into newer search results")
    func stalePaginationCannotCorruptNewerSearchContinuation() async {
        let paginationGate = AsyncGate()
        self.mockClient.searchResponsesByRequest = [
            MockYouTubeClient.searchKey(query: "swift", filter: .all): YouTubeSearchResponse(
                videos: [MockYouTubeClient.makeVideo(videoId: "old-query")],
                channels: [],
                playlists: [],
                continuation: "old-token"
            ),
            MockYouTubeClient.searchKey(query: "swiftui", filter: .all): YouTubeSearchResponse(
                videos: [MockYouTubeClient.makeVideo(videoId: "new-query")],
                channels: [],
                playlists: [],
                continuation: "new-token"
            ),
        ]

        self.sut.query = "swift"
        await self.sut.search()
        self.mockClient.searchContinuation = YouTubeSearchResponse(
            videos: [MockYouTubeClient.makeVideo(videoId: "old-page")],
            channels: [],
            playlists: [],
            continuation: "old-next-token"
        )
        self.mockClient.beforeSearchContinuationReturn = { await paginationGate.wait() }

        let oldPage = Task { await self.sut.loadMore() }
        await self.waitUntil(self.sut.loadingState == .loadingMore)

        self.sut.query = "swiftui"
        let newSearch = Task { await self.sut.search() }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        await paginationGate.open()
        await oldPage.value
        await newSearch.value

        #expect(self.sut.results.videos.map(\.videoId) == ["new-query"])
        #expect(self.sut.results.continuation == "new-token")
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("Late results from an older filter cannot corrupt newer filter continuation")
    func lateOlderFilterCannotOverwriteNewerFilterOrContinuation() async {
        let oldFilterGate = AsyncGate()
        self.mockClient.searchResponsesByRequest = [
            MockYouTubeClient.searchKey(query: "swift", filter: .videos): YouTubeSearchResponse(
                videos: [MockYouTubeClient.makeVideo(videoId: "old-videos")],
                channels: [],
                playlists: [],
                continuation: "videos-token"
            ),
            MockYouTubeClient.searchKey(query: "swift", filter: .channels): YouTubeSearchResponse(
                videos: [],
                channels: [YouTubeChannel(channelId: "new-channel", name: "New Channel")],
                playlists: [],
                continuation: "channels-token"
            ),
        ]
        self.mockClient.beforeSearchReturn = { _, filter in
            if filter == .videos {
                await oldFilterGate.wait()
            }
        }

        self.sut.selectedFilter = .videos
        self.sut.query = "swift"
        let oldSearch = Task { await self.sut.search() }
        await self.waitUntil(self.mockClient.lastSearchFilter == .videos)

        self.sut.selectedFilter = .channels
        await self.waitUntil(self.sut.results.channels.map(\.channelId) == ["new-channel"])

        #expect(self.sut.results.channels.map(\.channelId) == ["new-channel"])
        #expect(self.sut.results.continuation == "channels-token")

        await oldFilterGate.open()
        await oldSearch.value

        #expect(self.sut.results.channels.map(\.channelId) == ["new-channel"])
        #expect(self.sut.results.videos.isEmpty)
        #expect(self.sut.results.continuation == "channels-token")
        #expect(self.sut.loadingState == .loaded)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0 ..< 1000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for condition")
    }
}
