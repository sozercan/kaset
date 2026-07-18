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

    @Test("Remove song from playlist rolls back the optimistic change when the API call fails")
    func removeSongFromPlaylistRollsBackOnFailure() async {
        let song = Song(id: "song-1", title: "Song 1", artists: [], videoId: "song-1", playlistSetVideoId: "set-1")
        let playlist = Playlist(
            id: "VL-test-playlist", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: 1, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(playlist: playlist, tracks: [song], duration: nil)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()
        self.mockClient.shouldWaitForRemoveSongFromPlaylistResponse = true
        self.mockClient.removeSongFromPlaylistError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        let removalTask = Task {
            await LibraryMutationActions.removeSongFromPlaylist(song, from: viewModel, client: self.mockClient)
        }
        let requestStarted = await self.waitUntil(self.mockClient.removeSongFromPlaylistCalls.count == 1)
        #expect(requestStarted)
        guard requestStarted else {
            self.mockClient.shouldWaitForRemoveSongFromPlaylistResponse = false
            removalTask.cancel()
            return
        }

        #expect(viewModel.playlistDetail?.tracks.isEmpty == true)
        #expect(viewModel.playlistDetail?.trackCount == 0)

        self.mockClient.resumeNextRemoveSongFromPlaylistResponse()
        await removalTask.value

        #expect(viewModel.playlistDetail?.tracks.map(\.videoId) == ["song-1"])
        #expect(viewModel.playlistDetail?.trackCount == 1)
    }

    @Test("Optimistic removal stays applied while refresh is requested")
    func optimisticRemovalBlocksRefreshUntilCompletion() async {
        let songs = [
            Song(id: "song-a", title: "A", artists: [], videoId: "song-a", playlistSetVideoId: "set-a"),
            Song(id: "song-b", title: "B", artists: [], videoId: "song-b", playlistSetVideoId: "set-b"),
        ]
        let playlist = Playlist(
            id: "VL-test-playlist", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: songs.count, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(playlist: playlist, tracks: songs, duration: nil)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()
        self.mockClient.shouldWaitForRemoveSongFromPlaylistResponse = true

        let removalTask = Task {
            await LibraryMutationActions.removeSongFromPlaylist(songs[0], from: viewModel, client: self.mockClient)
        }
        let requestStarted = await self.waitUntil(self.mockClient.removeSongFromPlaylistCalls.count == 1)
        #expect(requestStarted)
        guard requestStarted else {
            self.mockClient.shouldWaitForRemoveSongFromPlaylistResponse = false
            removalTask.cancel()
            return
        }

        #expect(viewModel.playlistDetail?.tracks.map(\.videoId) == ["song-b"])
        #expect(viewModel.playlistDetail?.trackCount == 1)
        #expect(viewModel.isRemovingTrack)

        let refreshed = await viewModel.refresh()
        #expect(!refreshed)
        #expect(viewModel.playlistDetail?.tracks.map(\.videoId) == ["song-b"])

        self.mockClient.resumeNextRemoveSongFromPlaylistResponse()
        await removalTask.value

        #expect(viewModel.playlistDetail?.tracks.map(\.videoId) == ["song-b"])
        #expect(viewModel.playlistDetail?.trackCount == 1)
        #expect(!viewModel.isRemovingTrack)
    }

    @Test("Duplicate removal requests for one occurrence call the API once")
    func duplicateRemovalRequestsAreDeduplicated() async {
        let song = Song(id: "song-a", title: "A", artists: [], videoId: "song-a", playlistSetVideoId: "set-a")
        let playlist = Playlist(
            id: "VL-test-playlist", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: 1, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(playlist: playlist, tracks: [song], duration: nil)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()
        self.mockClient.shouldWaitForRemoveSongFromPlaylistResponse = true

        let firstRemoval = Task {
            await LibraryMutationActions.removeSongFromPlaylist(song, from: viewModel, client: self.mockClient)
        }
        let requestStarted = await self.waitUntil(self.mockClient.removeSongFromPlaylistCalls.count == 1)
        #expect(requestStarted)
        guard requestStarted else {
            self.mockClient.shouldWaitForRemoveSongFromPlaylistResponse = false
            firstRemoval.cancel()
            return
        }

        let duplicateRemoval = Task {
            await LibraryMutationActions.removeSongFromPlaylist(song, from: viewModel, client: self.mockClient)
        }
        await Task.yield()

        self.mockClient.resumeNextRemoveSongFromPlaylistResponse()
        await firstRemoval.value
        await duplicateRemoval.value

        #expect(self.mockClient.removeSongFromPlaylistCalls.count == 1)
        #expect(viewModel.playlistDetail?.tracks.isEmpty == true)
    }

    @Test("A stale action cannot remove an occurrence already confirmed deleted")
    func confirmedRemovalRejectsStaleRetry() async {
        let song = Song(id: "song-a", title: "A", artists: [], videoId: "song-a", playlistSetVideoId: "set-a")
        let playlist = Playlist(
            id: "VL-test-playlist", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: 1, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(playlist: playlist, tracks: [song], duration: nil)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()

        await LibraryMutationActions.removeSongFromPlaylist(song, from: viewModel, client: self.mockClient)
        await LibraryMutationActions.removeSongFromPlaylist(song, from: viewModel, client: self.mockClient)

        #expect(self.mockClient.removeSongFromPlaylistCalls.count == 1)
        #expect(viewModel.playlistDetail?.tracks.isEmpty == true)
    }

    @Test("Track removal does not interrupt an awaited full-playlist drain")
    func removalDoesNotInterruptFullPlaylistDrain() async {
        let songs = [
            Song(id: "song-a", title: "A", artists: [], videoId: "song-a", playlistSetVideoId: "set-a"),
            Song(id: "song-b", title: "B", artists: [], videoId: "song-b", playlistSetVideoId: "set-b"),
            Song(id: "song-c", title: "C", artists: [], videoId: "song-c", playlistSetVideoId: "set-c"),
            Song(id: "song-d", title: "D", artists: [], videoId: "song-d", playlistSetVideoId: "set-d"),
        ]
        let playlist = Playlist(
            id: "VL-test-playlist", title: "Test Playlist", description: nil,
            thumbnailURL: nil, trackCount: songs.count, canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: Array(songs.prefix(2)),
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlist.id] = [Array(songs.suffix(2))]
        self.mockClient.playlistContinuationDelay = .milliseconds(250)
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()

        let drainTask = Task { await viewModel.loadAllRemaining() }
        let continuationStarted = await self.waitUntil(self.mockClient.getPlaylistContinuationCallCount == 1)
        #expect(continuationStarted)
        guard continuationStarted else {
            drainTask.cancel()
            return
        }

        await LibraryMutationActions.removeSongFromPlaylist(songs[0], from: viewModel, client: self.mockClient)
        await drainTask.value

        #expect(viewModel.playlistDetail?.tracks.map(\.videoId) == ["song-b", "song-c", "song-d"])
        #expect(viewModel.playlistDetail?.trackCount == 3)
        #expect(!viewModel.hasMore)
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

    @Test("Delete playlist unpins it from the sidebar")
    func deletePlaylistUnpinsFromSidebar() async throws {
        let pinnedPlaylist = TestFixtures.makePlaylist(id: "PL-pinned-delete", title: "Pinned Playlist")
        let playlist = TestFixtures.makePlaylist(id: "VLPL-pinned-delete", title: "Pinned Playlist")
        SidebarPinnedItemsManager.shared.add(.from(pinnedPlaylist))

        try await LibraryMutationActions.deletePlaylist(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(!SidebarPinnedItemsManager.shared.isPinned(contentId: "PL-pinned-delete"))
    }

    @Test("Failed playlist deletion restores the sidebar pin and library entry")
    func deletePlaylistRestoresStateOnFailure() async throws {
        let pinnedPlaylist = TestFixtures.makePlaylist(id: "PL-delete-fails", title: "Sticky Playlist")
        let playlist = TestFixtures.makePlaylist(id: "VLPL-delete-fails", title: "Sticky Playlist")
        self.libraryViewModel.addToLibrary(playlist: playlist)
        SidebarPinnedItemsManager.shared.add(.from(pinnedPlaylist))
        self.mockClient.shouldThrowError = URLError(.notConnectedToInternet)

        await #expect(throws: (any Error).self) {
            try await LibraryMutationActions.deletePlaylist(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel
            )
        }

        #expect(SidebarPinnedItemsManager.shared.isPinned(contentId: "PL-delete-fails"))
        #expect(self.libraryViewModel.isInLibrary(playlistId: "VLPL-delete-fails"))
        SidebarPinnedItemsManager.shared.remove(contentId: "PL-delete-fails")
    }

    @Test("Failed playlist deletion restores every library model that observed the optimistic removal")
    func deletePlaylistRestoresAllAffectedLibraryModels() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-delete-multi-window", title: "Shared Playlist")
        let otherLibraryViewModel = LibraryViewModel(client: self.mockClient)
        self.libraryViewModel.addToLibrary(playlist: playlist)
        otherLibraryViewModel.addToLibrary(playlist: playlist)
        self.mockClient.shouldThrowError = URLError(.notConnectedToInternet)

        await #expect(throws: (any Error).self) {
            try await LibraryMutationActions.deletePlaylist(
                playlist,
                client: self.mockClient,
                libraryViewModel: nil
            )
        }

        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id))
        #expect(otherLibraryViewModel.isInLibrary(playlistId: playlist.id))
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !condition() {
            guard clock.now < deadline else { return condition() }
            try? await Task.sleep(for: .milliseconds(10))
        }

        return true
    }
}
