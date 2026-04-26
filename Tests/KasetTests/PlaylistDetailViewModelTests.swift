import Foundation
import Testing
@testable import Kaset

/// Tests for PlaylistDetailViewModel using mock client.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct PlaylistDetailViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: PlaylistDetailViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        self.viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
    }

    private func makeLikedMusicPlaylist(trackCount: Int? = nil) -> Playlist {
        Playlist(
            id: "LM",
            title: "Liked Music",
            description: nil,
            thumbnailURL: URL(string: "https://example.com/liked.jpg"),
            trackCount: trackCount,
            author: "You"
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
        return PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
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
        #expect(SongLikeStatusManager.shared.status(for: "liked-1") == .like)
        #expect(SongLikeStatusManager.shared.status(for: "liked-2") == .like)
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

    @Test("Load more preserves reported total track count")
    func loadMorePreservesReportedTotalTrackCount() async {
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
        await self.viewModel.loadMore()

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

        likedMusicViewModel.handleLikeStatusChange(
            LikeStatusEvent(
                videoId: videoId,
                status: .like,
                song: Song(id: videoId, title: "Loading...", artists: [], videoId: videoId)
            )
        )

        try? await Task.sleep(for: .milliseconds(50))

        likedMusicViewModel.handleLikeStatusChange(
            LikeStatusEvent(videoId: videoId, status: .indifferent, song: nil)
        )

        try? await Task.sleep(for: .milliseconds(150))

        #expect(self.mockClient.getSongVideoIds.contains(videoId))
        #expect(likedMusicViewModel.playlistDetail?.tracks.isEmpty == true)
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
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()

        // Should use original playlist title "Test Playlist" instead of "Unknown Playlist"
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
