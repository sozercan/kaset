import Foundation
import Testing
@testable import Kaset

// MARK: - Playlist mutation boundary tests

extension LibraryMutationSerialTests.LibraryMutationActionsTests {
    @Test("Library mutations resume immediately after an empty account boundary")
    func mutationsResumeImmediatelyAfterEmptyAccountBoundary() async throws {
        let playlist = TestFixtures.makePlaylist(id: "VL-boundary-reopened", title: "Boundary Reopened")

        LibraryMutationActions.beginAccountBoundary()
        LibraryMutationActions.endAccountBoundary()

        try await LibraryMutationActions.addPlaylistToLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel,
            reconciliationDelay: .zero
        )

        #expect(self.mockClient.subscribeToPlaylistIds == [playlist.id])
        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id))
    }

    @Test("Library mutations cannot start while an account boundary is active")
    func libraryMutationCannotStartDuringAccountBoundary() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-boundary-closed", title: "Boundary Closed")
        let podcast = TestFixtures.makePodcastShow(id: "MPSPPLboundary-closed")
        let artist = TestFixtures.makeArtist(id: "UC-boundary-closed", name: "Boundary Closed")
        let song = TestFixtures.makeSong(id: "boundary-song", title: "Boundary Song")
        let addToPlaylistOption = AddToPlaylistOption(
            playlistId: "VL-boundary-target",
            title: "Boundary Target",
            subtitle: nil,
            thumbnailURL: nil,
            isSelected: false,
            privacyStatus: nil
        )
        LibraryMutationActions.beginAccountBoundary()
        defer { LibraryMutationActions.endAccountBoundary() }

        await #expect(throws: CancellationError.self) {
            try await LibraryMutationActions.addPlaylistToLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero
            )
        }
        await #expect(throws: CancellationError.self) {
            try await LibraryMutationActions.subscribeToPodcast(
                podcast,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel
            )
        }
        await #expect(throws: CancellationError.self) {
            try await LibraryMutationActions.subscribeToArtist(
                artist,
                channelId: artist.id,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel
            )
        }
        await LibraryMutationActions.addSongToPlaylist(
            song,
            playlist: addToPlaylistOption,
            client: self.mockClient
        )
        #expect(self.mockClient.subscribeToPlaylistIds.isEmpty)
        #expect(self.mockClient.addSongToPlaylistCalls.isEmpty)
        #expect(!self.mockClient.subscribeToArtistCalled)
        #expect(!self.libraryViewModel.isInLibrary(podcastId: podcast.id))
        #expect(!self.libraryViewModel.isInLibrary(artistId: artist.id))
    }

    @Test("Account boundary drain waits for cancelled mutations to finish")
    func accountBoundaryDrainWaitsForCancelledMutation() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-boundary-drain", title: "Boundary Drain")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        let drainCompleted = LockedCounter()
        self.mockClient.beforeSubscribeToPlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let mutationTask = Task {
            try await LibraryMutationActions.addPlaylistToLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero
            )
        }
        await requestStarted.wait()

        LibraryMutationActions.beginAccountBoundary()
        let drainTask = Task {
            await LibraryMutationActions.awaitAccountBoundaryDrain()
            drainCompleted.increment()
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(drainCompleted.isEmpty)

        await releaseRequest.open()
        await drainTask.value
        LibraryMutationActions.endAccountBoundary()

        await #expect(throws: CancellationError.self) { try await mutationTask.value }
        #expect(drainCompleted.count == 1)
    }

    @Test("Account boundary drains in-flight playlist creation")
    func accountBoundaryDrainsInFlightPlaylistCreation() async {
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        let drainCompleted = LockedCounter()
        self.mockClient.beforeCreatePlaylistReturn = {
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let creationTask = Task {
            try await LibraryMutationActions.withAccountBoundaryTracking {
                try await self.mockClient.createPlaylist(
                    title: "Boundary Playlist",
                    description: nil,
                    privacyStatus: .private,
                    videoIds: ["boundary-video"]
                )
            }
        }
        await requestStarted.wait()

        LibraryMutationActions.beginAccountBoundary()
        let drainTask = Task {
            await LibraryMutationActions.awaitAccountBoundaryDrain()
            drainCompleted.increment()
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(drainCompleted.isEmpty)

        await releaseRequest.open()
        await drainTask.value
        LibraryMutationActions.endAccountBoundary()

        await #expect(throws: CancellationError.self) {
            _ = try await creationTask.value
        }
        #expect(drainCompleted.count == 1)
        #expect(self.mockClient.createPlaylistCalls.count == 1)
    }

    @Test("Account boundary keeps a completed track removal applied")
    func accountBoundaryKeepsCompletedTrackRemovalApplied() async {
        let song = Song(
            id: "boundary-track",
            title: "Boundary Track",
            artists: [],
            videoId: "boundary-track",
            playlistSetVideoId: "boundary-set"
        )
        let playlist = Playlist(
            id: "VL-boundary-track",
            title: "Boundary Tracks",
            description: nil,
            thumbnailURL: nil,
            trackCount: 1,
            canDelete: true
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [song],
            duration: nil
        )
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient)
        await viewModel.load()
        self.mockClient.shouldWaitForRemoveSongFromPlaylistResponse = true

        let removalTask = Task {
            await LibraryMutationActions.removeSongFromPlaylist(
                song,
                from: viewModel,
                client: self.mockClient
            )
        }
        #expect(await self.waitForCondition(self.mockClient.removeSongFromPlaylistCalls.count == 1))

        LibraryMutationActions.beginAccountBoundary()
        self.mockClient.resumeNextRemoveSongFromPlaylistResponse()
        await LibraryMutationActions.awaitAccountBoundaryDrain()
        LibraryMutationActions.endAccountBoundary()
        await removalTask.value

        #expect(viewModel.playlistDetail?.tracks.isEmpty == true)
        #expect(viewModel.playlistDetail?.trackCount == 0)
    }

    @Test("Replacing artist reconciliation keeps the successor boundary-tracked")
    func replacingArtistReconciliationKeepsSuccessorTracked() async throws {
        let artist = TestFixtures.makeArtist(id: "UC-reconciliation-successor", name: "Tracked Artist")
        let drainCompleted = LockedCounter()
        LibraryMutationActions.artistReconciliationRetryDelays = [.zero]
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false
        self.mockClient.shouldWaitForLibraryContentResponse = true

        try await LibraryMutationActions.subscribeToArtist(
            artist,
            channelId: artist.id,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )
        #expect(await self.waitForCondition(self.mockClient.getLibraryContentCallCount == 1))

        LibraryMutationActions.artistReconciliationRetryDelays = [.seconds(10)]
        try await LibraryMutationActions.subscribeToArtist(
            artist,
            channelId: artist.id,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        LibraryMutationActions.beginAccountBoundary()
        let drainTask = Task {
            await LibraryMutationActions.awaitAccountBoundaryDrain()
            drainCompleted.increment()
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(drainCompleted.isEmpty)

        self.mockClient.shouldWaitForLibraryContentResponse = false
        self.mockClient.resumeNextLibraryContentResponse()
        await drainTask.value
        LibraryMutationActions.endAccountBoundary()

        #expect(drainCompleted.count == 1)
        #expect(self.mockClient.getLibraryContentCallCount == 1)
    }

    @Test("Stale playlist-creation errors normalize to cancellation")
    func stalePlaylistCreationErrorsNormalizeToCancellation() async {
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeCreatePlaylistReturn = {
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let creationTask = Task {
            try await LibraryMutationActions.withAccountBoundaryTracking {
                try await self.mockClient.createPlaylist(
                    title: "Cancelled Boundary Playlist",
                    description: nil,
                    privacyStatus: .private,
                    videoIds: []
                )
            }
        }
        await requestStarted.wait()

        LibraryMutationActions.beginAccountBoundary()
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.cancelled))
        await releaseRequest.open()
        await LibraryMutationActions.awaitAccountBoundaryDrain()
        LibraryMutationActions.endAccountBoundary()

        await #expect(throws: CancellationError.self) {
            _ = try await creationTask.value
        }
    }

    @Test("Cancelling an in-flight playlist add prevents an account-crossing update")
    func cancellingInFlightPlaylistAddPreventsAccountCrossingUpdate() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-cancelled-add", title: "Cancelled Add")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.libraryViewModel.activateAccountScope("account-a")
        self.mockClient.beforeSubscribeToPlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        let task = Task {
            try await LibraryMutationActions.addPlaylistToLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero
            )
        }

        await requestStarted.wait()
        LibraryMutationActions.cancelPendingPlaylistMutations(for: self.libraryViewModel)
        self.libraryViewModel.activateAccountScope("account-b")
        await releaseRequest.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!self.libraryViewModel.isInLibrary(playlistId: playlist.id))
    }

    @Test("Cancelling delayed playlist add does not reinsert into the next account")
    func cancellingDelayedPlaylistAddPreservesNextAccountSnapshot() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-delayed-add", title: "Delayed Add")
        let applied = LockedCounter()
        self.libraryViewModel.activateAccountScope("account-a")
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        let task = Task {
            try await LibraryMutationActions.addPlaylistToLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .seconds(10),
                onMutationApplied: { applied.increment() }
            )
        }

        #expect(await self.waitForCondition(applied.count == 1))
        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id))
        LibraryMutationActions.cancelPendingPlaylistMutations(for: self.libraryViewModel)
        self.libraryViewModel.activateAccountScope("account-b")

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!self.libraryViewModel.isInLibrary(playlistId: playlist.id))
    }

    @Test("Cancelling delayed playlist removal preserves the next account membership")
    func cancellingDelayedPlaylistRemovalPreservesNextAccountSnapshot() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-delayed-remove", title: "Delayed Remove")
        let applied = LockedCounter()
        self.libraryViewModel.activateAccountScope("account-a")
        self.libraryViewModel.addToLibrary(playlist: playlist)
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        let task = Task {
            try await LibraryMutationActions.removePlaylistFromLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .seconds(10),
                onMutationApplied: { applied.increment() }
            )
        }

        #expect(await self.waitForCondition(applied.count == 1))
        #expect(!self.libraryViewModel.isInLibrary(playlistId: playlist.id))
        LibraryMutationActions.cancelPendingPlaylistMutations(for: self.libraryViewModel)
        self.libraryViewModel.activateAccountScope("account-b")
        self.libraryViewModel.addToLibrary(playlist: playlist)

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id))
    }

    @Test("Account boundary during playlist add refresh cannot reinsert old content")
    func accountBoundaryDuringPlaylistAddRefreshCannotReinsertOldPlaylist() async {
        let oldPlaylist = TestFixtures.makePlaylist(id: "VL-old-account-add", title: "Old Account")
        let nextPlaylist = TestFixtures.makePlaylist(id: "VL-next-account", title: "Next Account")
        self.libraryViewModel.activateAccountScope("account-a")
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false
        self.mockClient.shouldWaitForLibraryContentResponse = true

        let task = Task {
            try await LibraryMutationActions.addPlaylistToLibrary(
                oldPlaylist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero
            )
        }

        #expect(await self.waitForCondition(self.mockClient.getLibraryContentCallCount == 1))
        LibraryMutationActions.cancelPendingPlaylistMutations(for: self.libraryViewModel)
        self.libraryViewModel.activateAccountScope("account-b")
        self.libraryViewModel.addToLibrary(playlist: nextPlaylist)
        self.mockClient.resumeNextLibraryContentResponse()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!self.libraryViewModel.isInLibrary(playlistId: oldPlaylist.id))
        #expect(self.libraryViewModel.isInLibrary(playlistId: nextPlaylist.id))
    }

    @Test("Account boundary during playlist removal refresh preserves matching next-account content")
    func accountBoundaryDuringPlaylistRemovalRefreshPreservesNextAccountPlaylist() async {
        let oldPlaylist = TestFixtures.makePlaylist(id: "VL-shared-account", title: "Old Account")
        let nextPlaylist = TestFixtures.makePlaylist(id: "VL-shared-account", title: "Next Account")
        self.libraryViewModel.activateAccountScope("account-a")
        self.libraryViewModel.addToLibrary(playlist: oldPlaylist)
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false
        self.mockClient.shouldWaitForLibraryContentResponse = true

        let task = Task {
            try await LibraryMutationActions.removePlaylistFromLibrary(
                oldPlaylist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero
            )
        }

        #expect(await self.waitForCondition(self.mockClient.getLibraryContentCallCount == 1))
        LibraryMutationActions.cancelPendingPlaylistMutations(for: self.libraryViewModel)
        self.libraryViewModel.activateAccountScope("account-b")
        self.libraryViewModel.addToLibrary(playlist: nextPlaylist)
        self.mockClient.resumeNextLibraryContentResponse()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(self.libraryViewModel.playlists.contains(nextPlaylist))
    }

    @Test("Newer playlist removal wins over delayed add reconciliation")
    func newerPlaylistRemovalWinsOverDelayedAddReconciliation() async throws {
        let playlist = TestFixtures.makePlaylist(id: "VL-overlap-add-remove", title: "Overlap Playlist")
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false
        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
        ]
        self.mockClient.libraryContentResponseDelays = [.milliseconds(100), .zero]

        async let add: Void = LibraryMutationActions.addPlaylistToLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel,
            reconciliationDelay: .zero
        )

        #expect(await self.waitForCondition(self.libraryViewModel.isInLibrary(playlistId: playlist.id)))

        async let remove: Void = LibraryMutationActions.removePlaylistFromLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel,
            reconciliationDelay: .zero
        )

        try await add
        try await remove

        #expect(!self.libraryViewModel.isInLibrary(playlistId: playlist.id))
        #expect(self.mockClient.subscribeToPlaylistIds == [playlist.id])
        #expect(self.mockClient.unsubscribeFromPlaylistIds == [playlist.id])
        #expect(self.mockClient.getLibraryContentCallCount == 2)
    }

    @Test("Playlist mutations serialize across different library models")
    func playlistMutationsSerializeAcrossLibraryModels() async throws {
        let playlist = TestFixtures.makePlaylist(id: "VL-multi-model-overlap", title: "Shared Playlist")
        let otherLibraryViewModel = LibraryViewModel(client: self.mockClient)
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false
        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
        ]
        self.mockClient.libraryContentResponseDelays = [.milliseconds(100), .zero, .zero]

        async let add: Void = LibraryMutationActions.addPlaylistToLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel,
            reconciliationDelay: .zero
        )

        #expect(await self.waitForCondition(self.libraryViewModel.isInLibrary(playlistId: playlist.id)))

        async let remove: Void = LibraryMutationActions.removePlaylistFromLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: otherLibraryViewModel,
            reconciliationDelay: .zero
        )

        try await add
        try await remove

        #expect(!self.libraryViewModel.isInLibrary(playlistId: playlist.id))
        #expect(!otherLibraryViewModel.isInLibrary(playlistId: playlist.id))
        #expect(self.mockClient.subscribeToPlaylistIds == [playlist.id])
        #expect(self.mockClient.unsubscribeFromPlaylistIds == [playlist.id])
    }

    @Test("Playlist additions update every active library model")
    func playlistAdditionsUpdateEveryActiveLibraryModel() async throws {
        let playlist = TestFixtures.makePlaylist(id: "VL-multi-model-add", title: "Shared Addition")
        let otherLibraryViewModel = LibraryViewModel(client: self.mockClient)
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        try await LibraryMutationActions.addPlaylistToLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: otherLibraryViewModel,
            reconciliationDelay: .zero
        )

        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id))
        #expect(otherLibraryViewModel.isInLibrary(playlistId: playlist.id))
    }

    @Test("Newer playlist add wins over delayed removal reconciliation")
    func newerPlaylistAddWinsOverDelayedRemovalReconciliation() async throws {
        let playlist = TestFixtures.makePlaylist(id: "VL-overlap-remove-add", title: "Overlap Playlist")
        self.libraryViewModel.addToLibrary(playlist: playlist)
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false
        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
        ]
        self.mockClient.libraryContentResponseDelays = [.milliseconds(100), .zero]

        async let remove: Void = LibraryMutationActions.removePlaylistFromLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel,
            reconciliationDelay: .zero
        )

        #expect(await self.waitForCondition(!self.libraryViewModel.isInLibrary(playlistId: playlist.id)))

        async let add: Void = LibraryMutationActions.addPlaylistToLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel,
            reconciliationDelay: .zero
        )

        try await remove
        try await add

        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id))
        #expect(self.mockClient.unsubscribeFromPlaylistIds == [playlist.id])
        #expect(self.mockClient.subscribeToPlaylistIds == [playlist.id])
        #expect(self.mockClient.getLibraryContentCallCount == 2)
    }

    @Test("Cancelling a playlist mutation caller cancels its tracked operation")
    func callerCancellationPropagatesToPlaylistMutation() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-caller-cancelled", title: "Caller Cancelled")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        let applied = LockedCounter()
        self.mockClient.beforeSubscribeToPlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        let task = Task {
            try await LibraryMutationActions.addPlaylistToLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero,
                onMutationApplied: { applied.increment() }
            )
        }

        await requestStarted.wait()
        task.cancel()
        await releaseRequest.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(applied.isEmpty)
        #expect(!self.libraryViewModel.isInLibrary(playlistId: playlist.id))
        #expect(self.mockClient.getLibraryContentCallCount == 0)
    }

    @Test("Account cancellation cancels every queued mutation for one playlist")
    func accountCancellationCancelsEveryQueuedPlaylistMutation() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-cancel-chain", title: "Cancel Chain")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        let predecessorWasCancelled = LockedCounter()
        self.mockClient.beforeSubscribeToPlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
            if Task.isCancelled {
                predecessorWasCancelled.increment()
            }
        }
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        let firstTask = Task {
            try await LibraryMutationActions.addPlaylistToLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero
            )
        }
        await requestStarted.wait()

        let secondTask = Task {
            try await LibraryMutationActions.removePlaylistFromLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero
            )
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        LibraryMutationActions.cancelAllPendingLibraryMutations()
        await releaseRequest.open()

        await #expect(throws: CancellationError.self) { try await firstTask.value }
        await #expect(throws: CancellationError.self) { try await secondTask.value }
        #expect(predecessorWasCancelled.count == 1)
        #expect(self.mockClient.unsubscribeFromPlaylistIds.isEmpty)
    }

    @Test("Account cancellation cancels every queued mutation for one album")
    func accountCancellationCancelsEveryQueuedAlbumMutation() async {
        let album = TestFixtures.makeAlbum(
            id: "MPRE-cancel-chain",
            title: "Cancel Chain",
            libraryTargetId: "OLAK-cancel-chain"
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        let predecessorWasCancelled = LockedCounter()
        self.mockClient.beforeSubscribeToPlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
            if Task.isCancelled {
                predecessorWasCancelled.increment()
            }
        }
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        let firstTask = Task {
            try await LibraryMutationActions.addAlbumToLibrary(
                album,
                targetPlaylistId: "OLAK-cancel-chain",
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero
            )
        }
        await requestStarted.wait()

        let secondTask = Task {
            try await LibraryMutationActions.removeAlbumFromLibrary(
                album,
                targetPlaylistId: "OLAK-cancel-chain",
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero
            )
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        LibraryMutationActions.cancelAllPendingLibraryMutations()
        await releaseRequest.open()

        await #expect(throws: CancellationError.self) { try await firstTask.value }
        await #expect(throws: CancellationError.self) { try await secondTask.value }
        #expect(predecessorWasCancelled.count == 1)
        #expect(self.mockClient.unsubscribeFromPlaylistIds.isEmpty)
    }

    @Test("Cancelling one owner preserves the shared playlist serialization tail")
    func ownerCancellationPreservesSharedPlaylistSerializationTail() async throws {
        let playlist = TestFixtures.makePlaylist(id: "VL-owner-tail", title: "Owner Tail")
        let firstLibraryViewModel = self.libraryViewModel
        let cancelledLibraryViewModel = LibraryViewModel(client: self.mockClient)
        let latestLibraryViewModel = LibraryViewModel(client: self.mockClient)
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeSubscribeToPlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        let firstTask = Task {
            try await LibraryMutationActions.addPlaylistToLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: firstLibraryViewModel,
                reconciliationDelay: .zero
            )
        }
        await requestStarted.wait()

        let cancelledTask = Task {
            try await LibraryMutationActions.removePlaylistFromLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: cancelledLibraryViewModel,
                reconciliationDelay: .zero
            )
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        LibraryMutationActions.cancelPendingPlaylistMutations(for: cancelledLibraryViewModel)

        let latestTask = Task {
            try await LibraryMutationActions.removePlaylistFromLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: latestLibraryViewModel,
                reconciliationDelay: .zero
            )
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(self.mockClient.unsubscribeFromPlaylistIds.isEmpty)

        await releaseRequest.open()
        try await firstTask.value
        await #expect(throws: CancellationError.self) { try await cancelledTask.value }
        try await latestTask.value

        #expect(!firstLibraryViewModel.isInLibrary(playlistId: playlist.id))
        #expect(self.mockClient.unsubscribeFromPlaylistIds == [playlist.id])
    }

    @Test("Stale playlist client errors normalize to cancellation")
    func stalePlaylistClientErrorNormalizesToCancellation() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-stale-error", title: "Stale Error")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeSubscribeToPlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let task = Task {
            try await LibraryMutationActions.addPlaylistToLibrary(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel,
                reconciliationDelay: .zero
            )
        }

        await requestStarted.wait()
        LibraryMutationActions.cancelPendingPlaylistMutations(for: self.libraryViewModel)
        self.mockClient.shouldThrowError = URLError(.notConnectedToInternet)
        await releaseRequest.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("Account boundary prevents an in-flight podcast add from updating the next account")
    func accountBoundaryCancelsInFlightPodcastAdd() async {
        let podcast = TestFixtures.makePodcastShow(id: "MPSPPLboundary-podcast")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.libraryViewModel.activateAccountScope("account-a")
        self.mockClient.beforeSubscribeToPodcastReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        self.mockClient.shouldAutoUpdatePodcastLibraryOnMutation = false

        let task = Task {
            try await LibraryMutationActions.subscribeToPodcast(
                podcast,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel
            )
        }

        await requestStarted.wait()
        LibraryMutationActions.cancelAllPendingLibraryMutations()
        self.libraryViewModel.activateAccountScope("account-b")
        await releaseRequest.open()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!self.libraryViewModel.isInLibrary(podcastId: podcast.id))
    }

    @Test("Account boundary prevents an in-flight artist add from updating the next account")
    func accountBoundaryCancelsInFlightArtistAdd() async {
        let artist = TestFixtures.makeArtist(id: "UC-boundary-artist", name: "Boundary Artist")
        self.libraryViewModel.activateAccountScope("account-a")
        self.mockClient.subscribeToArtistDelay = .milliseconds(100)
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false

        let task = Task {
            try await LibraryMutationActions.subscribeToArtist(
                artist,
                channelId: artist.id,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel
            )
        }

        #expect(await self.waitForCondition(self.mockClient.subscribeToArtistCalled))
        LibraryMutationActions.cancelAllPendingLibraryMutations()
        self.libraryViewModel.activateAccountScope("account-b")

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!self.libraryViewModel.isInLibrary(artistId: artist.id))
    }

    @Test("Caller cancellation rolls back an uncommitted optimistic artist add")
    func callerCancellationRollsBackOptimisticArtistAdd() async {
        let artist = TestFixtures.makeArtist(id: "UC-cancelled-artist", name: "Cancelled Artist")
        self.libraryViewModel.activateAccountScope("account-a")
        self.mockClient.subscribeToArtistDelay = .milliseconds(100)
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false

        let task = Task {
            try await LibraryMutationActions.subscribeToArtist(
                artist,
                channelId: artist.id,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel
            )
        }

        #expect(await self.waitForCondition(self.mockClient.subscribeToArtistCalled))
        #expect(self.libraryViewModel.isInLibrary(artistId: artist.id))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!self.libraryViewModel.isInLibrary(artistId: artist.id))
    }

    @Test("Cancelling playlist deletion before server success restores optimistic membership")
    func cancelledPlaylistDeletionRestoresMembership() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-cancelled-delete", title: "Cancelled Delete")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.libraryViewModel.addToLibrary(playlist: playlist)
        self.mockClient.beforeDeletePlaylistReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let task = Task {
            try await LibraryMutationActions.deletePlaylist(
                playlist,
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel
            )
        }

        await requestStarted.wait()
        #expect(!self.libraryViewModel.isInLibrary(playlistId: playlist.id))
        LibraryMutationActions.cancelAllPendingLibraryMutations()
        self.libraryViewModel.activateAccountScope("resolved-primary", isPrimary: true)
        await releaseRequest.open()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id))
    }

    private func waitForCondition(_ condition: @autoclosure () -> Bool, timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !condition() {
            guard clock.now < deadline else { return condition() }
            try? await Task.sleep(for: .milliseconds(10))
        }

        return true
    }
}
