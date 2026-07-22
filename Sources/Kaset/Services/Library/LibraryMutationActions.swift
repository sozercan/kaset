// swiftlint:disable file_length

import Foundation

/// Orchestrates Library mutations that need optimistic UI updates, cache invalidation,
/// and eventual-consistency reconciliation after YouTube Music accepts a change.
@MainActor
// swiftlint:disable:next type_body_length
enum LibraryMutationActions {
    private struct PlaylistDeletionKey: Hashable {
        let playlistId: String
        let owner: MusicAccountMutationOwner?
    }

    private struct PendingPlaylistDeletion {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct PendingAlbumMutation {
        let owner: AlbumMutationOwner
        let task: Task<Void, Error>
    }

    private struct PendingPlaylistMutation {
        let owner: PlaylistMutationOwner
        let task: Task<Void, Error>
    }

    private struct PendingArtistReconciliation {
        let task: Task<Void, Never>
    }

    private enum TrackedMutationResult<Value> {
        case pending
        case value(Value)
    }

    private enum PlaylistMutationOwner: Hashable {
        case viewModel(ObjectIdentifier)
        case unscoped
    }

    private struct PlaylistMutationContext {
        let owner: PlaylistMutationOwner
        let generation: UInt64
    }

    private struct PlaylistMutationKey: Hashable {
        let identity: String
    }

    private enum AlbumMutationOwner: Hashable {
        case viewModel(ObjectIdentifier)
        case unscoped
    }

    private struct AlbumMutationKey: Hashable {
        let identity: String
    }

    private struct AlbumMutationContext {
        let owner: AlbumMutationOwner
        let generation: UInt64
    }

    private struct AlbumMutationRequest {
        let album: Album
        let targetPlaylistId: String
        let client: any YTMusicClientProtocol
        let libraryViewModel: LibraryViewModel?
        let reconciliationDelay: Duration
        let onMutationApplied: @MainActor () -> Void
    }

    static var artistReconciliationRetryDelays: [Duration] = [.seconds(2), .seconds(3)]

    private static var artistReconciliationTasks: [String: PendingArtistReconciliation] = [:]
    private static var latestArtistReconciliationIDs: [String: String] = [:]
    private static var pendingPlaylistDeletions: [PlaylistDeletionKey: PendingPlaylistDeletion] = [:]
    private static var pendingPlaylistMutations: [UUID: PendingPlaylistMutation] = [:]
    private static var latestPlaylistMutationIDs: [PlaylistMutationKey: UUID] = [:]
    private static var playlistMutationGenerations: [PlaylistMutationOwner: UInt64] = [:]
    private static var pendingAlbumMutations: [UUID: PendingAlbumMutation] = [:]
    private static var latestAlbumMutationIDs: [AlbumMutationKey: UUID] = [:]
    private static var albumMutationGenerations: [AlbumMutationOwner: UInt64] = [:]
    private static var accountBoundaryGeneration: UInt64 = 0
    private static var accountBoundaryDepth: Int = 0
    private static var pendingAccountBoundaryMutations: [UUID: Task<Void, Error>] = [:]
    private static var accountBoundaryDrainTask: Task<Void, Never>?

    static func beginAccountBoundary() {
        self.accountBoundaryDepth += 1
        let throwingTasks = self.pendingPlaylistMutations.values.map(\.task)
            + self.pendingAlbumMutations.values.map(\.task)
            + self.pendingPlaylistDeletions.values.map(\.task)
            + Array(self.pendingAccountBoundaryMutations.values)
        let nonthrowingTasks = self.artistReconciliationTasks.values.map(\.task)
        self.cancelAllPendingLibraryMutations()
        guard self.accountBoundaryDrainTask == nil else { return }
        guard !throwingTasks.isEmpty || !nonthrowingTasks.isEmpty else { return }
        let drainTask = Task { @MainActor in
            for task in throwingTasks {
                _ = try? await task.value
            }
            for task in nonthrowingTasks {
                await task.value
            }
        }
        self.accountBoundaryDrainTask = drainTask
        Task { @MainActor in
            await drainTask.value
            if self.accountBoundaryDrainTask == drainTask {
                self.accountBoundaryDrainTask = nil
            }
        }
    }

    static func endAccountBoundary() {
        precondition(self.accountBoundaryDepth > 0, "Unbalanced Library account boundary")
        self.accountBoundaryDepth -= 1
    }

    static func awaitAccountBoundaryDrain() async {
        while let drainTask = self.accountBoundaryDrainTask {
            await drainTask.value
            if self.accountBoundaryDrainTask == drainTask {
                self.accountBoundaryDrainTask = nil
            }
        }
    }

    static func cancelPendingLibraryMutations(for libraryViewModel: LibraryViewModel?) {
        self.cancelPendingPlaylistMutations(for: libraryViewModel)
        self.cancelPendingAlbumMutations(for: libraryViewModel)
    }

    static func cancelAllPendingLibraryMutations() {
        self.accountBoundaryGeneration &+= 1
        self.cancelAllPendingPlaylistMutations()
        self.cancelAllPendingAlbumMutations()
        self.cancelAllPendingPlaylistDeletions()
        self.cancelAllArtistReconciliationTasks()
        self.cancelAllPendingAccountBoundaryMutations()
    }

    static func cancelPendingPlaylistMutations(for libraryViewModel: LibraryViewModel?) {
        let owner = self.playlistMutationOwner(for: libraryViewModel)
        self.playlistMutationGenerations[owner, default: 0] &+= 1
        let matchingIDs = self.pendingPlaylistMutations.compactMap { id, mutation in
            mutation.owner == owner ? id : nil
        }
        let tasks = matchingIDs.compactMap { self.pendingPlaylistMutations[$0]?.task }
        for task in tasks {
            task.cancel()
        }
    }

    static func cancelAllPendingPlaylistMutations() {
        let owners = Set(self.playlistMutationGenerations.keys)
            .union(self.pendingPlaylistMutations.values.map(\.owner))
            .union([.unscoped])
        for owner in owners {
            self.playlistMutationGenerations[owner, default: 0] &+= 1
        }

        let tasks = self.pendingPlaylistMutations.values.map(\.task)
        self.pendingPlaylistMutations.removeAll()
        self.latestPlaylistMutationIDs.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private static func cancelAllPendingPlaylistDeletions() {
        let tasks = self.pendingPlaylistDeletions.values.map(\.task)
        self.pendingPlaylistDeletions.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private static func cancelAllArtistReconciliationTasks() {
        let tasks = self.artistReconciliationTasks.values.map(\.task)
        self.artistReconciliationTasks.removeAll()
        self.latestArtistReconciliationIDs.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private static func cancelAllPendingAccountBoundaryMutations() {
        let tasks = self.pendingAccountBoundaryMutations.values
        self.pendingAccountBoundaryMutations.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private static func checkAccountBoundary(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard self.accountBoundaryDepth == 0,
              self.accountBoundaryDrainTask == nil,
              generation == self.accountBoundaryGeneration
        else { throw CancellationError() }
    }

    private static func isAccountBoundaryCurrent(_ generation: UInt64) -> Bool {
        !Task.isCancelled
            && self.accountBoundaryDepth == 0
            && self.accountBoundaryDrainTask == nil
            && generation == self.accountBoundaryGeneration
    }

    private static func runTrackedAccountBoundaryMutation(
        _ operation: @MainActor @escaping () async throws -> Void
    ) async throws {
        let boundaryGeneration = self.accountBoundaryGeneration
        try self.checkAccountBoundary(boundaryGeneration)
        let operationID = UUID()
        let task = Task { @MainActor in
            try self.checkAccountBoundary(boundaryGeneration)
            try await operation()
        }
        self.pendingAccountBoundaryMutations[operationID] = task
        defer { self.pendingAccountBoundaryMutations.removeValue(forKey: operationID) }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func withAccountBoundaryTracking<Value>(
        _ operation: @MainActor @escaping () async throws -> Value
    ) async throws -> Value {
        let boundaryGeneration = self.accountBoundaryGeneration
        var result: TrackedMutationResult<Value> = .pending
        try await self.runTrackedAccountBoundaryMutation {
            do {
                let value = try await operation()
                try self.checkAccountBoundary(boundaryGeneration)
                result = .value(value)
            } catch {
                guard self.isAccountBoundaryCurrent(boundaryGeneration) else {
                    throw CancellationError()
                }
                throw error
            }
        }
        guard case let .value(value) = result else { throw CancellationError() }
        return value
    }

    static func cancelPendingAlbumMutations(for libraryViewModel: LibraryViewModel?) {
        let owner = self.albumMutationOwner(for: libraryViewModel)
        self.albumMutationGenerations[owner, default: 0] &+= 1
        let matchingIDs = self.pendingAlbumMutations.compactMap { id, mutation in
            mutation.owner == owner ? id : nil
        }
        let tasks = matchingIDs.compactMap { self.pendingAlbumMutations[$0]?.task }
        for task in tasks {
            task.cancel()
        }
    }

    static func cancelAllPendingAlbumMutations() {
        let owners = Set(self.albumMutationGenerations.keys)
            .union(self.pendingAlbumMutations.values.map(\.owner))
            .union([.unscoped])
        for owner in owners {
            self.albumMutationGenerations[owner, default: 0] &+= 1
        }

        let tasks = self.pendingAlbumMutations.values.map(\.task)
        self.pendingAlbumMutations.removeAll()
        self.latestAlbumMutationIDs.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    /// Adds a song to a playlist.
    static func addSongToPlaylist(
        _ song: Song,
        playlist: AddToPlaylistOption,
        client: any YTMusicClientProtocol
    ) async {
        let boundaryGeneration = self.accountBoundaryGeneration
        do {
            try await self.runTrackedAccountBoundaryMutation {
                try self.checkAccountBoundary(boundaryGeneration)
                try await client.addSongToPlaylist(
                    videoId: song.videoId,
                    playlistId: playlist.playlistId,
                    allowDuplicate: false
                )
                try self.checkAccountBoundary(boundaryGeneration)
                self.invalidateResponseCaches()
                DiagnosticsLogger.api.info("Added song '\(song.title)' to playlist '\(playlist.title)'")
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.isAccountBoundaryCurrent(boundaryGeneration) else { return }
            DiagnosticsLogger.api.error("Failed to add song to playlist: \(error.localizedDescription)")
        }
    }

    /// Removes a song from the playlist currently loaded in `viewModel`. The row is removed
    /// optimistically and restored if the server mutation fails.
    static func removeSongFromPlaylist(
        _ song: Song,
        from viewModel: PlaylistDetailViewModel,
        client: any YTMusicClientProtocol
    ) async {
        guard let setVideoId = song.playlistSetVideoId else {
            DiagnosticsLogger.api.error("Cannot remove '\(song.title)' from playlist: missing setVideoId")
            HapticService.error()
            return
        }

        let boundaryGeneration = self.accountBoundaryGeneration
        do {
            try await self.runTrackedAccountBoundaryMutation {
                try self.checkAccountBoundary(boundaryGeneration)
                guard let removal = viewModel.beginOptimisticTrackRemoval(setVideoId: setVideoId) else { return }

                var didMutateRemotely = false
                do {
                    try await client.removeSongFromPlaylist(
                        videoId: song.videoId,
                        setVideoId: setVideoId,
                        playlistId: viewModel.playlistID
                    )
                    didMutateRemotely = true
                    viewModel.confirmTrackRemoval(removal)
                    try self.checkAccountBoundary(boundaryGeneration)
                    Self.invalidateResponseCaches()
                    HapticService.success()
                    DiagnosticsLogger.api.info("Removed song '\(song.title)' from playlist")
                } catch is CancellationError {
                    if !didMutateRemotely {
                        await viewModel.rollbackTrackRemoval(removal)
                    }
                    throw CancellationError()
                } catch {
                    guard self.isAccountBoundaryCurrent(boundaryGeneration) else {
                        if !didMutateRemotely {
                            await viewModel.rollbackTrackRemoval(removal)
                        }
                        throw CancellationError()
                    }
                    await viewModel.rollbackTrackRemoval(removal)
                    HapticService.error()
                    DiagnosticsLogger.api.error("Failed to remove song from playlist: \(error.localizedDescription)")
                }
            }
        } catch is CancellationError {
            return
        } catch {
            DiagnosticsLogger.api.error("Failed to remove song from playlist: \(error.localizedDescription)")
        }
    }

    /// Adds a playlist to the library.
    static func addPlaylistToLibrary(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?,
        reconciliationDelay: Duration = .milliseconds(500),
        onMutationApplied: @MainActor @escaping () -> Void = {}
    ) async throws {
        try await self.enqueuePlaylistMutation(
            playlistId: playlist.id,
            libraryViewModel: libraryViewModel
        ) { context in
            do {
                try self.checkPlaylistMutationIsCurrent(context.generation, owner: context.owner)
                try await client.subscribeToPlaylist(playlistId: playlist.id)
                try self.checkPlaylistMutationIsCurrent(context.generation, owner: context.owner)
                self.invalidateResponseCaches()
                LibraryMutationBroadcaster.shared.playlistAdded(playlist)
                onMutationApplied()

                // Library browse responses can lag briefly behind a successful add.
                try await Task.sleep(for: reconciliationDelay)
                try self.checkPlaylistMutationIsCurrent(context.generation, owner: context.owner)
                let reconciled = await LibraryMutationBroadcaster.shared.reconcileAddedPlaylist(
                    playlist,
                    whileValid: { Self.isPlaylistMutationCurrent(context) }
                )
                guard reconciled else { throw CancellationError() }
                self.invalidateResponseCaches()
                DiagnosticsLogger.api.info("Added playlist to library: \(playlist.title)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.isPlaylistMutationCurrent(context) else { throw CancellationError() }
                DiagnosticsLogger.api.error("Failed to add playlist to library: \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// Removes a playlist from the library.
    static func removePlaylistFromLibrary(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?,
        reconciliationDelay: Duration = .milliseconds(500),
        onMutationApplied: @MainActor @escaping () -> Void = {}
    ) async throws {
        try await self.enqueuePlaylistMutation(
            playlistId: playlist.id,
            libraryViewModel: libraryViewModel
        ) { context in
            do {
                try self.checkPlaylistMutationIsCurrent(context.generation, owner: context.owner)
                try await client.unsubscribeFromPlaylist(playlistId: playlist.id)
                try self.checkPlaylistMutationIsCurrent(context.generation, owner: context.owner)
                self.invalidateResponseCaches()
                libraryViewModel?.markNeedsReloadOnActivation()
                LibraryMutationBroadcaster.shared.playlistRemoved(playlistId: playlist.id)
                onMutationApplied()

                // Library browse responses can lag briefly behind a successful removal.
                try await Task.sleep(for: reconciliationDelay)
                try self.checkPlaylistMutationIsCurrent(context.generation, owner: context.owner)
                let reconciled = await LibraryMutationBroadcaster.shared.reconcileRemovedPlaylist(
                    playlistId: playlist.id,
                    whileValid: { Self.isPlaylistMutationCurrent(context) }
                )
                guard reconciled else { throw CancellationError() }
                self.invalidateResponseCaches()
                DiagnosticsLogger.api.info("Removed playlist from library: \(playlist.title)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.isPlaylistMutationCurrent(context) else { throw CancellationError() }
                DiagnosticsLogger.api.error("Failed to remove playlist from library: \(error.localizedDescription)")
                throw error
            }
        }
    }

    private static func enqueuePlaylistMutation(
        playlistId: String,
        libraryViewModel: LibraryViewModel?,
        operation: @MainActor @escaping (PlaylistMutationContext) async throws -> Void
    ) async throws {
        let owner = self.playlistMutationOwner(for: libraryViewModel)
        let boundaryGeneration = self.accountBoundaryGeneration
        try self.checkAccountBoundary(boundaryGeneration)
        let key = PlaylistMutationKey(
            identity: LibraryContentIdentity.playlistKey(for: playlistId)
        )
        let previousTask = self.latestPlaylistMutationIDs[key]
            .flatMap { self.pendingPlaylistMutations[$0]?.task }
        let operationID = UUID()
        let generation = self.playlistMutationGenerations[owner, default: 0]
        let task = Task { @MainActor in
            if let previousTask {
                _ = try? await previousTask.value
            }
            try self.checkAccountBoundary(boundaryGeneration)
            try self.checkPlaylistMutationIsCurrent(generation, owner: owner)
            try await operation(PlaylistMutationContext(owner: owner, generation: generation))
        }

        self.pendingPlaylistMutations[operationID] = PendingPlaylistMutation(
            owner: owner,
            task: task
        )
        self.latestPlaylistMutationIDs[key] = operationID
        defer {
            self.pendingPlaylistMutations.removeValue(forKey: operationID)
            if self.latestPlaylistMutationIDs[key] == operationID {
                self.latestPlaylistMutationIDs.removeValue(forKey: key)
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func checkPlaylistMutationIsCurrent(
        _ generation: UInt64,
        owner: PlaylistMutationOwner
    ) throws {
        try Task.checkCancellation()
        guard generation == self.playlistMutationGenerations[owner, default: 0] else {
            throw CancellationError()
        }
    }

    private static func isPlaylistMutationCurrent(_ context: PlaylistMutationContext) -> Bool {
        !Task.isCancelled
            && context.generation == self.playlistMutationGenerations[context.owner, default: 0]
    }

    private static func playlistMutationOwner(for libraryViewModel: LibraryViewModel?) -> PlaylistMutationOwner {
        guard let libraryViewModel else { return .unscoped }
        return .viewModel(ObjectIdentifier(libraryViewModel))
    }

    /// Adds an album to the library using its OLAK playlist target.
    static func addAlbumToLibrary(
        _ album: Album,
        targetPlaylistId: String,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?,
        reconciliationDelay: Duration = .milliseconds(500),
        onMutationApplied: @MainActor @escaping () -> Void = {}
    ) async throws {
        let request = AlbumMutationRequest(
            album: album,
            targetPlaylistId: targetPlaylistId,
            client: client,
            libraryViewModel: libraryViewModel,
            reconciliationDelay: reconciliationDelay,
            onMutationApplied: onMutationApplied
        )
        try await self.enqueueAlbumMutation(
            albumId: album.id,
            targetPlaylistId: targetPlaylistId,
            libraryViewModel: libraryViewModel
        ) { context in
            try await Self.performAddAlbumToLibrary(request, context: context)
        }
    }

    private static func performAddAlbumToLibrary(
        _ request: AlbumMutationRequest,
        context: AlbumMutationContext
    ) async throws {
        do {
            try self.checkAlbumMutationIsCurrent(context.generation, owner: context.owner)
            try await request.client.subscribeToPlaylist(playlistId: request.targetPlaylistId)
            try self.checkAlbumMutationIsCurrent(context.generation, owner: context.owner)
            let libraryAlbum = Album(
                id: request.album.id,
                title: request.album.title,
                artists: request.album.artists,
                thumbnailURL: request.album.thumbnailURL,
                year: request.album.year,
                trackCount: request.album.trackCount,
                libraryTargetId: request.targetPlaylistId
            )
            self.invalidateResponseCaches()
            request.libraryViewModel?.markNeedsReloadOnActivation()
            LibraryMutationBroadcaster.shared.albumAdded(libraryAlbum)
            request.onMutationApplied()

            try await Task.sleep(for: request.reconciliationDelay)
            try self.checkAlbumMutationIsCurrent(context.generation, owner: context.owner)
            let reconciled = await LibraryMutationBroadcaster.shared.reconcileAddedAlbum(
                libraryAlbum,
                whileValid: { Self.isAlbumMutationCurrent(context) }
            )
            guard reconciled else { throw CancellationError() }
            self.invalidateResponseCaches()
            DiagnosticsLogger.api.info("Added album to library: \(request.album.title)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard self.isAlbumMutationCurrent(context) else { throw CancellationError() }
            DiagnosticsLogger.api.error("Failed to add album to library: \(error.localizedDescription)")
            throw error
        }
    }

    /// Removes an album from the library using its OLAK playlist target.
    static func removeAlbumFromLibrary(
        _ album: Album,
        targetPlaylistId: String,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?,
        reconciliationDelay: Duration = .milliseconds(500),
        onMutationApplied: @MainActor @escaping () -> Void = {}
    ) async throws {
        let request = AlbumMutationRequest(
            album: album,
            targetPlaylistId: targetPlaylistId,
            client: client,
            libraryViewModel: libraryViewModel,
            reconciliationDelay: reconciliationDelay,
            onMutationApplied: onMutationApplied
        )
        try await self.enqueueAlbumMutation(
            albumId: album.id,
            targetPlaylistId: targetPlaylistId,
            libraryViewModel: libraryViewModel
        ) { context in
            try await Self.performRemoveAlbumFromLibrary(request, context: context)
        }
    }

    private static func performRemoveAlbumFromLibrary(
        _ request: AlbumMutationRequest,
        context: AlbumMutationContext
    ) async throws {
        do {
            try self.checkAlbumMutationIsCurrent(context.generation, owner: context.owner)
            try await request.client.unsubscribeFromPlaylist(playlistId: request.targetPlaylistId)
            try self.checkAlbumMutationIsCurrent(context.generation, owner: context.owner)
            self.invalidateResponseCaches()
            request.libraryViewModel?.markNeedsReloadOnActivation()
            LibraryMutationBroadcaster.shared.albumRemoved(
                albumId: request.album.id,
                targetPlaylistId: request.targetPlaylistId
            )
            request.onMutationApplied()

            try await Task.sleep(for: request.reconciliationDelay)
            try self.checkAlbumMutationIsCurrent(context.generation, owner: context.owner)
            let reconciled = await LibraryMutationBroadcaster.shared.reconcileRemovedAlbum(
                albumId: request.album.id,
                targetPlaylistId: request.targetPlaylistId,
                whileValid: { Self.isAlbumMutationCurrent(context) }
            )
            guard reconciled else { throw CancellationError() }
            self.invalidateResponseCaches()
            DiagnosticsLogger.api.info("Removed album from library: \(request.album.title)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard self.isAlbumMutationCurrent(context) else { throw CancellationError() }
            DiagnosticsLogger.api.error("Failed to remove album from library: \(error.localizedDescription)")
            throw error
        }
    }

    private static func enqueueAlbumMutation(
        albumId: String,
        targetPlaylistId: String,
        libraryViewModel: LibraryViewModel?,
        operation: @MainActor @escaping (AlbumMutationContext) async throws -> Void
    ) async throws {
        let identity = LibraryContentIdentity.albumKey(
            albumId: albumId,
            targetPlaylistId: targetPlaylistId
        )
        let owner = self.albumMutationOwner(for: libraryViewModel)
        let boundaryGeneration = self.accountBoundaryGeneration
        try self.checkAccountBoundary(boundaryGeneration)
        let key = AlbumMutationKey(identity: identity)
        let previousTask = self.latestAlbumMutationIDs[key]
            .flatMap { self.pendingAlbumMutations[$0]?.task }
        let mutationId = UUID()
        let mutationGeneration = self.albumMutationGenerations[owner, default: 0]
        let task = Task { @MainActor in
            if let previousTask {
                _ = try? await previousTask.value
            }
            try self.checkAccountBoundary(boundaryGeneration)
            try self.checkAlbumMutationIsCurrent(mutationGeneration, owner: owner)
            try await operation(AlbumMutationContext(owner: owner, generation: mutationGeneration))
        }

        self.pendingAlbumMutations[mutationId] = PendingAlbumMutation(
            owner: owner,
            task: task
        )
        self.latestAlbumMutationIDs[key] = mutationId
        defer {
            self.pendingAlbumMutations.removeValue(forKey: mutationId)
            if self.latestAlbumMutationIDs[key] == mutationId {
                self.latestAlbumMutationIDs.removeValue(forKey: key)
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func checkAlbumMutationIsCurrent(
        _ generation: UInt64,
        owner: AlbumMutationOwner
    ) throws {
        try Task.checkCancellation()
        guard generation == self.albumMutationGenerations[owner, default: 0] else {
            throw CancellationError()
        }
    }

    private static func isAlbumMutationCurrent(_ context: AlbumMutationContext) -> Bool {
        !Task.isCancelled
            && context.generation == self.albumMutationGenerations[context.owner, default: 0]
    }

    private static func albumMutationOwner(for libraryViewModel: LibraryViewModel?) -> AlbumMutationOwner {
        guard let libraryViewModel else { return .unscoped }
        return .viewModel(ObjectIdentifier(libraryViewModel))
    }

    /// Permanently deletes a playlist owned by the user.
    static func deletePlaylist(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?,
        owner: MusicAccountMutationOwner? = nil,
        whileValid isCurrent: @escaping () -> Bool = { true }
    ) async throws {
        guard isCurrent() else { throw CancellationError() }
        let boundaryGeneration = self.accountBoundaryGeneration
        try self.checkAccountBoundary(boundaryGeneration)
        let key = PlaylistDeletionKey(
            playlistId: LibraryContentIdentity.playlistKey(for: playlist.id),
            owner: owner
        )
        if let pendingDeletion = self.pendingPlaylistDeletions[key] {
            try await pendingDeletion.task.value
            return
        }

        let operationID = UUID()
        let pinnedItemsManager = SidebarPinnedItemsManager.shared
        let removedPins = pinnedItemsManager.stagePlaylistPinRemoval(matching: playlist.id)
        let removalReceipt = LibraryMutationBroadcaster.shared.playlistRemoved(
            playlistId: playlist.id
        )
        let task = Task { @MainActor in
            var didDeleteRemotely = false
            do {
                try self.checkAccountBoundary(boundaryGeneration)
                guard isCurrent() else { throw CancellationError() }
                try await client.deletePlaylist(playlistId: playlist.id)
                didDeleteRemotely = true
                pinnedItemsManager.commitPlaylistPinRemoval(removedPins)
                try self.checkAccountBoundary(boundaryGeneration)
                guard isCurrent() else { throw CancellationError() }
                self.invalidateResponseCaches()
                libraryViewModel?.markNeedsReloadOnActivation()
                DiagnosticsLogger.api.info("Deleted playlist: \(playlist.title)")

                // Library browse responses can lag briefly behind a successful deletion.
                try await Task.sleep(for: .milliseconds(500))
                try self.checkAccountBoundary(boundaryGeneration)
                guard isCurrent() else { throw CancellationError() }
                let reconciled = await LibraryMutationBroadcaster.shared.reconcileRemovedPlaylist(
                    playlistId: playlist.id,
                    whileValid: { Self.isAccountBoundaryCurrent(boundaryGeneration) && isCurrent() }
                )
                guard reconciled else { throw CancellationError() }
                self.invalidateResponseCaches()
            } catch is CancellationError {
                if !didDeleteRemotely {
                    pinnedItemsManager.restore(removedPins)
                    LibraryMutationBroadcaster.shared.rollbackPlaylistRemoval(
                        playlist,
                        receipt: removalReceipt
                    )
                }
                throw CancellationError()
            } catch {
                guard self.isAccountBoundaryCurrent(boundaryGeneration), isCurrent() else {
                    if !didDeleteRemotely {
                        pinnedItemsManager.restore(removedPins)
                        LibraryMutationBroadcaster.shared.rollbackPlaylistRemoval(
                            playlist,
                            receipt: removalReceipt
                        )
                    }
                    throw CancellationError()
                }
                guard isCurrent() else {
                    if !didDeleteRemotely {
                        pinnedItemsManager.restore(removedPins)
                    }
                    throw CancellationError()
                }
                pinnedItemsManager.restore(removedPins)
                LibraryMutationBroadcaster.shared.rollbackPlaylistRemoval(
                    playlist,
                    receipt: removalReceipt
                )
                DiagnosticsLogger.api.error("Failed to delete playlist: \(error.localizedDescription)")
                throw error
            }
        }
        self.pendingPlaylistDeletions[key] = PendingPlaylistDeletion(
            id: operationID,
            task: task
        )
        defer {
            if self.pendingPlaylistDeletions[key]?.id == operationID {
                self.pendingPlaylistDeletions.removeValue(forKey: key)
            }
        }
        try await task.value
    }

    /// Subscribes to a podcast show (adds to library).
    static func subscribeToPodcast(
        _ show: PodcastShow,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        let boundaryGeneration = self.accountBoundaryGeneration
        try await self.runTrackedAccountBoundaryMutation {
            do {
                try self.checkAccountBoundary(boundaryGeneration)
                try await client.subscribeToPodcast(showId: show.id)
                try self.checkAccountBoundary(boundaryGeneration)
                self.invalidateResponseCaches()
                libraryViewModel?.markNeedsReloadOnActivation()
                if let libraryViewModel {
                    libraryViewModel.addToLibrary(podcast: show)

                    // Library browse responses can lag briefly behind a successful subscribe.
                    try await Task.sleep(for: .milliseconds(500))
                    try self.checkAccountBoundary(boundaryGeneration)
                    await libraryViewModel.refresh()
                    try self.checkAccountBoundary(boundaryGeneration)
                    self.invalidateResponseCaches()

                    if !libraryViewModel.isInLibrary(podcastId: show.id) {
                        libraryViewModel.addToLibrary(podcast: show)
                        self.invalidateResponseCaches()
                    }
                }
                DiagnosticsLogger.api.info("Subscribed to podcast: \(show.title)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard self.isAccountBoundaryCurrent(boundaryGeneration) else { throw CancellationError() }
                throw error
            }
        }
    }

    /// Unsubscribes from a podcast show (removes from library).
    static func unsubscribeFromPodcast(
        _ show: PodcastShow,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        DiagnosticsLogger.api.debug("Attempting to unsubscribe from podcast: \(show.id), libraryViewModel is \(libraryViewModel == nil ? "nil" : "present")")
        let boundaryGeneration = self.accountBoundaryGeneration
        try await self.runTrackedAccountBoundaryMutation {
            do {
                try self.checkAccountBoundary(boundaryGeneration)
                try await client.unsubscribeFromPodcast(showId: show.id)
                try self.checkAccountBoundary(boundaryGeneration)
                self.invalidateResponseCaches()
                libraryViewModel?.markNeedsReloadOnActivation()
                if let libraryViewModel {
                    libraryViewModel.removeFromLibrary(podcastId: show.id)

                    // Library browse responses can lag briefly behind a successful removal.
                    try await Task.sleep(for: .milliseconds(500))
                    try self.checkAccountBoundary(boundaryGeneration)
                    await libraryViewModel.refresh()
                    try self.checkAccountBoundary(boundaryGeneration)
                    self.invalidateResponseCaches()

                    if libraryViewModel.isInLibrary(podcastId: show.id) {
                        libraryViewModel.removeFromLibrary(podcastId: show.id)
                        self.invalidateResponseCaches()
                    }
                }
                DiagnosticsLogger.api.info("Unsubscribed from podcast: \(show.title)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard self.isAccountBoundaryCurrent(boundaryGeneration) else { throw CancellationError() }
                throw error
            }
        }
    }

    /// Subscribes to an artist (adds to library).
    static func subscribeToArtist(
        _ artist: Artist,
        channelId: String,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        let boundaryGeneration = self.accountBoundaryGeneration
        let accountScopeGeneration = libraryViewModel?.currentAccountScopeGeneration
        try await self.runTrackedAccountBoundaryMutation {
            try self.checkAccountBoundary(boundaryGeneration)
            if let libraryViewModel {
                self.addArtistToLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                libraryViewModel.markNeedsReloadOnActivation()
            }

            var didMutateRemotely = false
            do {
                try await client.subscribeToArtist(channelId: channelId)
                didMutateRemotely = true
                try self.checkAccountBoundary(boundaryGeneration)
                Self.invalidateResponseCaches()
                if let libraryViewModel {
                    Self.scheduleArtistReconciliation(
                        artist,
                        channelId: channelId,
                        expectedInLibrary: true,
                        libraryViewModel: libraryViewModel,
                        boundaryGeneration: boundaryGeneration
                    )
                }
                DiagnosticsLogger.api.info("Subscribed to artist: \(artist.name)")
            } catch is CancellationError {
                if !didMutateRemotely,
                   let libraryViewModel,
                   libraryViewModel.currentAccountScopeGeneration == accountScopeGeneration
                {
                    Self.removeArtistFromLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                    libraryViewModel.markNeedsReloadOnActivation()
                }
                throw CancellationError()
            } catch {
                guard self.isAccountBoundaryCurrent(boundaryGeneration) else {
                    if !didMutateRemotely,
                       let libraryViewModel,
                       libraryViewModel.currentAccountScopeGeneration == accountScopeGeneration
                    {
                        Self.removeArtistFromLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                        libraryViewModel.markNeedsReloadOnActivation()
                    }
                    throw CancellationError()
                }
                if let libraryViewModel {
                    Self.removeArtistFromLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                    libraryViewModel.markNeedsReloadOnActivation()
                }
                DiagnosticsLogger.api.error("Failed to subscribe to artist: \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// Unsubscribes from an artist (removes from library).
    static func unsubscribeFromArtist(
        _ artist: Artist,
        channelId: String,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        let boundaryGeneration = self.accountBoundaryGeneration
        let accountScopeGeneration = libraryViewModel?.currentAccountScopeGeneration
        try await self.runTrackedAccountBoundaryMutation {
            try self.checkAccountBoundary(boundaryGeneration)
            if let libraryViewModel {
                self.removeArtistFromLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                libraryViewModel.markNeedsReloadOnActivation()
            }

            var didMutateRemotely = false
            do {
                try await client.unsubscribeFromArtist(channelId: channelId)
                didMutateRemotely = true
                try self.checkAccountBoundary(boundaryGeneration)
                Self.invalidateResponseCaches()
                if let libraryViewModel {
                    Self.scheduleArtistReconciliation(
                        artist,
                        channelId: channelId,
                        expectedInLibrary: false,
                        libraryViewModel: libraryViewModel,
                        boundaryGeneration: boundaryGeneration
                    )
                }
                DiagnosticsLogger.api.info("Unsubscribed from artist: \(artist.name)")
            } catch is CancellationError {
                if !didMutateRemotely,
                   let libraryViewModel,
                   libraryViewModel.currentAccountScopeGeneration == accountScopeGeneration
                {
                    Self.addArtistToLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                    libraryViewModel.markNeedsReloadOnActivation()
                }
                throw CancellationError()
            } catch {
                guard self.isAccountBoundaryCurrent(boundaryGeneration) else {
                    if !didMutateRemotely,
                       let libraryViewModel,
                       libraryViewModel.currentAccountScopeGeneration == accountScopeGeneration
                    {
                        Self.addArtistToLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                        libraryViewModel.markNeedsReloadOnActivation()
                    }
                    throw CancellationError()
                }
                if let libraryViewModel {
                    Self.addArtistToLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                    libraryViewModel.markNeedsReloadOnActivation()
                }
                DiagnosticsLogger.api.error("Failed to unsubscribe from artist: \(error.localizedDescription)")
                throw error
            }
        }
    }

    static func invalidateResponseCaches() {
        // Library mutations can leave stale data in both the app-level cache and URL loading cache.
        APICache.shared.invalidate(matching: "browse:")
        APICache.shared.invalidate(matching: "playlist/get_add_to_playlist:")
        URLCache.shared.removeAllCachedResponses()
    }

    private static func scheduleArtistReconciliation(
        _ artist: Artist,
        channelId: String,
        expectedInLibrary: Bool,
        libraryViewModel: LibraryViewModel,
        boundaryGeneration: UInt64
    ) {
        let normalizedArtistId = Artist.publicChannelId(for: channelId) ?? channelId
        if let previousID = Self.latestArtistReconciliationIDs[normalizedArtistId] {
            Self.artistReconciliationTasks[previousID]?.task.cancel()
        }
        let operationID = UUID().uuidString
        let task = Task { @MainActor in
            defer {
                Self.artistReconciliationTasks.removeValue(forKey: operationID)
                if Self.latestArtistReconciliationIDs[normalizedArtistId] == operationID {
                    Self.latestArtistReconciliationIDs.removeValue(forKey: normalizedArtistId)
                }
            }

            for delay in Self.artistReconciliationRetryDelays {
                guard Self.isAccountBoundaryCurrent(boundaryGeneration) else { return }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }

                guard Self.isAccountBoundaryCurrent(boundaryGeneration) else { return }

                Self.invalidateResponseCaches()
                await libraryViewModel.refresh()
                guard Self.isAccountBoundaryCurrent(boundaryGeneration) else { return }
                Self.invalidateResponseCaches()

                let needsReconciliation = libraryViewModel.needsArtistLibraryReconciliation(
                    artistIds: Self.artistLibraryAliases(for: artist, channelId: channelId),
                    expectedInLibrary: expectedInLibrary
                )
                let isInLibrary = Self.isArtistInLibrary(
                    artist,
                    channelId: channelId,
                    libraryViewModel: libraryViewModel
                )
                if !needsReconciliation, isInLibrary == expectedInLibrary {
                    DiagnosticsLogger.api.debug(
                        "Artist library reconciliation converged with backend state for \(artist.name, privacy: .public)"
                    )
                    return
                }

                DiagnosticsLogger.api.debug(
                    "Artist library reconciliation is still waiting on backend propagation for \(artist.name, privacy: .public)"
                )
                if isInLibrary != expectedInLibrary {
                    DiagnosticsLogger.api.debug(
                        "Artist library reconciliation is reapplying optimistic state for \(artist.name, privacy: .public)"
                    )
                }

                if expectedInLibrary {
                    Self.addArtistToLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                } else {
                    Self.removeArtistFromLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                }
                libraryViewModel.markNeedsReloadOnActivation()
            }
        }
        Self.artistReconciliationTasks[operationID] = PendingArtistReconciliation(task: task)
        Self.latestArtistReconciliationIDs[normalizedArtistId] = operationID
    }

    private static func addArtistToLibrary(
        _ artist: Artist,
        channelId: String,
        libraryViewModel: LibraryViewModel
    ) {
        let libraryArtistId = Self.preferredLibraryArtistId(for: artist, channelId: channelId)
        libraryViewModel.addToLibrary(artist: artist, libraryArtistId: libraryArtistId)
        for artistId in Self.artistLibraryAliases(for: artist, channelId: channelId) {
            libraryViewModel.addToLibrarySet(artistId: artistId)
        }
    }

    private static func removeArtistFromLibrary(
        _ artist: Artist,
        channelId: String,
        libraryViewModel: LibraryViewModel
    ) {
        for artistId in self.artistLibraryAliases(for: artist, channelId: channelId) {
            libraryViewModel.removeFromLibrary(artistId: artistId)
        }
    }

    private static func isArtistInLibrary(
        _ artist: Artist,
        channelId: String,
        libraryViewModel: LibraryViewModel
    ) -> Bool {
        self.artistLibraryAliases(for: artist, channelId: channelId)
            .contains(where: { libraryViewModel.isInLibrary(artistId: $0) })
    }

    private static func artistLibraryAliases(for artist: Artist, channelId: String) -> [String] {
        var ids = Set([channelId, artist.id])
        if let publicChannelId = artist.publicChannelId {
            ids.insert(publicChannelId)
        }
        return Array(ids)
    }

    private static func preferredLibraryArtistId(for artist: Artist, channelId: String) -> String {
        if artist.hasNavigableId {
            return artist.id
        }

        return channelId
    }
}
