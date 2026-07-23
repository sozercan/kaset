import Foundation
import Testing
@testable import Kaset

// MARK: - PlayerServicePlaylistCreationBoundaryTests

extension LibraryMutationSerialTests {
    @Suite(.tags(.service), .timeLimit(.minutes(1)))
    @MainActor
    struct PlayerServicePlaylistCreationBoundaryTests {
        var playerService: PlayerService
        var mockClient: MockYTMusicClient

        init() {
            self.mockClient = MockYTMusicClient()
            self.playerService = PlayerService()
            let likeStatusManager = SongLikeStatusManager()
            likeStatusManager.setActiveAccountID(nil)
            self.playerService.setSongLikeStatusManager(likeStatusManager)
            self.playerService.setYTMusicClient(self.mockClient)
        }

        @Test("A stale account owner cannot create a captured queue playlist")
        func staleAccountOwnerCannotCreateCapturedQueuePlaylist() async {
            let songs = [TestFixtures.makeSong(id: "stale-playlist-owner")]
            let owner = self.playerService.currentAccountMutationOwner
            self.playerService.songLikeStatusManager.setActiveAccountID("brand-account")

            await #expect(throws: CancellationError.self) {
                _ = try await self.playerService.saveQueueAsPlaylist(
                    title: "Stale Snapshot",
                    songs: songs,
                    owner: owner
                )
            }

            #expect(self.mockClient.createPlaylistCalls.isEmpty)
        }

        @Test("An account switch during playlist reconciliation removes the stale optimistic playlist")
        func accountSwitchDuringPlaylistReconciliationRemovesOptimisticPlaylist() async {
            let libraryViewModel = LibraryViewModel(client: self.mockClient)
            let songs = [TestFixtures.makeSong(id: "reconcile-account-switch")]
            let owner = self.playerService.currentAccountMutationOwner
            self.mockClient.shouldWaitForLibraryContentResponse = true

            var saveTask: Task<Playlist, any Error>!
            await withCheckedContinuation { continuation in
                self.mockClient.onGetLibraryContent = {
                    self.mockClient.onGetLibraryContent = nil
                    continuation.resume()
                }
                saveTask = Task { @MainActor in
                    try await self.playerService.saveQueueAsPlaylist(
                        title: "Old Account Playlist",
                        songs: songs,
                        owner: owner
                    )
                }
            }

            #expect(libraryViewModel.isInLibrary(playlistId: "PLCREATED"))
            self.playerService.songLikeStatusManager.setActiveAccountID("brand-account")
            self.mockClient.shouldWaitForLibraryContentResponse = false
            self.mockClient.resumeNextLibraryContentResponse()

            await #expect(throws: CancellationError.self) {
                _ = try await saveTask.value
            }
            #expect(!libraryViewModel.isInLibrary(playlistId: "PLCREATED"))
            #expect(!libraryViewModel.playlists.contains { $0.id == "PLCREATED" })
        }

        @Test("Account boundary drains queue-playlist reconciliation before reopening")
        func accountBoundaryDrainsQueuePlaylistReconciliation() async {
            let libraryViewModel = LibraryViewModel(client: self.mockClient)
            let songs = [TestFixtures.makeSong(id: "boundary-reconciliation")]
            self.mockClient.shouldWaitForLibraryContentResponse = true

            var saveTask: Task<Playlist, any Error>!
            await withCheckedContinuation { continuation in
                self.mockClient.onGetLibraryContent = {
                    self.mockClient.onGetLibraryContent = nil
                    continuation.resume()
                }
                saveTask = Task { @MainActor in
                    try await self.playerService.saveQueueAsPlaylist(
                        title: "Boundary Playlist",
                        songs: songs,
                        owner: self.playerService.currentAccountMutationOwner
                    )
                }
            }
            #expect(libraryViewModel.isInLibrary(playlistId: "PLCREATED"))

            LibraryMutationActions.beginAccountBoundary()
            let drainTask = Task { await LibraryMutationActions.awaitAccountBoundaryDrain() }
            for _ in 0 ..< 10 {
                await Task.yield()
            }
            #expect(libraryViewModel.isInLibrary(playlistId: "PLCREATED"))
            self.mockClient.shouldWaitForLibraryContentResponse = false
            self.mockClient.resumeNextLibraryContentResponse()
            await drainTask.value
            LibraryMutationActions.endAccountBoundary()

            await #expect(throws: CancellationError.self) {
                _ = try await saveTask.value
            }
            #expect(!libraryViewModel.isInLibrary(playlistId: "PLCREATED"))
        }
    }
}
