import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct LibraryMutationActionsTests {
    var mockClient: MockYTMusicClient
    var libraryViewModel: LibraryViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.libraryViewModel = LibraryViewModel(client: self.mockClient)
        APICache.shared.invalidateAll()
        URLCache.shared.removeAllCachedResponses()
        LibraryMutationActions.artistReconciliationRetryDelays = [.milliseconds(1), .milliseconds(1)]
    }

    @Test("Add song to playlist delegates to client")
    func addSongToPlaylistDelegatesToClient() async {
        let song = TestFixtures.makeSong(id: "song-1", title: "Song 1")
        let playlist = AddToPlaylistOption(
            playlistId: "VL-target",
            title: "Target Playlist",
            subtitle: nil,
            thumbnailURL: nil,
            isSelected: false,
            privacyStatus: nil
        )

        await LibraryMutationActions.addSongToPlaylist(song, playlist: playlist, client: self.mockClient)

        #expect(self.mockClient.addSongToPlaylistCalls == [
            MockYTMusicClient.AddSongToPlaylistCall(
                videoId: "song-1",
                playlistId: "VL-target",
                allowDuplicate: false
            ),
        ])
    }

    @Test("Remove song from playlist delegates to client and removes it from the loaded list")
    func removeSongFromPlaylistDelegatesToClient() async {
        let song = Song(id: "song-1", title: "Song 1", artists: [], videoId: "song-1", playlistSetVideoId: "set-1")
        let playlist = Playlist(
            id: "VL-test-playlist", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: 1, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(playlist: playlist, tracks: [song], duration: nil)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()

        await LibraryMutationActions.removeSongFromPlaylist(song, from: viewModel, client: self.mockClient)

        #expect(self.mockClient.removeSongFromPlaylistCalls == [
            MockYTMusicClient.RemoveSongFromPlaylistCall(videoId: "song-1", setVideoId: "set-1", playlistId: "VL-test-playlist"),
        ])
        #expect(viewModel.playlistDetail?.tracks.isEmpty == true)
    }

    @Test("Remove song from playlist rolls back the optimistic removal when the API call fails")
    func removeSongFromPlaylistRollsBackOnFailure() async {
        let song = Song(id: "song-1", title: "Song 1", artists: [], videoId: "song-1", playlistSetVideoId: "set-1")
        let playlist = Playlist(
            id: "VL-test-playlist", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: 1, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(playlist: playlist, tracks: [song], duration: nil)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await LibraryMutationActions.removeSongFromPlaylist(song, from: viewModel, client: self.mockClient)

        #expect(viewModel.playlistDetail?.tracks.map(\.videoId) == ["song-1"])
        #expect(viewModel.playlistDetail?.trackCount == 1)
    }

    @Test("Subscribe to artist applies optimistic library state while request is in flight")
    func subscribeToArtistAppliesOptimisticState() async throws {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-123", name: "Test Artist")
        self.mockClient.subscribeToArtistDelay = .milliseconds(700)

        let subscribeTask = Task {
            try await LibraryMutationActions.subscribeToArtist(
                artist,
                channelId: "UC-channel-123",
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel
            )
        }

        try await Task.sleep(for: .milliseconds(100))

        #expect(self.libraryViewModel.isInLibrary(artistId: "UC-channel-123"))
        #expect(self.libraryViewModel.artists.first?.id == "UC-channel-123")

        try await subscribeTask.value
    }

    @Test("Delete playlist removes it optimistically and calls client")
    func deletePlaylistRemovesOptimisticallyAndCallsClient() async throws {
        let playlist = TestFixtures.makePlaylist(id: "VL-owned", title: "Owned Playlist")
        self.libraryViewModel.addToLibrary(playlist: playlist)
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        try await LibraryMutationActions.deletePlaylist(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.mockClient.deletePlaylistCalled)
        #expect(self.mockClient.deletePlaylistIds == ["VL-owned"])
        #expect(!self.libraryViewModel.isInLibrary(playlistId: "VL-owned"))
    }
}
