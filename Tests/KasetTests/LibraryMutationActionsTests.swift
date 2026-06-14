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
