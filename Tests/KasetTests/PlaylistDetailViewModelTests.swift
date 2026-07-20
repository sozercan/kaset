// swiftlint:disable file_length
import Foundation
import Testing
@testable import Kaset

/// Tests for PlaylistDetailViewModel using mock client.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
// swiftlint:disable:next type_body_length
struct PlaylistDetailViewModelTests {
    var mockClient: MockYTMusicClient
    var likeStatusManager: SongLikeStatusManager
    var viewModel: PlaylistDetailViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.likeStatusManager = SongLikeStatusManager()
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        self.viewModel = PlaylistDetailViewModel(
            playlist: playlist,
            client: self.mockClient,
            likeStatusManager: self.likeStatusManager
        )
    }

    private func makeLikedMusicPlaylist(trackCount: Int? = nil) -> Playlist {
        Playlist(
            id: LikedMusicPlaylist.id,
            title: "Liked Music",
            description: nil,
            thumbnailURL: URL(string: "https://example.com/liked.jpg"),
            trackCount: trackCount,
            author: Artist.inline(name: "You", namespace: "playlist-author")
        )
    }

    private func makeLikedMusicViewModel(with tracks: [Song], trackCount: Int? = nil) -> PlaylistDetailViewModel {
        let playlist = self.makeLikedMusicPlaylist(trackCount: trackCount)
        let detail = PlaylistDetail(
            playlist: playlist,
            tracks: tracks,
            duration: nil
        )
        self.mockClient.playlistDetails[playlist.id] = detail
        return PlaylistDetailViewModel(
            playlist: playlist,
            client: self.mockClient,
            likeStatusManager: self.likeStatusManager
        )
    }

    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        description: String,
        timeout: Duration = .seconds(3)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("Timed out waiting for \(description)")
    }

    // MARK: - Initial State Tests

    @Test("Initial state is idle with no playlist detail")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.playlistDetail == nil)
        #expect(self.viewModel.hasMore == false)
    }

    // MARK: - Load Tests

    @Test("Load success sets playlist detail")
    func loadSuccess() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 10
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()

        #expect(self.mockClient.getPlaylistCalled == true)
        #expect(self.mockClient.getPlaylistIds.first == "VL-test-playlist")
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.playlistDetail != nil)
        #expect(self.viewModel.playlistDetail?.tracks.count == 10)
    }

    // MARK: - Track Removal Tests

    @Test("Optimistic track removal removes the matching track and confirms successfully")
    func optimisticTrackRemovalRemovesMatch() async throws {
        let songs = [
            Song(id: "a", title: "A", artists: [], videoId: "a", playlistSetVideoId: "set-a"),
            Song(id: "b", title: "B", artists: [], videoId: "b", playlistSetVideoId: "set-b"),
            Song(id: "c", title: "C", artists: [], videoId: "c", playlistSetVideoId: "set-c"),
        ]
        let playlist = Playlist(
            id: "VL-removal-test", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: 3, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(playlist: playlist, tracks: songs, duration: nil)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()

        let removal = try #require(viewModel.beginOptimisticTrackRemoval(setVideoId: "set-b"))

        #expect(viewModel.playlistDetail?.tracks.map(\.videoId) == ["a", "c"])
        #expect(viewModel.playlistDetail?.trackCount == 2)
        #expect(viewModel.isRemovingTrack)

        viewModel.confirmTrackRemoval(removal)

        #expect(!viewModel.isRemovingTrack)
    }

    @Test("Only one optimistic playlist removal can be active")
    func optimisticTrackRemovalIsSingleFlight() async throws {
        let songs = [
            Song(id: "a", title: "A", artists: [], videoId: "a", playlistSetVideoId: "set-a"),
            Song(id: "b", title: "B", artists: [], videoId: "b", playlistSetVideoId: "set-b"),
        ]
        let playlist = Playlist(
            id: "VL-single-flight-removal", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: songs.count, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(playlist: playlist, tracks: songs, duration: nil)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()

        let firstRemoval = try #require(viewModel.beginOptimisticTrackRemoval(setVideoId: "set-a"))
        #expect(viewModel.beginOptimisticTrackRemoval(setVideoId: "set-b") == nil)

        await viewModel.rollbackTrackRemoval(firstRemoval)

        let secondRemoval = try #require(viewModel.beginOptimisticTrackRemoval(setVideoId: "set-b"))
        await viewModel.rollbackTrackRemoval(secondRemoval)
    }

    @Test("Generation-mismatched rollback restores the full pre-removal snapshot")
    func generationMismatchRollbackRestoresSnapshot() async throws {
        let songs = [
            Song(id: "a", title: "A", artists: [], videoId: "a", playlistSetVideoId: "set-a"),
            Song(id: "b", title: "B", artists: [], videoId: "b", playlistSetVideoId: "set-b"),
            Song(id: "c", title: "C", artists: [], videoId: "c", playlistSetVideoId: "set-c"),
        ]
        let playlist = Playlist(
            id: "VL-async-rollback", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: songs.count, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: Array(songs.prefix(2)),
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlist.id] = [[songs[2]]]
        self.mockClient.playlistContinuationDelay = .milliseconds(150)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()
        let removal = try #require(viewModel.beginOptimisticTrackRemoval(setVideoId: "set-a"))

        let loadMoreTask = Task { await viewModel.loadMore() }
        await self.waitUntil(
            viewModel.loadingState == .loadingMore,
            description: "continuation load to start"
        )
        loadMoreTask.cancel()
        await loadMoreTask.value
        await self.waitUntil(
            viewModel.loadingState == .loaded,
            description: "cancelled continuation to settle"
        )

        await viewModel.rollbackTrackRemoval(removal)

        #expect(!viewModel.isRemovingTrack)
        #expect(viewModel.playlistDetail?.tracks.map(\.videoId) == ["a", "b"])
        let nextRemoval = try #require(viewModel.beginOptimisticTrackRemoval(setVideoId: "set-b"))
        await viewModel.rollbackTrackRemoval(nextRemoval)
    }

    @Test("Track removal waiters resume only after the optimistic mutation finishes")
    func trackRemovalWaitersResumeAfterCompletion() async throws {
        let song = Song(id: "a", title: "A", artists: [], videoId: "a", playlistSetVideoId: "set-a")
        let playlist = Playlist(
            id: "VL-removal-waiter", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: 1, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(playlist: playlist, tracks: [song], duration: nil)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()
        let removal = try #require(viewModel.beginOptimisticTrackRemoval(setVideoId: "set-a"))
        var waiterFinished = false
        let waiter = Task { @MainActor in
            await viewModel.waitForTrackRemovalToFinish()
            waiterFinished = true
        }
        await Task.yield()

        #expect(!waiterFinished)

        viewModel.confirmTrackRemoval(removal)
        await waiter.value

        #expect(waiterFinished)
    }

    @Test("Stale refresh counts an off-page tombstone when its continuation arrives")
    func staleRefreshCountsOffPageTombstoneOnContinuation() async throws {
        let songs = [
            Song(id: "a", title: "A", artists: [], videoId: "a", playlistSetVideoId: "set-a"),
            Song(id: "b", title: "B", artists: [], videoId: "b", playlistSetVideoId: "set-b"),
            Song(id: "c", title: "C", artists: [], videoId: "c", playlistSetVideoId: "set-c"),
            Song(id: "d", title: "D", artists: [], videoId: "d", playlistSetVideoId: "set-d"),
        ]
        let playlist = Playlist(
            id: "VL-stale-continuation-removal", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: songs.count, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: songs,
            duration: nil
        )
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()
        let removal = try #require(viewModel.beginOptimisticTrackRemoval(setVideoId: "set-d"))
        viewModel.confirmTrackRemoval(removal)

        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: Array(songs.prefix(2)),
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlist.id] = [Array(songs.suffix(2))]

        await viewModel.refresh()
        #expect(viewModel.playlistDetail?.trackCount == 4)

        await viewModel.loadMore()

        #expect(viewModel.playlistDetail?.tracks.map(\.videoId) == ["a", "b", "c"])
        #expect(viewModel.playlistDetail?.trackCount == 3)
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

        #expect(self.mockClient.getPlaylistCalled == true)
        if case let .error(error) = viewModel.loadingState {
            #expect(!error.message.isEmpty)
            #expect(error.isRetryable)
        } else {
            Issue.record("Expected error state")
        }
        #expect(self.viewModel.playlistDetail == nil)
    }

    @Test("Load does not duplicate when already loading")
    func loadDoesNotDuplicateWhenAlreadyLoading() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()
        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("Liked Music load marks tracks as liked and seeds like cache")
    func likedMusicLoadMarksTracksAsLikedAndSeedsCache() async {
        let tracks = [
            TestFixtures.makeSong(id: "liked-1", title: "Liked 1"),
            TestFixtures.makeSong(id: "liked-2", title: "Liked 2"),
        ]
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: tracks, trackCount: 2)

        await likedMusicViewModel.load()

        #expect(likedMusicViewModel.playlistDetail?.tracks.count == 2)
        #expect(likedMusicViewModel.playlistDetail?.tracks[0].likeStatus == .like)
        #expect(likedMusicViewModel.playlistDetail?.tracks[1].likeStatus == .like)
        #expect(self.likeStatusManager.status(for: "liked-1") == .like)
        #expect(self.likeStatusManager.status(for: "liked-2") == .like)
    }

    @Test("Liked Music loadAllRemaining fetches every continuation")
    func likedMusicLoadAllRemainingFetchesEveryContinuation() async {
        let initialTracks = [
            TestFixtures.makeSong(id: "liked-1", title: "Liked 1"),
            TestFixtures.makeSong(id: "liked-2", title: "Liked 2"),
        ]
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: initialTracks)
        self.mockClient.playlistContinuationTracks[LikedMusicPlaylist.id] = [
            [
                TestFixtures.makeSong(id: "liked-3", title: "Liked 3"),
                TestFixtures.makeSong(id: "liked-4", title: "Liked 4"),
            ],
            [
                TestFixtures.makeSong(id: "liked-5", title: "Liked 5"),
            ],
        ]

        await likedMusicViewModel.load()
        #expect(self.mockClient.getPlaylistContinuationCallCount == 0)
        #expect(likedMusicViewModel.playlistDetail?.tracks.count == 2)

        await likedMusicViewModel.loadAllRemaining()

        #expect(self.mockClient.getPlaylistContinuationCallCount == 2)
        #expect(likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) == [
            "liked-1",
            "liked-2",
            "liked-3",
            "liked-4",
            "liked-5",
        ])
        #expect(likedMusicViewModel.playlistDetail?.tracks.allSatisfy { $0.likeStatus == .like } == true)
        #expect(likedMusicViewModel.hasMore == false)
    }

    @Test("Liked Music load keeps delayed continuation lazy")
    func likedMusicLoadKeepsDelayedContinuationLazy() async {
        let initialTracks = [
            TestFixtures.makeSong(id: "liked-1", title: "Liked 1"),
            TestFixtures.makeSong(id: "liked-2", title: "Liked 2"),
        ]
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: initialTracks)
        self.mockClient.playlistContinuationTracks[LikedMusicPlaylist.id] = [
            [TestFixtures.makeSong(id: "liked-3", title: "Liked 3")],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await likedMusicViewModel.load()

        #expect(likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) == ["liked-1", "liked-2"])
        #expect(self.mockClient.getPlaylistContinuationReturnCount == 0)

        try? await Task.sleep(for: .milliseconds(250))
        #expect(likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) == ["liked-1", "liked-2"])
        #expect(self.mockClient.getPlaylistContinuationReturnCount == 0)
        #expect(likedMusicViewModel.hasMore == true)

        await likedMusicViewModel.loadAllRemaining()
        #expect(likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) == ["liked-1", "liked-2", "liked-3"])
        #expect(likedMusicViewModel.playlistDetail?.tracks.allSatisfy { $0.likeStatus == .like } == true)
        #expect(likedMusicViewModel.hasMore == false)
    }

    @Test("Large playlist loadAllRemaining fetches every continuation")
    func largePlaylistLoadAllRemainingFetchesEveryContinuation() async {
        let playlist = Playlist(
            id: "VL-test-playlist",
            title: "Large Playlist",
            description: nil,
            thumbnailURL: URL(string: "https://example.com/playlist.jpg"),
            trackCount: 125,
            author: Artist.inline(name: "Test User", namespace: "playlist-author")
        )
        let initialTracks = TestFixtures.makeSongs(count: 100)
        let detail = PlaylistDetail(playlist: playlist, tracks: initialTracks, duration: nil)
        self.mockClient.playlistDetails[playlist.id] = detail
        self.mockClient.playlistContinuationTracks[playlist.id] = [
            (100 ..< 115).map { index in
                TestFixtures.makeSong(id: "video-\(index)", title: "Song \(index)")
            },
            (115 ..< 125).map { index in
                TestFixtures.makeSong(id: "video-\(index)", title: "Song \(index)")
            },
        ]

        await self.viewModel.load()
        #expect(self.mockClient.getPlaylistContinuationCallCount == 0)
        #expect(self.viewModel.playlistDetail?.tracks.count == 100)

        await self.viewModel.loadAllRemaining()

        #expect(self.mockClient.getPlaylistContinuationCallCount == 2)
        #expect(self.viewModel.playlistDetail?.tracks.count == 125)
        #expect(self.viewModel.playlistDetail?.trackCount == 125)
        #expect(self.viewModel.hasMore == false)
    }

    @Test("Large playlist load keeps delayed continuation lazy")
    func largePlaylistLoadKeepsDelayedContinuationLazy() async {
        let playlist = Playlist(
            id: "VL-test-playlist",
            title: "Large Playlist",
            description: nil,
            thumbnailURL: URL(string: "https://example.com/playlist.jpg"),
            trackCount: 125,
            author: Artist.inline(name: "Test User", namespace: "playlist-author")
        )
        let initialTracks = TestFixtures.makeSongs(count: 100)
        let detail = PlaylistDetail(playlist: playlist, tracks: initialTracks, duration: nil)
        self.mockClient.playlistDetails[playlist.id] = detail
        self.mockClient.playlistContinuationTracks[playlist.id] = [
            (100 ..< 125).map { index in
                TestFixtures.makeSong(id: "video-\(index)", title: "Song \(index)")
            },
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await self.viewModel.load()

        #expect(self.viewModel.playlistDetail?.tracks.count == 100)
        #expect(self.mockClient.getPlaylistContinuationReturnCount == 0)

        try? await Task.sleep(for: .milliseconds(250))
        #expect(self.viewModel.playlistDetail?.tracks.count == 100)
        #expect(self.mockClient.getPlaylistContinuationReturnCount == 0)
        #expect(self.viewModel.hasMore == true)

        await self.viewModel.loadAllRemaining()
        #expect(self.viewModel.playlistDetail?.tracks.count == 125)
        #expect(self.viewModel.hasMore == false)
    }

    @Test("Load more during background full drain does not cancel drain")
    func loadMoreDuringBackgroundFullDrainDoesNotCancelDrain() async {
        let playlist = Playlist(
            id: "VL-test-playlist",
            title: "Large Playlist",
            description: nil,
            thumbnailURL: URL(string: "https://example.com/playlist.jpg"),
            trackCount: 125,
            author: Artist.inline(name: "Test User", namespace: "playlist-author")
        )
        let initialTracks = TestFixtures.makeSongs(count: 100)
        let detail = PlaylistDetail(playlist: playlist, tracks: initialTracks, duration: nil)
        self.mockClient.playlistDetails[playlist.id] = detail
        self.mockClient.playlistContinuationTracks[playlist.id] = [
            (100 ..< 125).map { index in
                TestFixtures.makeSong(id: "video-\(index)", title: "Song \(index)")
            },
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await self.viewModel.load()
        let drainTask = Task { await self.viewModel.loadAllRemaining() }
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationCallCount == 1,
            description: "large playlist explicit drain to start"
        )

        await self.viewModel.loadMore()
        await drainTask.value

        await self.waitUntil(
            self.viewModel.playlistDetail?.tracks.count == 125,
            description: "large playlist explicit drain after manual load more"
        )
        #expect(self.mockClient.getPlaylistContinuationCallCount == 1)
        #expect(self.viewModel.hasMore == false)
    }

    @Test("Repeated load during background continuation drain does not restart playlist")
    func repeatedLoadDuringBackgroundContinuationDrainDoesNotRestartPlaylist() async {
        let playlist = Playlist(
            id: "VL-test-playlist",
            title: "Large Playlist",
            description: nil,
            thumbnailURL: URL(string: "https://example.com/playlist.jpg"),
            trackCount: 125,
            author: Artist.inline(name: "Test User", namespace: "playlist-author")
        )
        let initialTracks = TestFixtures.makeSongs(count: 100)
        let detail = PlaylistDetail(playlist: playlist, tracks: initialTracks, duration: nil)
        self.mockClient.playlistDetails[playlist.id] = detail
        self.mockClient.playlistContinuationTracks[playlist.id] = [
            (100 ..< 125).map { index in
                TestFixtures.makeSong(id: "video-\(index)", title: "Song \(index)")
            },
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await self.viewModel.load()
        let drainTask = Task { await self.viewModel.loadAllRemaining() }
        await self.waitUntil(
            self.viewModel.loadingState == .loadingMore,
            description: "explicit continuation drain to enter loadingMore"
        )

        await self.viewModel.load()

        #expect(self.mockClient.getPlaylistIds == [playlist.id])
        await drainTask.value
        await self.waitUntil(
            self.viewModel.playlistDetail?.tracks.count == 125,
            description: "explicit drain after repeated load"
        )
    }

    @Test("Live-synced loaded removal is not double-counted by continuation overlap")
    func liveSyncedLoadedRemovalIsNotDoubleCountedByContinuationOverlap() async throws {
        let initialTracks = [TestFixtures.makeSong(id: "liked-1", title: "Liked 1")]
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: initialTracks, trackCount: 2)
        self.mockClient.playlistContinuationTracks[LikedMusicPlaylist.id] = [
            [
                TestFixtures.makeSong(id: "liked-1", title: "Liked 1"),
                TestFixtures.makeSong(id: "liked-2", title: "Liked 2"),
            ],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await likedMusicViewModel.load()
        let drainTask = Task { await likedMusicViewModel.loadAllRemaining() }
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationCallCount == 1,
            description: "overlapping delayed continuation to start"
        )

        let manager = self.likeStatusManager
        let rating = manager.enqueueRating(
            initialTracks[0],
            status: .indifferent,
            client: self.mockClient
        )
        try likedMusicViewModel.handleLikeStatusChange(#require(manager.lastLikeEvent))

        await drainTask.value
        _ = await rating.value
        await self.waitUntil(
            likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) == ["liked-2"],
            description: "continuation drain to skip loaded unlike overlap"
        )

        #expect(likedMusicViewModel.playlistDetail?.trackCount == 1)
        #expect(self.likeStatusManager.status(for: "liked-1") != .like)
    }

    @Test("Live-synced removal skips not-yet-loaded continuation track")
    func liveSyncedRemovalSkipsNotYetLoadedContinuationTrack() async throws {
        let initialTracks = [TestFixtures.makeSong(id: "liked-1", title: "Liked 1")]
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: initialTracks, trackCount: 3)
        let futureSong = TestFixtures.makeSong(id: "future-unliked", title: "Future Unliked")
        self.mockClient.playlistContinuationTracks[LikedMusicPlaylist.id] = [
            [futureSong],
            [TestFixtures.makeSong(id: "liked-3", title: "Liked 3")],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await likedMusicViewModel.load()
        let drainTask = Task { await likedMusicViewModel.loadAllRemaining() }
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationCallCount == 1,
            description: "first delayed continuation to start"
        )

        let manager = self.likeStatusManager
        let rating = manager.enqueueRating(
            futureSong,
            status: .indifferent,
            client: self.mockClient
        )
        try likedMusicViewModel.handleLikeStatusChange(#require(manager.lastLikeEvent))

        await drainTask.value
        _ = await rating.value
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationCallCount == 2 && likedMusicViewModel.playlistDetail?.tracks.map(\.videoId).contains("liked-3") == true,
            description: "continuation drain to skip not-yet-loaded unlike"
        )

        let videoIds = likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) ?? []
        #expect(videoIds == ["liked-1", "liked-3"])
        #expect(videoIds.contains("future-unliked") == false)
        #expect(likedMusicViewModel.playlistDetail?.trackCount == 2)
        #expect(self.likeStatusManager.status(for: "future-unliked") != .like)
    }

    @Test("Manual load more preserves live removal after background drain failure")
    func manualLoadMorePreservesLiveRemovalAfterBackgroundDrainFailure() async throws {
        let initialTracks = [TestFixtures.makeSong(id: "liked-1", title: "Liked 1")]
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: initialTracks, trackCount: 3)
        let futureSong = TestFixtures.makeSong(id: "future-unliked", title: "Future Unliked")
        self.mockClient.playlistContinuationTracks[LikedMusicPlaylist.id] = [
            [futureSong],
            [TestFixtures.makeSong(id: "liked-3", title: "Liked 3")],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await likedMusicViewModel.load()
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.timedOut))
        let failingDrainTask = Task { await likedMusicViewModel.loadAllRemaining() }
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationCallCount == 1,
            description: "failed explicit continuation to start"
        )
        await failingDrainTask.value
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationReturnCount >= 1 && likedMusicViewModel.loadingState == .loaded,
            description: "failed explicit continuation to return"
        )
        self.mockClient.shouldThrowError = nil
        self.mockClient.playlistContinuationDelay = nil

        #expect(likedMusicViewModel.hasMore == true)
        let manager = self.likeStatusManager
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeRateSongReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        let rating = manager.enqueueRating(
            futureSong,
            status: .indifferent,
            client: self.mockClient
        )
        try likedMusicViewModel.handleLikeStatusChange(#require(manager.lastLikeEvent))

        await likedMusicViewModel.loadMore()
        await likedMusicViewModel.loadMore()
        await releaseRequest.open()
        _ = await rating.value

        let videoIds = likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) ?? []
        #expect(videoIds == ["liked-1", "liked-3"])
        #expect(videoIds.contains("future-unliked") == false)
        #expect(likedMusicViewModel.playlistDetail?.trackCount == 2)
        #expect(self.likeStatusManager.status(for: "future-unliked") != .like)
        #expect(likedMusicViewModel.hasMore == false)
    }

    @Test("Live-synced duplicate page advances continuation drain")
    func liveSyncedDuplicatePageAdvancesContinuationDrain() async {
        let initialTracks = [TestFixtures.makeSong(id: "liked-1", title: "Liked 1")]
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: initialTracks)
        self.mockClient.playlistContinuationTracks[LikedMusicPlaylist.id] = [
            [TestFixtures.makeSong(id: "live-inserted", title: "Live Inserted")],
            [TestFixtures.makeSong(id: "liked-3", title: "Liked 3")],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await likedMusicViewModel.load()
        let drainTask = Task { await likedMusicViewModel.loadAllRemaining() }
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationCallCount == 1,
            description: "first delayed continuation to start"
        )

        likedMusicViewModel.handleLikeStatusChange(
            LikeStatusEvent(
                videoId: "live-inserted",
                status: .like,
                song: TestFixtures.makeSong(id: "live-inserted", title: "Live Inserted")
            )
        )

        await drainTask.value
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationCallCount == 2 && likedMusicViewModel.playlistDetail?.tracks.map(\.videoId).contains("liked-3") == true,
            description: "continuation drain to advance past live-synced duplicate"
        )

        #expect(likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) == ["live-inserted", "liked-1", "liked-3"])
        #expect(likedMusicViewModel.hasMore == false)
    }

    @Test("Stale background continuation drain cannot mutate after refresh")
    func staleBackgroundContinuationDrainCannotMutateAfterRefresh() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Refresh Playlist")
        let initialTracks = TestFixtures.makeSongs(count: 100)
        let initialDetail = PlaylistDetail(playlist: playlist, tracks: initialTracks, duration: nil)
        self.mockClient.playlistDetails[playlist.id] = initialDetail
        self.mockClient.playlistContinuationTracks[playlist.id] = [
            [TestFixtures.makeSong(id: "stale-continuation", title: "Stale")],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await self.viewModel.load()
        let drainTask = Task { await self.viewModel.loadAllRemaining() }
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationCallCount == 1,
            description: "stale explicit drain to start"
        )

        let refreshedPlaylist = Playlist(
            id: playlist.id,
            title: playlist.title,
            description: playlist.description,
            thumbnailURL: playlist.thumbnailURL,
            trackCount: 3,
            author: playlist.author
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: refreshedPlaylist,
            tracks: TestFixtures.makeSongs(count: 3),
            duration: nil
        )

        await self.viewModel.refresh()
        await drainTask.value
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationReturnCount == 1,
            description: "stale explicit drain to return"
        )

        let videoIds = self.viewModel.playlistDetail?.tracks.map(\.videoId) ?? []
        #expect(videoIds == ["video-0", "video-1", "video-2"])
        #expect(videoIds.contains("stale-continuation") == false)
    }

    @Test("Explicit full drain can run again after refresh cancels stale drain")
    func explicitFullDrainRunsAfterRefreshCancelsStaleDrain() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Refresh Playlist")
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: TestFixtures.makeSongs(count: 100),
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlist.id] = [
            [TestFixtures.makeSong(id: "stale-continuation", title: "Stale")],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await self.viewModel.load()
        let staleDrain = Task { await self.viewModel.loadAllRemaining() }
        await self.waitUntil(
            self.mockClient.getPlaylistContinuationCallCount == 1,
            description: "stale explicit drain to start before refresh"
        )

        let refreshedPlaylist = Playlist(
            id: playlist.id,
            title: playlist.title,
            description: playlist.description,
            thumbnailURL: playlist.thumbnailURL,
            trackCount: 4,
            author: playlist.author
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: refreshedPlaylist,
            tracks: TestFixtures.makeSongs(count: 3),
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlist.id] = [
            [TestFixtures.makeSong(id: "fresh-continuation", title: "Fresh")],
        ]
        self.mockClient.playlistContinuationDelay = nil

        await self.viewModel.refresh()
        await staleDrain.value
        await self.viewModel.loadAllRemaining()

        let videoIds = self.viewModel.playlistDetail?.tracks.map(\.videoId) ?? []
        #expect(videoIds == ["video-0", "video-1", "video-2", "fresh-continuation"])
        #expect(videoIds.contains("stale-continuation") == false)
        #expect(self.viewModel.hasMore == false)
    }

    @Test("Concurrent paging callers coalesce: full load, no stall, no duplicate fetch")
    func concurrentPagingCoalesces() async {
        // Small playlist (10 < threshold) so load() does NOT auto-page; we drive paging explicitly
        // to exercise the single-flight wrapper with overlapping callers.
        let initialTracks = TestFixtures.makeSongs(count: 10) // video-0...video-9
        let detail = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            tracks: initialTracks,
            duration: nil
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = detail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            (10 ..< 20).map { TestFixtures.makeSong(id: "video-\($0)") },
            (20 ..< 30).map { TestFixtures.makeSong(id: "video-\($0)") },
            (30 ..< 35).map { TestFixtures.makeSong(id: "video-\($0)") },
        ]
        // Widen the overlap window so the concurrent callers genuinely race.
        self.mockClient.playlistContinuationDelay = .milliseconds(40)

        await self.viewModel.load()
        #expect(self.viewModel.hasMore)
        #expect(self.viewModel.playlistDetail?.tracks.count == 10)

        // The completion loader plus two scroll-style loadMore() calls run concurrently. With the
        // single-flight wrapper they coalesce onto the in-flight batch instead of colliding on
        // `loadingState` (where the loser would return a spurious false that the resilient loop
        // mis-reads as a stall and gives up on, leaving the queue stuck at a partial count).
        async let all: Void = self.viewModel.loadAllRemaining()
        async let more1: Void = self.viewModel.loadMore()
        async let more2: Void = self.viewModel.loadMore()
        _ = await (all, more1, more2)

        #expect(self.viewModel.playlistDetail?.tracks.count == 35)
        #expect(self.viewModel.hasMore == false)
        // Each of the 3 continuation batches is fetched exactly once — no batch skipped, and no
        // duplicate fetch from a coalesced caller advancing the token twice.
        #expect(self.mockClient.getPlaylistContinuationCallCount == 3)
    }

    @Test("Large playlist load keeps continuation lazy until explicitly requested")
    func largePlaylistLoadKeepsContinuationLazy() async {
        let playlist = Playlist(
            id: "VL-test-playlist",
            title: "Large Test Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: 150,
            author: Artist.inline(name: "Test User", namespace: "playlist-author")
        )
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        let playlistDetail = PlaylistDetail(
            playlist: playlist,
            tracks: TestFixtures.makeSongs(count: 100),
            duration: nil
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            (100 ..< 150).map { TestFixtures.makeSong(id: "cont-\($0)") },
        ]

        await viewModel.load()

        #expect(self.mockClient.getPlaylistContinuationCalled == false)
        #expect(self.mockClient.getPlaylistContinuationCallCount == 0)
        #expect(viewModel.playlistDetail?.tracks.count == 100)
        #expect(viewModel.hasMore == true)

        await viewModel.loadAllRemaining()

        #expect(self.mockClient.getPlaylistContinuationCallCount == 1)
        #expect(viewModel.playlistDetail?.tracks.count == 150)
        #expect(viewModel.hasMore == false)
    }

    @Test("Small playlist load keeps continuation lazy")
    func smallPlaylistLoadKeepsContinuationLazy() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 10
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [TestFixtures.makeSong(id: "cont-1")],
        ]

        await self.viewModel.load()

        #expect(self.mockClient.getPlaylistContinuationCalled == false)
        #expect(self.viewModel.playlistDetail?.tracks.count == 10)
        #expect(self.viewModel.hasMore == true)
    }

    @Test("Album load keeps continuation lazy")
    func albumLoadKeepsContinuationLazy() async {
        let album = Playlist(
            id: "MPRE-test-album",
            title: "Test Album",
            description: nil,
            thumbnailURL: URL(string: "https://example.com/album.jpg"),
            trackCount: 125,
            author: Artist.inline(name: "Test Artist", namespace: "playlist-author")
        )
        let albumViewModel = PlaylistDetailViewModel(playlist: album, client: self.mockClient)
        let detail = PlaylistDetail(
            playlist: album,
            tracks: TestFixtures.makeSongs(count: 100),
            duration: nil
        )
        self.mockClient.playlistDetails[album.id] = detail
        self.mockClient.playlistContinuationTracks[album.id] = [
            (100 ..< 125).map { index in
                TestFixtures.makeSong(id: "video-\(index)", title: "Song \(index)")
            },
        ]

        await albumViewModel.load()

        #expect(self.mockClient.getPlaylistContinuationCalled == false)
        #expect(albumViewModel.playlistDetail?.tracks.count == 100)
        #expect(albumViewModel.hasMore == true)
    }

    // MARK: - Load More Tests

    @Test("Load more appends tracks")
    func loadMoreAppendsTracks() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [
                TestFixtures.makeSong(id: "cont-1"),
                TestFixtures.makeSong(id: "cont-2"),
            ],
        ]

        await self.viewModel.load()
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)
        #expect(self.viewModel.hasMore == true)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationCalled == true)
        #expect(self.viewModel.playlistDetail?.tracks.count == 7)
    }

    @Test("Load more continuation auth uses loaded ownership")
    func loadMoreContinuationAuthUsesLoadedOwnership() async {
        let routePlaylist = TestFixtures.makePlaylist(
            id: "VL-owned-load-more",
            title: "Owned Load More",
            canDelete: false
        )
        let loadedPlaylist = TestFixtures.makePlaylist(
            id: routePlaylist.id,
            title: routePlaylist.title,
            canDelete: true
        )
        let viewModel = PlaylistDetailViewModel(playlist: routePlaylist, client: self.mockClient)
        self.mockClient.playlistDetails[routePlaylist.id] = PlaylistDetail(
            playlist: loadedPlaylist,
            tracks: [TestFixtures.makeSong(id: "owned-initial")],
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[routePlaylist.id] = [
            [TestFixtures.makeSong(id: "owned-continuation")],
        ]

        await viewModel.load()
        await viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationRequiresAuthFlags == [true])
    }

    @Test("Load more uses the view model's own continuation token after another playlist loads")
    func loadMoreUsesOwnContinuationTokenAfterAnotherPlaylistLoads() async {
        let firstPlaylist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "First Playlist")
        let secondPlaylist = TestFixtures.makePlaylist(id: "VL-other-playlist", title: "Other Playlist")
        let firstDetail = TestFixtures.makePlaylistDetail(playlist: firstPlaylist, trackCount: 2)
        let secondDetail = TestFixtures.makePlaylistDetail(playlist: secondPlaylist, trackCount: 2)
        let secondViewModel = PlaylistDetailViewModel(playlist: secondPlaylist, client: self.mockClient)

        self.mockClient.playlistDetails[firstPlaylist.id] = firstDetail
        self.mockClient.playlistDetails[secondPlaylist.id] = secondDetail
        self.mockClient.playlistContinuationTracks[firstPlaylist.id] = [
            [TestFixtures.makeSong(id: "first-continuation")],
        ]
        self.mockClient.playlistContinuationTracks[secondPlaylist.id] = [
            [TestFixtures.makeSong(id: "other-continuation")],
        ]

        await self.viewModel.load()
        await secondViewModel.load()
        await self.viewModel.loadMore()

        let videoIDs = self.viewModel.playlistDetail?.tracks.map(\.videoId) ?? []
        #expect(videoIDs.contains("first-continuation"))
        #expect(!videoIDs.contains("other-continuation"))
    }

    @Test("Cancelled load more restores loaded state")
    func cancelledLoadMoreRestoresLoadedState() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [TestFixtures.makeSong(id: "cont-1")],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await self.viewModel.load()
        let loadMoreTask = Task { await self.viewModel.loadMore() }
        await self.waitUntil(
            self.viewModel.loadingState == .loadingMore,
            description: "load more to enter loadingMore"
        )

        loadMoreTask.cancel()
        await loadMoreTask.value

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)
    }

    @Test("Stale manual load more cannot mutate after refresh")
    func staleManualLoadMoreCannotMutateAfterRefresh() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [TestFixtures.makeSong(id: "stale-manual")],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(200)

        await self.viewModel.load()
        let loadMoreTask = Task { await self.viewModel.loadMore() }
        await self.waitUntil(
            self.viewModel.loadingState == .loadingMore,
            description: "manual loadMore to enter loadingMore"
        )

        let refreshedDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = refreshedDetail
        await self.viewModel.refresh()
        await loadMoreTask.value
        try? await Task.sleep(for: .milliseconds(220))

        let videoIds = self.viewModel.playlistDetail?.tracks.map(\.videoId) ?? []
        #expect(videoIds == ["video-0", "video-1", "video-2"])
        #expect(videoIds.contains("stale-manual") == false)
    }

    @Test("Continuation drain preserves reported total track count")
    func continuationDrainPreservesReportedTotalTrackCount() async {
        let playlist = Playlist(
            id: "VL-test-playlist",
            title: "Large Playlist",
            description: "A test playlist",
            thumbnailURL: URL(string: "https://example.com/playlist.jpg"),
            trackCount: 2429,
            author: Artist(id: "UC123456", name: "Test User")
        )
        let playlistDetail = PlaylistDetail(
            playlist: playlist,
            tracks: TestFixtures.makeSongs(count: 100),
            duration: "135+ hours"
        )
        let continuationTracks = (100 ..< 150).map { index in
            TestFixtures.makeSong(id: "video-\(index)", title: "Song \(index)")
        }

        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [continuationTracks]

        await self.viewModel.load()
        await self.viewModel.loadAllRemaining()
        await self.waitUntil(
            self.viewModel.playlistDetail?.tracks.count == 150,
            description: "reported total count continuation drain"
        )

        #expect(self.viewModel.playlistDetail?.tracks.count == 150)
        #expect(self.viewModel.playlistDetail?.trackCount == 2429)
        #expect(self.viewModel.playlistDetail?.author?.id == "UC123456")
    }

    @Test("Load more deduplicates tracks")
    func loadMoreDeduplicatesTracks() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [
                TestFixtures.makeSong(id: "video-0"), // Duplicate
                TestFixtures.makeSong(id: "new-track"),
            ],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.playlistDetail?.tracks.count == 4) // 3 original + 1 new
    }

    @Test("Load more stops on all duplicates")
    func loadMoreStopsOnAllDuplicates() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 2
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [
                TestFixtures.makeSong(id: "video-0"),
                TestFixtures.makeSong(id: "video-1"),
            ],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.playlistDetail?.tracks.count == 2)
        #expect(self.viewModel.hasMore == false)
    }

    @Test("Load more does nothing when not loaded")
    func loadMoreDoesNothingWhenNotLoaded() async {
        #expect(self.viewModel.loadingState == .idle)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationCalled == false)
    }

    @Test("Load more does nothing when no more tracks")
    func loadMoreDoesNothingWhenNoMore() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        // No continuation tracks set

        await self.viewModel.load()
        #expect(self.viewModel.hasMore == false)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationCalled == false)
    }

    // MARK: - Liked Music Live Sync Tests

    @Test("Liked Music live sync removes song after unlike")
    func likedMusicLiveSyncRemovesSongAfterUnlike() async {
        let tracks = [
            TestFixtures.makeSong(id: "liked-1", title: "Liked 1"),
            TestFixtures.makeSong(id: "liked-2", title: "Liked 2"),
        ]
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: tracks, trackCount: 2)

        await likedMusicViewModel.load()
        likedMusicViewModel.handleLikeStatusChange(
            LikeStatusEvent(videoId: "liked-1", status: .indifferent, song: nil)
        )

        #expect(likedMusicViewModel.playlistDetail?.tracks.count == 1)
        #expect(likedMusicViewModel.playlistDetail?.tracks.first?.videoId == "liked-2")
    }

    @Test("Failed unlike rollback restores the loaded track total")
    func failedUnlikeRollbackRestoresLoadedTrackTotal() async throws {
        let manager = self.likeStatusManager
        let song = TestFixtures.makeSong(id: "rollback-loaded-total", title: "Rollback Loaded")
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: [song], trackCount: 1)
        await likedMusicViewModel.load()
        manager.setStatus(.like, for: song.videoId)
        self.mockClient.rateSongErrors = [
            YTMusicError.networkError(underlying: URLError(.notConnectedToInternet)),
        ]

        let rating = manager.enqueueRating(
            song,
            status: .indifferent,
            client: self.mockClient
        )
        try likedMusicViewModel.handleLikeStatusChange(#require(manager.lastLikeEvent))
        #expect(likedMusicViewModel.playlistDetail?.trackCount == 0)

        #expect(await rating.value == .like)
        try likedMusicViewModel.handleLikeStatusChange(#require(manager.lastLikeEvent))

        #expect(likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) == [song.videoId])
        #expect(likedMusicViewModel.playlistDetail?.trackCount == 1)
    }

    @Test("Liked Music live sync inserts liked song with complete metadata")
    func likedMusicLiveSyncInsertsLikedSongWithCompleteMetadata() async {
        let tracks = [TestFixtures.makeSong(id: "liked-1", title: "Liked 1")]
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: tracks, trackCount: 1)

        await likedMusicViewModel.load()

        let liveSong = Song(
            id: "new-liked-song",
            title: "Live Synced Song",
            artists: [Artist(id: "UC-live", name: "Live Artist")],
            thumbnailURL: URL(string: "https://example.com/live.jpg"),
            videoId: "new-liked-song"
        )
        likedMusicViewModel.handleLikeStatusChange(
            LikeStatusEvent(videoId: "new-liked-song", status: .like, song: liveSong)
        )

        #expect(likedMusicViewModel.playlistDetail?.tracks.count == 2)
        #expect(likedMusicViewModel.playlistDetail?.tracks.first?.videoId == "new-liked-song")
        #expect(likedMusicViewModel.playlistDetail?.tracks.first?.likeStatus == .like)
    }

    @Test("Liked Music optimistic insertion preserves the confirmed rollback baseline")
    func likedMusicOptimisticInsertionPreservesRollbackBaseline() async throws {
        let manager = self.likeStatusManager
        let accountID = "liked-music-rollback-\(UUID().uuidString)"
        manager.setActiveAccountID(accountID)
        defer { manager.setActiveAccountID(nil) }
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: [], trackCount: 0)
        await likedMusicViewModel.load()
        let song = Song(
            id: "optimistic-liked-song",
            title: "Optimistic Liked Song",
            artists: [Artist(id: "artist", name: "Artist")],
            videoId: "optimistic-liked-song"
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        manager.setStatus(.indifferent, for: song.videoId)
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        self.mockClient.beforeRateSongReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let likeTask = Task { @MainActor in
            await manager.like(song, client: self.mockClient)
        }
        await requestStarted.wait()
        try likedMusicViewModel.handleLikeStatusChange(#require(manager.lastLikeEvent))
        #expect(manager.status(for: song.videoId) == .like)
        #expect(likedMusicViewModel.playlistDetail?.tracks.first?.videoId == song.videoId)

        await releaseRequest.open()

        #expect(await likeTask.value == .indifferent)
        #expect(manager.status(for: song.videoId) == .indifferent)
    }

    @Test("Liked Music live sync fetches metadata for placeholder song")
    func likedMusicLiveSyncFetchesMetadataForPlaceholderSong() async {
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: [], trackCount: 0)
        await likedMusicViewModel.load()

        let videoId = "placeholder-song"
        self.mockClient.songResponses[videoId] = Song(
            id: videoId,
            title: "Resolved Song",
            artists: [Artist(id: "artist-1", name: "Resolved Artist")],
            thumbnailURL: URL(string: "https://example.com/thumb.jpg"),
            videoId: videoId
        )

        let placeholderSong = Song(
            id: videoId,
            title: "Loading...",
            artists: [],
            videoId: videoId
        )
        self.likeStatusManager.setCachedStatus(.like, for: videoId)
        likedMusicViewModel.handleLikeStatusChange(
            LikeStatusEvent(videoId: videoId, status: .like, song: placeholderSong)
        )

        try? await Task.sleep(for: .milliseconds(100))

        #expect(self.mockClient.getSongCalled == true)
        #expect(self.mockClient.getSongVideoIds.contains(videoId))
        #expect(likedMusicViewModel.playlistDetail?.tracks.count == 1)
        #expect(likedMusicViewModel.playlistDetail?.tracks.first?.title == "Resolved Song")
        #expect(likedMusicViewModel.playlistDetail?.tracks.first?.artistsDisplay == "Resolved Artist")
        #expect(likedMusicViewModel.playlistDetail?.tracks.first?.likeStatus == .like)
    }

    @Test("Liked Music live sync cancels pending metadata insert after unlike")
    func likedMusicLiveSyncCancelsPendingMetadataInsertAfterUnlike() async {
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: [], trackCount: 0)
        await likedMusicViewModel.load()

        let videoId = "cancelled-song"
        self.mockClient.getSongDelay = .milliseconds(150)
        self.mockClient.songResponses[videoId] = Song(
            id: videoId,
            title: "Should Not Insert",
            artists: [Artist(id: "artist-3", name: "Cancelled Artist")],
            thumbnailURL: URL(string: "https://example.com/cancelled.jpg"),
            videoId: videoId
        )

        self.likeStatusManager.setCachedStatus(.like, for: videoId)
        likedMusicViewModel.handleLikeStatusChange(
            LikeStatusEvent(
                videoId: videoId,
                status: .like,
                song: Song(id: videoId, title: "Loading...", artists: [], videoId: videoId)
            )
        )

        try? await Task.sleep(for: .milliseconds(50))

        self.likeStatusManager.setCachedStatus(.indifferent, for: videoId)
        likedMusicViewModel.handleLikeStatusChange(
            LikeStatusEvent(videoId: videoId, status: .indifferent, song: nil)
        )

        try? await Task.sleep(for: .milliseconds(150))

        #expect(self.mockClient.getSongVideoIds.contains(videoId))
        #expect(likedMusicViewModel.playlistDetail?.tracks.isEmpty == true)
    }

    // MARK: - Liked Music Reconciliation Regression Tests

    @Test("Loaded unlike is counted once when an in-flight continuation returns the removed track")
    func loadedUnlikeIsCountedOnceAcrossContinuationOverlap() async {
        let manager = self.likeStatusManager
        let removedSong = TestFixtures.makeSong(id: "loaded-unlike", title: "Loaded Unlike")
        let continuationSong = TestFixtures.makeSong(id: "continuation-liked", title: "Continuation Liked")
        let reportedTotal = 2429
        let likedMusicViewModel = self.makeLikedMusicViewModel(
            with: [removedSong],
            trackCount: reportedTotal
        )
        self.mockClient.playlistContinuationTracks[LikedMusicPlaylist.id] = [
            [removedSong, continuationSong],
        ]

        let continuationStarted = AsyncGate()
        let releaseContinuation = AsyncGate()
        let releaseRating = AsyncGate()
        self.mockClient.beforePlaylistContinuationReturn = { _ in
            await continuationStarted.open()
            await releaseContinuation.wait()
        }
        self.mockClient.beforeRateSongReturn = { _, _ in
            await releaseRating.wait()
        }

        await likedMusicViewModel.load()
        let drainTask = Task { await likedMusicViewModel.loadAllRemaining() }
        await continuationStarted.wait()

        let rating = manager.enqueueRating(
            removedSong,
            status: .indifferent,
            client: self.mockClient
        )
        if let event = manager.lastLikeEvent {
            likedMusicViewModel.handleLikeStatusChange(event)
        } else {
            Issue.record("Expected an optimistic unlike event")
        }

        #expect(likedMusicViewModel.playlistDetail?.trackCount == reportedTotal - 1)

        await releaseContinuation.open()
        await drainTask.value

        #expect(likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) == [continuationSong.videoId])
        #expect(likedMusicViewModel.playlistDetail?.trackCount == reportedTotal - 1)

        await releaseRating.open()
        #expect(await rating.value == .indifferent)
    }

    @Test("Completed unlike survives a later stale continuation from the initial Liked Music load")
    func completedUnlikeSurvivesLaterInitialContinuation() async throws {
        let manager = self.likeStatusManager
        let removedSong = TestFixtures.makeSong(id: "completed-unlike", title: "Completed Unlike")
        let continuationSong = TestFixtures.makeSong(id: "later-liked", title: "Later Liked")
        let reportedTotal = 2
        let likedMusicViewModel = self.makeLikedMusicViewModel(
            with: [removedSong],
            trackCount: reportedTotal
        )
        self.mockClient.playlistContinuationTracks[LikedMusicPlaylist.id] = [
            [removedSong, continuationSong],
        ]

        let ratingStarted = AsyncGate()
        let releaseRating = AsyncGate()
        let continuationStarted = AsyncGate()
        let releaseContinuation = AsyncGate()
        self.mockClient.beforeRateSongReturn = { _, _ in
            await ratingStarted.open()
            await releaseRating.wait()
        }
        self.mockClient.beforePlaylistContinuationReturn = { _ in
            await continuationStarted.open()
            await releaseContinuation.wait()
        }

        await likedMusicViewModel.load()
        #expect(likedMusicViewModel.hasMore == true)
        #expect(self.mockClient.getPlaylistContinuationCallCount == 0)

        let rating = manager.enqueueRating(
            removedSong,
            status: .indifferent,
            client: self.mockClient
        )
        try likedMusicViewModel.handleLikeStatusChange(#require(manager.lastLikeEvent))
        await ratingStarted.wait()

        #expect(self.mockClient.getPlaylistContinuationCallCount == 0)
        #expect(likedMusicViewModel.playlistDetail?.tracks.isEmpty == true)
        #expect(likedMusicViewModel.playlistDetail?.trackCount == reportedTotal - 1)

        await releaseRating.open()
        #expect(await rating.value == .indifferent)
        #expect(self.mockClient.getPlaylistContinuationCallCount == 0)

        let continuationTask = Task { await likedMusicViewModel.loadMore() }
        await continuationStarted.wait()
        await releaseContinuation.open()
        await continuationTask.value

        let videoIDs = likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) ?? []
        #expect(self.mockClient.getPlaylistContinuationCallCount == 1)
        #expect(videoIDs == [continuationSong.videoId])
        #expect(videoIDs.contains(removedSong.videoId) == false)
        #expect(likedMusicViewModel.playlistDetail?.trackCount == reportedTotal - 1)
        #expect(likedMusicViewModel.hasMore == false)
    }

    @Test("Same-account invalidation keeps loaded Liked Music live sync active")
    func sameAccountInvalidationKeepsLoadedLikedMusicLiveSyncActive() async {
        let manager = self.likeStatusManager
        let accountID = "same-account-live-sync"
        manager.setActiveAccountID(accountID)
        defer { manager.setActiveAccountID(nil) }

        let song = TestFixtures.makeSong(id: "same-account-unlike", title: "Same Account Unlike")
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: [song], trackCount: 1)
        let releaseRating = AsyncGate()
        self.mockClient.beforeRateSongReturn = { _, _ in
            await releaseRating.wait()
        }

        await likedMusicViewModel.load()
        manager.invalidateSession(clearsActiveCache: false)

        let rating = manager.enqueueRating(
            song,
            status: .indifferent,
            client: self.mockClient
        )
        if let batch = manager.lastLikeEventBatch {
            #expect(batch.accountID == accountID)
            for event in batch.events {
                likedMusicViewModel.handleLikeStatusChange(event)
            }
        } else {
            Issue.record("Expected a current-account unlike event batch")
        }

        #expect(likedMusicViewModel.playlistDetail?.tracks.isEmpty == true)
        #expect(likedMusicViewModel.playlistDetail?.trackCount == 0)

        await releaseRating.open()
        #expect(await rating.value == .indifferent)
    }

    @Test("Initial reconciliation increments the reported total once for an omitted pending complete like")
    func initialReconciliationCountsOmittedPendingCompleteLikeOnce() async {
        let manager = self.likeStatusManager
        let existingSong = TestFixtures.makeSong(id: "existing-liked", title: "Existing Liked")
        let pendingSong = Song(
            id: "pending-complete-like",
            title: "Pending Complete Like",
            artists: [Artist(id: "pending-artist", name: "Pending Artist")],
            videoId: "pending-complete-like"
        )
        let reportedTotal = 2429
        let likedMusicViewModel = self.makeLikedMusicViewModel(
            with: [existingSong],
            trackCount: reportedTotal
        )

        let initialRequestStarted = AsyncGate()
        let releaseInitialResponse = AsyncGate()
        let releaseRating = AsyncGate()
        self.mockClient.beforeGetPlaylistReturn = { _ in
            await initialRequestStarted.open()
            await releaseInitialResponse.wait()
        }
        self.mockClient.beforeRateSongReturn = { _, _ in
            await releaseRating.wait()
        }

        let loadTask = Task { await likedMusicViewModel.load() }
        await initialRequestStarted.wait()

        let rating = manager.enqueueRating(
            pendingSong,
            status: .like,
            client: self.mockClient
        )
        await releaseInitialResponse.open()
        await loadTask.value

        let reconciledVideoIDs = likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) ?? []
        #expect(reconciledVideoIDs.filter { $0 == pendingSong.videoId }.count == 1)
        #expect(likedMusicViewModel.playlistDetail?.trackCount == reportedTotal + 1)

        if let event = manager.lastLikeEvent {
            likedMusicViewModel.handleLikeStatusChange(event)
        } else {
            Issue.record("Expected an optimistic like event")
        }

        #expect(likedMusicViewModel.playlistDetail?.tracks.filter { $0.videoId == pendingSong.videoId }.count == 1)
        #expect(likedMusicViewModel.playlistDetail?.trackCount == reportedTotal + 1)

        await releaseRating.open()
        #expect(await rating.value == .like)
    }

    @Test("Initial reconciliation does not increment totals for a failed unlike rollback")
    func initialReconciliationDoesNotCountFailedUnlikeRollbackAsInsertion() async {
        let manager = self.likeStatusManager
        let existingSong = TestFixtures.makeSong(id: "rollback-existing", title: "Existing Song")
        let rollbackSong = TestFixtures.makeSong(id: "rollback-liked", title: "Rollback Liked")
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: [existingSong], trackCount: 2)
        manager.setStatus(.like, for: rollbackSong.videoId)
        let initialRequestStarted = AsyncGate()
        let releaseInitialResponse = AsyncGate()
        self.mockClient.beforeGetPlaylistReturn = { _ in
            await initialRequestStarted.open()
            await releaseInitialResponse.wait()
        }

        let loadTask = Task { await likedMusicViewModel.load() }
        await initialRequestStarted.wait()
        self.mockClient.rateSongErrors = [
            YTMusicError.networkError(underlying: URLError(.notConnectedToInternet)),
        ]

        #expect(await manager.unlike(rollbackSong, client: self.mockClient) == .like)

        await releaseInitialResponse.open()
        await loadTask.value

        #expect(likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) == [rollbackSong.videoId, existingSong.videoId])
        #expect(likedMusicViewModel.playlistDetail?.trackCount == 2)
    }

    @Test("Deferred failed-unlike rollback metadata preserves the reported total")
    func deferredFailedUnlikeRollbackMetadataPreservesReportedTotal() async {
        let manager = self.likeStatusManager
        let existingSong = TestFixtures.makeSong(id: "deferred-rollback-existing", title: "Existing Song")
        let videoID = "deferred-rollback-liked"
        let placeholderSong = Song(
            id: videoID,
            title: "Loading...",
            artists: [],
            videoId: videoID
        )
        let resolvedSong = Song(
            id: videoID,
            title: "Resolved Rollback Like",
            artists: [Artist(id: "rollback-artist", name: "Rollback Artist")],
            videoId: videoID
        )
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: [existingSong], trackCount: 2)
        manager.setStatus(.like, for: videoID)
        self.mockClient.songResponses[videoID] = resolvedSong
        let initialRequestStarted = AsyncGate()
        let releaseInitialResponse = AsyncGate()
        self.mockClient.beforeGetPlaylistReturn = { _ in
            await initialRequestStarted.open()
            await releaseInitialResponse.wait()
        }

        let loadTask = Task { await likedMusicViewModel.load() }
        await initialRequestStarted.wait()
        self.mockClient.rateSongErrors = [
            YTMusicError.networkError(underlying: URLError(.notConnectedToInternet)),
        ]

        #expect(await manager.unlike(placeholderSong, client: self.mockClient) == .like)

        await releaseInitialResponse.open()
        await loadTask.value
        await self.waitUntil(
            likedMusicViewModel.playlistDetail?.tracks.contains { $0.videoId == videoID } == true,
            description: "deferred rollback metadata insertion"
        )

        #expect(likedMusicViewModel.playlistDetail?.tracks.first?.title == resolvedSong.title)
        #expect(likedMusicViewModel.playlistDetail?.trackCount == 2)
    }

    @Test("Initial reconciliation resolves an omitted pending placeholder like before insertion")
    func initialReconciliationResolvesOmittedPendingPlaceholderLike() async {
        let manager = self.likeStatusManager
        let existingSong = TestFixtures.makeSong(id: "existing-placeholder-base", title: "Existing Song")
        let videoID = "pending-placeholder-like"
        let placeholderSong = Song(
            id: videoID,
            title: "Loading...",
            artists: [],
            videoId: videoID
        )
        let resolvedSong = Song(
            id: videoID,
            title: "Resolved Pending Like",
            artists: [Artist(id: "resolved-artist", name: "Resolved Artist")],
            thumbnailURL: URL(string: "https://example.com/resolved-pending.jpg"),
            videoId: videoID
        )
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: [existingSong], trackCount: 1)
        self.mockClient.songResponses[videoID] = resolvedSong

        let initialRequestStarted = AsyncGate()
        let releaseInitialResponse = AsyncGate()
        let releaseMetadata = AsyncGate()
        let releaseRating = AsyncGate()
        self.mockClient.beforeGetPlaylistReturn = { _ in
            await initialRequestStarted.open()
            await releaseInitialResponse.wait()
        }
        self.mockClient.beforeGetSongReturn = { requestedVideoID in
            guard requestedVideoID == videoID else { return }
            await releaseMetadata.wait()
        }
        self.mockClient.beforeRateSongReturn = { _, _ in
            await releaseRating.wait()
        }

        let loadTask = Task { await likedMusicViewModel.load() }
        await initialRequestStarted.wait()

        let rating = manager.enqueueRating(
            placeholderSong,
            status: .like,
            client: self.mockClient
        )
        await releaseInitialResponse.open()
        await self.waitUntil(
            self.mockClient.getSongVideoIds.contains(videoID),
            description: "pending placeholder metadata request"
        )

        #expect(likedMusicViewModel.playlistDetail?.tracks.contains { $0.videoId == videoID } == false)
        #expect(likedMusicViewModel.playlistDetail?.tracks.contains { $0.title == "Loading..." } == false)

        await releaseMetadata.open()
        await loadTask.value
        await self.waitUntil(
            likedMusicViewModel.playlistDetail?.tracks.contains {
                $0.videoId == videoID && $0.title == resolvedSong.title
            } == true,
            description: "resolved pending placeholder insertion"
        )

        let resolvedTracks = likedMusicViewModel.playlistDetail?.tracks.filter { $0.videoId == videoID } ?? []
        #expect(self.mockClient.getSongVideoIds.filter { $0 == videoID }.count == 1)
        #expect(resolvedTracks.count == 1)
        #expect(resolvedTracks.first?.title == resolvedSong.title)
        #expect(resolvedTracks.first?.artistsDisplay == resolvedSong.artistsDisplay)
        #expect(resolvedTracks.first?.likeStatus == .like)
        #expect(likedMusicViewModel.playlistDetail?.trackCount == 2)

        await releaseRating.open()
        #expect(await rating.value == .like)
    }

    @Test("Continuation reconciliation reuses an in-flight placeholder metadata request")
    func continuationReconciliationReusesInFlightPlaceholderMetadataRequest() async {
        let manager = self.likeStatusManager
        let videoID = "reused-placeholder-metadata"
        let placeholderSong = Song(
            id: videoID,
            title: "Loading...",
            artists: [],
            videoId: videoID
        )
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: [], trackCount: 0)
        self.mockClient.playlistContinuationTracks[LikedMusicPlaylist.id] = [[], []]
        let ratingStarted = AsyncGate()
        let releaseRating = AsyncGate()
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        self.mockClient.beforeRateSongReturn = { _, _ in
            await ratingStarted.open()
            await releaseRating.wait()
        }
        self.mockClient.beforeGetSongReturn = { requestedVideoID in
            guard requestedVideoID == videoID else { return }
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        let rating = manager.enqueueRating(
            placeholderSong,
            status: .like,
            client: self.mockClient
        )
        await ratingStarted.wait()
        await likedMusicViewModel.load()
        await metadataStarted.wait()

        await likedMusicViewModel.loadAllRemaining()

        #expect(self.mockClient.getPlaylistContinuationCallCount == 2)
        #expect(self.mockClient.getSongVideoIds.filter { $0 == videoID }.count == 1)

        await releaseMetadata.open()
        await releaseRating.open()
        _ = await rating.value
    }

    @Test("Continuation response metadata for an optimistic like increments the reported total")
    func continuationResponseMetadataForOptimisticLikeIncrementsReportedTotal() async throws {
        let manager = self.likeStatusManager
        let existingSong = TestFixtures.makeSong(id: "existing-liked", title: "Existing Liked")
        let resolvedSong = Song(
            id: "response-backed-like",
            title: "Response Backed Like",
            artists: [Artist(id: "response-artist", name: "Response Artist")],
            videoId: "response-backed-like"
        )
        let placeholderSong = Song(
            id: resolvedSong.id,
            title: "Loading...",
            artists: [],
            videoId: resolvedSong.videoId
        )
        let likedMusicViewModel = self.makeLikedMusicViewModel(with: [existingSong], trackCount: 1)
        self.mockClient.playlistContinuationTracks[LikedMusicPlaylist.id] = [[resolvedSong]]
        let continuationStarted = AsyncGate()
        let releaseContinuation = AsyncGate()
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        self.mockClient.beforePlaylistContinuationReturn = { _ in
            await continuationStarted.open()
            await releaseContinuation.wait()
        }
        self.mockClient.beforeGetSongReturn = { _ in
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        await likedMusicViewModel.load()
        let continuationTask = Task { await likedMusicViewModel.loadMore() }
        await continuationStarted.wait()

        let rating = manager.enqueueRating(
            placeholderSong,
            status: .like,
            client: self.mockClient
        )
        try likedMusicViewModel.handleLikeStatusChange(#require(manager.lastLikeEvent))
        await metadataStarted.wait()

        await releaseContinuation.open()
        await continuationTask.value
        _ = await rating.value

        #expect(likedMusicViewModel.playlistDetail?.tracks.map(\.videoId) == [existingSong.videoId, resolvedSong.videoId])
        #expect(likedMusicViewModel.playlistDetail?.trackCount == 2)

        await releaseMetadata.open()
    }

    @Test("Continuation drain reaches a later unique page through advancing duplicate-only cursors")
    func continuationDrainReachesUniquePageAfterAdvancingDuplicates() async {
        let playlist = Playlist(
            id: "VL-advancing-duplicate-pages",
            title: "Advancing Duplicate Pages",
            description: nil,
            thumbnailURL: nil,
            trackCount: 2
        )
        let initialSong = TestFixtures.makeSong(id: "duplicate-page-song", title: "Initial Song")
        let uniqueSong = TestFixtures.makeSong(id: "later-unique-song", title: "Later Unique Song")
        let detail = PlaylistDetail(playlist: playlist, tracks: [initialSong], duration: nil)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        self.mockClient.playlistDetails[playlist.id] = detail
        self.mockClient.playlistContinuationTracks[playlist.id] = [
            [initialSong],
            [uniqueSong],
        ]

        await viewModel.loadAllRemaining()

        #expect(self.mockClient.getPlaylistContinuationCallCount == 2)
        #expect(viewModel.playlistDetail?.tracks.map(\.videoId) == [initialSong.videoId, uniqueSong.videoId])
        #expect(viewModel.hasMore == false)
    }

    @Test("Continuation drain stops before refetching a cyclic cursor")
    func continuationDrainStopsBeforeRefetchingCyclicCursor() async {
        let playlistID = "VL-cyclic-continuation"
        let song = TestFixtures.makeSong(id: "cyclic-song", title: "Cyclic Song")
        let playlist = TestFixtures.makePlaylist(id: playlistID, title: "Cyclic Playlist")
        self.mockClient.playlistDetails[playlistID] = PlaylistDetail(
            playlist: playlist,
            tracks: [song],
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlistID] = [[song]]
        let initialToken = "mock-playlist-continuation|\(playlistID)|0"
        self.mockClient.forcedPlaylistContinuationResponses = [
            PlaylistContinuationResponse(tracks: [song], continuationToken: "cycle-b"),
            PlaylistContinuationResponse(tracks: [song], continuationToken: initialToken),
        ]
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)

        await viewModel.load()
        await viewModel.loadAllRemaining()

        #expect(self.mockClient.getPlaylistContinuationCallCount == 2)
        #expect(self.mockClient.getPlaylistContinuationTokens == [initialToken, "cycle-b"])
        #expect(viewModel.hasMore == false)
    }

    // MARK: - Refresh Tests

    @Test("Refresh clears detail and reloads")
    func refreshClearsDetailAndReloads() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)

        // Update mock to return different track count
        let newPlaylistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 8
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = newPlaylistDetail

        await self.viewModel.refresh()

        #expect(self.viewModel.playlistDetail?.tracks.count == 8)
    }

    // MARK: - Fallback Tests

    @Test("Load uses original playlist info for unknown title")
    func loadUsesOriginalPlaylistInfoForUnknownTitle() async {
        // Create a playlist detail with "Unknown Playlist" title
        let unknownPlaylist = Playlist(
            id: "test-playlist",
            title: "Unknown Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: 3,
            author: nil
        )
        let playlistDetail = PlaylistDetail(
            playlist: unknownPlaylist,
            tracks: TestFixtures.makeSongs(count: 3),
            duration: "10 min"
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()

        // Should use original playlist title "Test Playlist" instead of "Unknown Playlist"
        #expect(self.viewModel.playlistDetail?.id == "VL-test-playlist")
        #expect(self.viewModel.playlistDetail?.title == "Test Playlist")
    }

    @Test("Load preserves fallback author metadata when cleaning song count suffix")
    func loadPreservesFallbackAuthorMetadataWhenCleaningSongCountSuffix() async {
        let mockClient = MockYTMusicClient()
        let originalPlaylist = Playlist(
            id: "VL-test-playlist",
            title: "Test Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: 145,
            author: Artist(
                id: "UC123456",
                name: "Test User • 145 songs",
                thumbnailURL: URL(string: "https://example.com/author.jpg"),
                subtitle: "123 subscribers",
                profileKind: .profile
            )
        )
        let viewModel = PlaylistDetailViewModel(playlist: originalPlaylist, client: mockClient)
        let unknownPlaylist = Playlist(
            id: "VL-test-playlist",
            title: "Unknown Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: 3,
            author: nil
        )
        let playlistDetail = PlaylistDetail(
            playlist: unknownPlaylist,
            tracks: TestFixtures.makeSongs(count: 3),
            duration: "10 min"
        )
        mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await viewModel.load()

        #expect(viewModel.playlistDetail?.author?.name == "Test User")
        #expect(viewModel.playlistDetail?.author?.id == "UC123456")
        #expect(viewModel.playlistDetail?.author?.subtitle == "123 subscribers")
        #expect(viewModel.playlistDetail?.author?.profileKind == .profile)
    }
}
