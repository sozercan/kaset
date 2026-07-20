// swiftlint:disable file_length
import Foundation
import Observation
import os

// MARK: - PlaylistDetailViewModel

/// View model for the PlaylistDetailView.
@MainActor
@Observable
final class PlaylistDetailViewModel {
    private struct LiveSyncTask {
        let id: UUID
        let snapshot: LikedMusicRequestSnapshot?
        let task: Task<Void, Never>
    }

    private struct DeferredLikedMusicMetadata {
        let videoId: String
        let addsLikedMusicMembership: Bool
    }

    private struct ContinuationDrainBatch {
        let generation: Int
        let continuation: String
        let currentDetail: PlaylistDetail
        let likedMusicSnapshot: LikedMusicRequestSnapshot?
    }

    private struct ContinuationReconciliation {
        let tracks: [Song]
        let filteredVideoIDs: Set<String>
        let insertedVideoIDs: Set<String>
        let localOverlayVideoIDs: Set<String>
        let newLikedMembershipVideoIDs: Set<String>
        let deferredMetadata: [DeferredLikedMusicMetadata]
    }

    private struct InitialLoadContext {
        let generation: Int
        let likedMusicSnapshot: LikedMusicRequestSnapshot?
    }

    private struct InitialLoadResult {
        let detail: PlaylistDetail
        let hasMore: Bool
        let continuationToken: String?
        let deferredLikedMusicMetadata: [DeferredLikedMusicMetadata]
    }

    private struct LikedMusicDetailResult {
        let detail: PlaylistDetail
        let deferredMetadata: [DeferredLikedMusicMetadata]
    }

    struct PlaylistTrackRemovalSnapshot {
        let song: Song
        let index: Int
        let loadGeneration: Int
        let detailBeforeRemoval: PlaylistDetail
        let hadMoreTracks: Bool
        let continuationToken: String?
    }

    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// The loaded playlist detail.
    private(set) var playlistDetail: PlaylistDetail?

    /// Whether more tracks are available to load.
    private(set) var hasMore: Bool = false

    private let playlist: Playlist
    /// The API client (exposed for add to library action).
    let client: any YTMusicClientProtocol
    private let likeStatusManager: SongLikeStatusManager
    private let logger = DiagnosticsLogger.api
    private var continuationToken: String?

    @ObservationIgnored
    private var liveSyncTasks: [String: LiveSyncTask] = [:]

    @ObservationIgnored
    private var loadGeneration = 0

    @ObservationIgnored
    private var loadedTrackVideoIds: Set<String> = []

    @ObservationIgnored
    private var seenContinuationTokens: Set<String> = []

    @ObservationIgnored
    private var loadedLikedMusicScope: LikedMusicRequestSnapshot?

    @ObservationIgnored
    private var loadedLikedMusicAccountID: String?

    @ObservationIgnored
    private var countedFilteredLikedMusicVideoIDs: Set<String> = []

    /// Successful occurrence removals remain tombstoned for this view model's lifetime so
    /// stale refreshes and continuation responses cannot restore them.
    @ObservationIgnored
    private var confirmedRemovedPlaylistSetVideoIDs: Set<String> = []

    @ObservationIgnored
    private var countedPlaylistRemovalSetVideoIDs: Set<String> = []

    @ObservationIgnored
    private var pendingRemovedPlaylistSetVideoID: String?

    private(set) var isRemovingTrack = false

    private var isLikedMusicPlaylist: Bool {
        LikedMusicPlaylist.matches(id: self.playlist.id)
    }

    init(
        playlist: Playlist,
        client: any YTMusicClientProtocol,
        likeStatusManager: SongLikeStatusManager = .shared
    ) {
        self.playlist = playlist
        self.client = client
        self.likeStatusManager = likeStatusManager
    }

    var playlistID: String {
        self.playlist.id
    }

    deinit {
        self.loadTask?.cancel()
        self.fullLoadTask?.cancel()
        self.pagingTask?.cancel()
        for liveSyncTask in self.liveSyncTasks.values {
            liveSyncTask.task.cancel()
        }
        if let loadedLikedMusicScope {
            let likeStatusManager = self.likeStatusManager
            Task { @MainActor [likeStatusManager, loadedLikedMusicScope] in
                likeStatusManager.finishLikedMusicRequest(loadedLikedMusicScope)
            }
        }
    }

    /// Strips song count patterns from author text (e.g., " • 145 songs" or " • 2,429 tracks").
    /// Used to clean fallback author values that may contain redundant song counts.
    private func stripSongCountAuthor(from author: Artist?) -> Artist? {
        guard let author else { return nil }
        var result = author.name
        result = result.replacingOccurrences(
            of: #" • [\d,]+ (?:songs?|tracks?)"#,
            with: "",
            options: .regularExpression
        )
        if result.hasPrefix(" • ") {
            result = String(result.dropFirst(3))
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty
            ? nil
            : Artist(
                id: author.id,
                name: result,
                thumbnailURL: author.thumbnailURL,
                subtitle: author.subtitle,
                profileKind: author.profileKind
            )
    }

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var fullLoadTask: Task<Void, Never>?
    @ObservationIgnored private var pagingTask: Task<Bool, Never>?
    @ObservationIgnored private var trackRemovalWaiters: [CheckedContinuation<Void, Never>] = []

    /// Runs the initial load (including full-playlist paging) once, coalescing concurrent
    /// callers so a player can await the complete track set before finalizing the queue.
    func ensureLoaded() async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard self.loadingState == .idle else { return }
        let task = Task { await self.load() }
        self.loadTask = task
        await task.value
        self.loadTask = nil
    }

    /// Drives pagination to completion (every track), for callers that need the full playlist
    /// (e.g. building a play queue). Coalesces callers and retries no-progress rounds caused by
    /// transient continuation failures or concurrent batches. Runs in a stored unstructured task
    /// so it survives `.task` restarts — the same single-flight discipline as `ensureLoaded`.
    func loadAllRemaining() async {
        await self.ensureLoaded()
        if let fullLoadTask {
            await fullLoadTask.value
            return
        }
        let generation = self.loadGeneration
        let task = Task { @MainActor in
            var consecutiveStalls = 0
            while self.isCurrentLoadGeneration(generation), self.hasMore, consecutiveStalls < 8 {
                let before = self.playlistDetail?.tracks.count ?? 0
                _ = await self.loadMoreBatch(generation: generation)
                if (self.playlistDetail?.tracks.count ?? 0) > before {
                    consecutiveStalls = 0
                } else {
                    consecutiveStalls += 1
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        self.fullLoadTask = task
        await task.value
        if self.isCurrentLoadGeneration(generation) {
            self.fullLoadTask = nil
        }
    }
}

extension PlaylistDetailViewModel {
    /// Loads the playlist details including tracks.
    func load() async {
        await self.load(restartingInFlightLoad: false)
    }

    private func load(restartingInFlightLoad: Bool) async {
        guard restartingInFlightLoad || (self.loadingState != .loading && self.loadingState != .loadingMore) else { return }

        let context = self.beginInitialLoad()
        defer {
            self.finishInitialLoad(context)
        }

        do {
            guard let result = try await self.fetchInitialLoadResult(context) else { return }
            self.applyInitialLoadResult(result, context: context)
        } catch is CancellationError {
            self.handleInitialLoadCancellation(context)
        } catch {
            self.handleInitialLoadError(error, context: context)
        }
    }

    private func beginInitialLoad() -> InitialLoadContext {
        self.cancelFullLoadTask()
        self.loadGeneration += 1
        let previousLikedMusicScope = self.loadedLikedMusicScope
        let likedMusicSnapshot = self.isLikedMusicPlaylist
            ? self.likeStatusManager.beginLikedMusicRequest()
            : nil
        if let previousLikedMusicScope {
            self.likeStatusManager.finishLikedMusicRequest(previousLikedMusicScope)
            self.loadedLikedMusicScope = nil
        }
        self.countedPlaylistRemovalSetVideoIDs = []
        self.countedFilteredLikedMusicVideoIDs = []
        self.seenContinuationTokens = []
        self.loadingState = .loading
        self.continuationToken = nil
        self.logger.info("Loading playlist: \(self.playlist.title), ID: \(self.playlist.id)")
        return InitialLoadContext(
            generation: self.loadGeneration,
            likedMusicSnapshot: likedMusicSnapshot
        )
    }

    private func finishInitialLoad(_ context: InitialLoadContext) {
        guard let snapshot = context.likedMusicSnapshot else { return }
        guard self.loadedLikedMusicScope != snapshot else { return }
        self.likeStatusManager.finishLikedMusicRequest(snapshot)
    }

    private func fetchInitialLoadResult(_ context: InitialLoadContext) async throws -> InitialLoadResult? {
        let response = try await self.client.getPlaylist(id: self.playlist.id)
        guard self.canApplyInitialLoad(context) else { return nil }

        var detail = response.detail
        var hasMore = response.hasMore
        var continuationToken = response.continuationToken
        var deferredLikedMusicMetadata: [DeferredLikedMusicMetadata] = []

        if let allTracks = try await self.fetchRadioPlaylistTracksIfNeeded() {
            guard self.canApplyInitialLoad(context) else { return nil }
            if allTracks.count > detail.tracks.count {
                detail = self.detailByReplacingRadioTracks(in: detail, with: allTracks)
                hasMore = false
                continuationToken = nil
            }
        }

        detail = self.detailByMergingOriginalPlaylistMetadata(into: detail)
        if let snapshot = context.likedMusicSnapshot {
            guard let reconciliation = self.reconciledLikedMusicDetail(detail, snapshot: snapshot) else {
                self.loadingState = .idle
                return nil
            }
            detail = reconciliation.detail
            deferredLikedMusicMetadata = reconciliation.deferredMetadata
        }

        return InitialLoadResult(
            detail: self.filterPlaylistRemovals(from: detail),
            hasMore: hasMore,
            continuationToken: continuationToken,
            deferredLikedMusicMetadata: deferredLikedMusicMetadata
        )
    }

    private func fetchRadioPlaylistTracksIfNeeded() async throws -> [Song]? {
        let playlistID = self.playlist.id
        let isRadioPlaylist = playlistID.contains("RDCLAK") || playlistID.hasPrefix("RD")
        self.logger.debug("Playlist ID: \(playlistID), isRadioPlaylist: \(isRadioPlaylist)")
        guard isRadioPlaylist else { return nil }

        self.logger.info("Radio playlist detected, fetching all tracks via queue API")
        do {
            return try await self.client.getPlaylistAllTracks(playlistId: playlistID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.logger.warning("Queue API failed, using browse results: \(error.localizedDescription)")
            return nil
        }
    }

    private func detailByReplacingRadioTracks(in detail: PlaylistDetail, with allTracks: [Song]) -> PlaylistDetail {
        self.logger.info("Queue API returned \(allTracks.count) tracks (vs \(detail.tracks.count) from browse)")
        let playlist = Playlist(
            id: detail.id,
            title: detail.title,
            description: detail.description,
            thumbnailURL: detail.thumbnailURL,
            trackCount: allTracks.count,
            author: detail.author,
            canDelete: detail.canDelete || self.playlist.canDelete
        )
        return PlaylistDetail(playlist: playlist, tracks: allTracks, duration: detail.duration)
    }

    private func detailByMergingOriginalPlaylistMetadata(into detail: PlaylistDetail) -> PlaylistDetail {
        let resolvedThumbnailURL = detail.thumbnailURL
            ?? self.playlist.thumbnailURL
            ?? detail.tracks.first?.thumbnailURL
        let needsMerge = detail.title == "Unknown Playlist" && self.playlist.title != "Unknown Playlist"
        let thumbnailMissing = detail.thumbnailURL == nil && resolvedThumbnailURL != nil
        guard needsMerge || thumbnailMissing else { return detail }

        let mergedTrackCount = max(
            detail.tracks.count,
            max(detail.trackCount ?? 0, self.playlist.trackCount ?? 0)
        )
        let playlist = Playlist(
            id: self.playlist.id,
            title: needsMerge ? self.playlist.title : detail.title,
            description: detail.description ?? self.playlist.description,
            thumbnailURL: resolvedThumbnailURL,
            trackCount: mergedTrackCount,
            author: detail.author ?? self.stripSongCountAuthor(from: self.playlist.author),
            canDelete: detail.canDelete || self.playlist.canDelete
        )
        return PlaylistDetail(playlist: playlist, tracks: detail.tracks, duration: detail.duration)
    }

    private func reconciledLikedMusicDetail(
        _ detail: PlaylistDetail,
        snapshot: LikedMusicRequestSnapshot
    ) -> LikedMusicDetailResult? {
        guard let reconciliation = self.likeStatusManager.reconcileLikedMusicTracks(
            detail.tracks,
            snapshot: snapshot,
            deduplicating: true
        ) else { return nil }

        let deferredMetadata: [DeferredLikedMusicMetadata] = reconciliation.tracks.compactMap { song in
            guard reconciliation.insertedVideoIDs.contains(song.videoId),
                  Self.requiresMetadataFetchForLiveSync(song)
            else { return nil }
            return DeferredLikedMusicMetadata(
                videoId: song.videoId,
                addsLikedMusicMembership: reconciliation.newLikedMembershipVideoIDs.contains(song.videoId)
            )
        }
        let deferredMetadataVideoIDSet = Set(deferredMetadata.map(\.videoId))
        let visibleTracks = reconciliation.tracks.filter {
            !deferredMetadataVideoIDSet.contains($0.videoId)
        }
        let insertedTrackCount = reconciliation.insertedVideoIDs
            .intersection(reconciliation.newLikedMembershipVideoIDs)
            .subtracting(deferredMetadataVideoIDSet)
            .count
        self.countedFilteredLikedMusicVideoIDs.formUnion(reconciliation.filteredVideoIDs)
        let adjustedTrackCount = self.adjustedTrackCount(
            detail.trackCount,
            skippedRemovalCount: reconciliation.filteredVideoIDs.count,
            insertedTrackCount: insertedTrackCount
        )
        return LikedMusicDetailResult(
            detail: self.updatedPlaylistDetail(
                from: detail,
                tracks: visibleTracks,
                trackCount: max(adjustedTrackCount ?? 0, visibleTracks.count)
            ),
            deferredMetadata: deferredMetadata
        )
    }

    private func applyInitialLoadResult(_ result: InitialLoadResult, context: InitialLoadContext) {
        guard self.canApplyInitialLoad(context) else { return }
        self.playlistDetail = result.detail
        self.loadedLikedMusicAccountID = context.likedMusicSnapshot?.accountID
        self.loadedLikedMusicScope = result.hasMore ? context.likedMusicSnapshot : nil
        self.hasMore = result.hasMore
        self.continuationToken = result.hasMore ? result.continuationToken : nil
        self.loadingState = .loaded
        let loadedTrackCount = result.detail.tracks.count
        let totalTrackCount = result.detail.trackCount ?? loadedTrackCount
        self.logger.info("Playlist loaded: \(loadedTrackCount) loaded tracks, total: \(totalTrackCount), hasMore: \(result.hasMore)")
        self.replaceLoadedTrackVideoIds(with: result.detail.tracks)
        self.startDeferredLikedMusicMetadataTasks(result.deferredLikedMusicMetadata)
    }

    private func handleInitialLoadCancellation(_ context: InitialLoadContext) {
        guard self.canApplyInitialLoad(context) else { return }
        self.logger.debug("Playlist detail load cancelled")
        self.loadingState = .idle
    }

    private func handleInitialLoadError(_ error: any Error, context: InitialLoadContext) {
        guard self.canApplyInitialLoad(context) else { return }
        self.logger.error("Failed to load playlist: \(error.localizedDescription)")
        self.loadingState = .error(LoadingError(from: error))
    }

    private func canApplyInitialLoad(_ context: InitialLoadContext) -> Bool {
        guard self.isCurrentLoadGeneration(context.generation) else { return false }
        guard self.isCurrentLikedMusicScope(context.likedMusicSnapshot) else {
            self.loadingState = .idle
            return false
        }
        return true
    }

    /// Loads more tracks via continuation.
    func loadMore() async {
        guard self.loadingState == .loaded,
              self.hasMore,
              self.continuationToken != nil,
              self.playlistDetail != nil
        else { return }

        let generation = self.loadGeneration
        await withTaskCancellationHandler {
            _ = await self.loadMoreBatch(generation: generation)
        } onCancel: {
            Task { @MainActor in
                if self.isCurrentLoadGeneration(generation), self.loadingState == .loadingMore {
                    self.loadGeneration += 1
                    self.loadingState = .loaded
                }
            }
        }
    }

    private func applyRemainingTracksResponse(
        _ response: PlaylistContinuationResponse,
        batch: ContinuationDrainBatch
    ) -> Bool {
        guard batch.generation == self.loadGeneration,
              !Task.isCancelled,
              self.isCurrentLikedMusicScope(batch.likedMusicSnapshot),
              let latestDetail = self.playlistDetail
        else { return false }
        self.seenContinuationTokens.insert(batch.continuation)

        let skippedConfirmedPlaylistRemovalCount = response.tracks.reduce(into: 0) { count, track in
            guard let setVideoId = track.playlistSetVideoId,
                  self.isPlaylistRemovalTombstoned(setVideoId: setVideoId),
                  self.countedPlaylistRemovalSetVideoIDs.insert(setVideoId).inserted
            else { return }
            count += 1
        }
        let playlistFilteredTracks = response.tracks.filter { track in
            guard let setVideoId = track.playlistSetVideoId else { return true }
            return !self.isPlaylistRemovalTombstoned(setVideoId: setVideoId)
        }

        guard let reconciliation = self.reconcileContinuationTracks(
            playlistFilteredTracks,
            snapshot: batch.likedMusicSnapshot
        ) else { return false }
        let skippedLikedMusicCount = reconciliation.filteredVideoIDs.reduce(into: 0) { count, videoId in
            if self.countedFilteredLikedMusicVideoIDs.insert(videoId).inserted {
                count += 1
            }
        }

        let originalExistingVideoIds = Set(batch.currentDetail.tracks.map(\.videoId))
        let newTracks = reconciliation.tracks.filter {
            !self.loadedTrackVideoIds.contains($0.videoId)
                && !originalExistingVideoIds.contains($0.videoId)
        }
        let skippedRemovalCount = skippedConfirmedPlaylistRemovalCount + skippedLikedMusicCount
        let insertedTrackCount = newTracks.count {
            reconciliation.newLikedMembershipVideoIDs.contains($0.videoId)
                || self.countedFilteredLikedMusicVideoIDs.contains($0.videoId)
        }
        let continuationDidNotAdvance = response.continuationToken == nil
            || response.continuationToken == batch.continuation

        if newTracks.isEmpty {
            self.applySkippedRemovalCount(skippedRemovalCount, to: latestDetail)
            self.startDeferredLikedMusicMetadataTasks(reconciliation.deferredMetadata)
            if response.hasMore,
               continuationDidNotAdvance
            {
                self.continuationToken = nil
                self.hasMore = false
                self.loadingState = .loaded
                self.releaseLoadedLikedMusicScope()
                self.logger.warning("Stopping playlist pagination after a non-advancing duplicate page")
                return false
            }
            self.continuationToken = response.continuationToken
            self.hasMore = response.hasMore
            self.loadingState = .loaded
            if !self.hasMore {
                self.releaseLoadedLikedMusicScope()
            }
            return self.hasMore
        }

        var allTracks = latestDetail.tracks
        allTracks.reserveCapacity(latestDetail.tracks.count + newTracks.count)
        allTracks.append(contentsOf: newTracks)
        let adjustedTrackCount = self.adjustedTrackCount(
            latestDetail.trackCount,
            skippedRemovalCount: skippedRemovalCount,
            insertedTrackCount: insertedTrackCount
        )
        let preservedTrackCount = max(allTracks.count, adjustedTrackCount ?? 0)
        self.playlistDetail = self.updatedPlaylistDetail(
            from: latestDetail,
            tracks: allTracks,
            trackCount: preservedTrackCount
        )
        self.insertLoadedTrackVideoIds(from: newTracks)
        for track in newTracks {
            self.countedFilteredLikedMusicVideoIDs.remove(track.videoId)
        }
        self.startDeferredLikedMusicMetadataTasks(reconciliation.deferredMetadata)
        self.continuationToken = response.continuationToken
        self.hasMore = response.hasMore
        self.loadingState = .loaded
        if !self.hasMore {
            self.releaseLoadedLikedMusicScope()
        }
        self.logger.info("Loaded \(newTracks.count) new tracks (from \(response.tracks.count)), loaded total: \(allTracks.count), reported total: \(preservedTrackCount), hasMore: \(self.hasMore)")
        return self.hasMore
    }

    private func reconcileContinuationTracks(
        _ tracks: [Song],
        snapshot: LikedMusicRequestSnapshot?
    ) -> ContinuationReconciliation? {
        guard let snapshot else {
            return ContinuationReconciliation(
                tracks: tracks,
                filteredVideoIDs: [],
                insertedVideoIDs: [],
                localOverlayVideoIDs: [],
                newLikedMembershipVideoIDs: [],
                deferredMetadata: []
            )
        }
        guard let reconciliation = self.likeStatusManager.reconcileLikedMusicTracks(
            tracks,
            snapshot: snapshot
        ) else { return nil }

        let deferredMetadata: [DeferredLikedMusicMetadata] = reconciliation.tracks.compactMap { song in
            guard reconciliation.insertedVideoIDs.contains(song.videoId),
                  Self.requiresMetadataFetchForLiveSync(song)
            else { return nil }
            return DeferredLikedMusicMetadata(
                videoId: song.videoId,
                addsLikedMusicMembership: reconciliation.newLikedMembershipVideoIDs.contains(song.videoId)
            )
        }
        let deferredMetadataVideoIDSet = Set(deferredMetadata.map(\.videoId))
        return ContinuationReconciliation(
            tracks: reconciliation.tracks.filter {
                !deferredMetadataVideoIDSet.contains($0.videoId)
            },
            filteredVideoIDs: reconciliation.filteredVideoIDs,
            insertedVideoIDs: reconciliation.insertedVideoIDs.subtracting(deferredMetadataVideoIDSet),
            localOverlayVideoIDs: reconciliation.localOverlayVideoIDs,
            newLikedMembershipVideoIDs: reconciliation.newLikedMembershipVideoIDs.subtracting(
                deferredMetadataVideoIDSet
            ),
            deferredMetadata: deferredMetadata
        )
    }

    private func startDeferredLikedMusicMetadataTasks(_ metadata: [DeferredLikedMusicMetadata]) {
        for item in metadata {
            if let snapshot = self.liveSyncTasks[item.videoId]?.snapshot,
               self.likeStatusManager.matchesCurrentScope(snapshot)
            {
                continue
            }
            self.startLiveSyncTask(
                for: item.videoId,
                addsLikedMusicMembership: item.addsLikedMusicMembership
            )
        }
    }

    private func adjustedTrackCount(
        _ trackCount: Int?,
        skippedRemovalCount: Int,
        insertedTrackCount: Int = 0
    ) -> Int? {
        guard let trackCount else { return nil }
        return max(0, trackCount - skippedRemovalCount + insertedTrackCount)
    }

    private func applySkippedRemovalCount(_ skippedRemovalCount: Int, to detail: PlaylistDetail) {
        guard let adjustedTrackCount = self.adjustedTrackCount(detail.trackCount, skippedRemovalCount: skippedRemovalCount),
              adjustedTrackCount != detail.trackCount
        else { return }

        self.playlistDetail = self.updatedPlaylistDetail(
            from: detail,
            tracks: detail.tracks,
            trackCount: max(detail.tracks.count, adjustedTrackCount)
        )
    }

    /// Single-flight wrapper around one continuation fetch. Concurrent callers — the initial
    /// full-playlist load, the scroll-triggered `loadMore()`, `loadAllRemaining`, and repeated play
    /// triggers — coalesce onto the in-flight batch and receive its real result, instead of colliding
    /// on `loadingState` (the loser would otherwise return a spurious `false` that resilient loops
    /// mis-read as "no progress" and give up on, leaving the queue stuck at a partial count).
    private func loadMoreBatch(generation: Int? = nil) async -> Bool {
        if let pagingTask {
            return await pagingTask.value
        }
        let task = Task { @MainActor in await self.performLoadMoreBatch(generation: generation) }
        self.pagingTask = task
        let result = await task.value
        self.pagingTask = nil
        return result
    }

    private func performLoadMoreBatch(generation: Int? = nil) async -> Bool {
        guard self.loadingState == .loaded,
              self.hasMore,
              let continuationToken,
              let currentDetail = self.playlistDetail,
              self.isCurrentLoadGeneration(generation)
        else { return false }

        guard self.isCurrentLikedMusicScope(self.loadedLikedMusicScope) else {
            self.invalidateLikedMusicPagination(generation: generation)
            return false
        }
        guard !self.seenContinuationTokens.contains(continuationToken) else {
            self.hasMore = false
            self.continuationToken = nil
            self.releaseLoadedLikedMusicScope()
            self.logger.warning("Stopping playlist pagination after a repeated continuation cursor")
            return false
        }
        let requestSnapshot = self.loadedLikedMusicScope

        self.loadingState = .loadingMore
        self.logger.info("Loading more playlist tracks")

        do {
            let continuation = continuationToken
            let response = try await client.getPlaylistContinuation(
                token: continuation,
                requiresAuth: currentDetail.requiresPersonalAccountForContinuations
            )
            guard self.isCurrentLoadGeneration(generation) else { return false }
            guard self.isCurrentLikedMusicScope(requestSnapshot) else {
                self.invalidateLikedMusicPagination(generation: generation)
                return false
            }
            let batch = ContinuationDrainBatch(
                generation: generation ?? self.loadGeneration,
                continuation: continuation,
                currentDetail: currentDetail,
                likedMusicSnapshot: requestSnapshot
            )
            return self.applyRemainingTracksResponse(response, batch: batch)
        } catch is CancellationError {
            guard self.isCurrentLoadGeneration(generation) else { return false }
            guard self.isCurrentLikedMusicScope(requestSnapshot) else {
                self.invalidateLikedMusicPagination(generation: generation)
                return false
            }
            self.logger.debug("Playlist continuation cancelled")
            self.loadingState = .loaded
            return false
        } catch {
            guard self.isCurrentLoadGeneration(generation) else { return false }
            guard self.isCurrentLikedMusicScope(requestSnapshot) else {
                self.invalidateLikedMusicPagination(generation: generation)
                return false
            }
            self.logger.error("Failed to load more playlist tracks: \(error.localizedDescription)")
            // Keep loaded state so user can retry
            self.loadingState = .loaded
            return false
        }
    }

    /// Handles like status updates for the Liked Music playlist.
    /// Handles immediate optimistic updates for the loaded Liked Music UI.
    /// Delayed API response correctness is owned by `SongLikeStatusManager` snapshots.
    func handleLikeStatusChange(_ event: LikeStatusEvent) {
        guard self.isLikedMusicPlaylist else { return }
        guard self.loadingState == .loaded || self.loadingState == .loadingMore else { return }
        guard self.isLoadedLikedMusicAccountCurrent() else { return }

        switch event.status {
        case .like:
            if let song = event.song, !Self.requiresMetadataFetchForLiveSync(song) {
                self.cancelLiveSyncTask(for: event.videoId)
                self.insertLiveSyncedLikedSong(
                    song,
                    addsLikedMusicMembership: event.addsLikedMusicMembership ?? true
                )
            } else {
                guard !self.containsTrack(videoId: event.videoId) else { return }
                self.startLiveSyncTask(
                    for: event.videoId,
                    addsLikedMusicMembership: event.addsLikedMusicMembership ?? true
                )
            }
        case .indifferent, .dislike:
            if self.containsTrack(videoId: event.videoId) {
                self.countedFilteredLikedMusicVideoIDs.insert(event.videoId)
            }
            self.cancelLiveSyncTask(for: event.videoId)
            self.removeLiveSyncedLikedSong(videoId: event.videoId)
        }
    }

    /// Refreshes the playlist.
    @discardableResult
    func refresh() async -> Bool {
        guard !self.isRemovingTrack else { return false }
        return await self.performRefresh()
    }

    private func performRefresh() async -> Bool {
        self.cancelAllLiveSyncTasks()
        self.replacePlaylistDetail(nil)
        self.hasMore = false
        self.continuationToken = nil
        await self.load(restartingInFlightLoad: true)
        return self.loadingState == .loaded && self.playlistDetail != nil
    }

    func beginOptimisticTrackRemoval(setVideoId: String) -> PlaylistTrackRemovalSnapshot? {
        guard !self.isRemovingTrack,
              !self.confirmedRemovedPlaylistSetVideoIDs.contains(setVideoId),
              let detail = self.playlistDetail,
              let index = detail.tracks.firstIndex(where: { $0.playlistSetVideoId == setVideoId })
        else { return nil }

        self.isRemovingTrack = true
        self.pendingRemovedPlaylistSetVideoID = setVideoId
        self.countedPlaylistRemovalSetVideoIDs.insert(setVideoId)

        var tracks = detail.tracks
        let removedSong = tracks.remove(at: index)
        self.replacePlaylistDetail(self.updatedPlaylistDetail(
            from: detail,
            tracks: tracks,
            trackCount: detail.trackCount.map { max(0, $0 - 1) }
        ))

        return PlaylistTrackRemovalSnapshot(
            song: removedSong,
            index: index,
            loadGeneration: self.loadGeneration,
            detailBeforeRemoval: detail,
            hadMoreTracks: self.hasMore,
            continuationToken: self.continuationToken
        )
    }

    func confirmTrackRemoval(_ removal: PlaylistTrackRemovalSnapshot) {
        guard let setVideoId = removal.song.playlistSetVideoId,
              self.pendingRemovedPlaylistSetVideoID == setVideoId
        else { return }

        self.confirmedRemovedPlaylistSetVideoIDs.insert(setVideoId)
        self.finishTrackRemoval()
    }

    func rollbackTrackRemoval(_ removal: PlaylistTrackRemovalSnapshot) async {
        guard let setVideoId = removal.song.playlistSetVideoId,
              self.pendingRemovedPlaylistSetVideoID == setVideoId
        else { return }

        self.countedPlaylistRemovalSetVideoIDs.remove(setVideoId)
        self.pendingRemovedPlaylistSetVideoID = nil
        defer { self.finishTrackRemoval() }

        if removal.loadGeneration == self.loadGeneration, let detail = self.playlistDetail {
            guard !detail.tracks.contains(where: { $0.playlistSetVideoId == setVideoId }) else { return }
            var tracks = detail.tracks
            tracks.insert(removal.song, at: min(removal.index, tracks.count))
            self.replacePlaylistDetail(self.updatedPlaylistDetail(
                from: detail,
                tracks: tracks,
                trackCount: detail.trackCount.map { $0 + 1 }
            ))
            return
        }

        let restoredDetail = self.filterPlaylistRemovals(from: removal.detailBeforeRemoval)
        self.replacePlaylistDetail(restoredDetail)
        self.hasMore = removal.hadMoreTracks
        self.continuationToken = removal.continuationToken
        self.loadingState = .loaded
    }

    func waitForTrackRemovalToFinish() async {
        guard self.isRemovingTrack else { return }
        await withCheckedContinuation { continuation in
            self.trackRemovalWaiters.append(continuation)
        }
    }

    private func isCurrentLikedMusicScope(_ snapshot: LikedMusicRequestSnapshot?) -> Bool {
        guard let snapshot else { return true }
        return self.likeStatusManager.matchesCurrentScope(snapshot)
    }

    private func isLoadedLikedMusicAccountCurrent() -> Bool {
        guard let loadedLikedMusicAccountID else { return true }
        return loadedLikedMusicAccountID == self.likeStatusManager.activeAccountID
    }

    private func invalidateLikedMusicPagination(generation: Int?) {
        guard self.isCurrentLoadGeneration(generation) else { return }
        self.loadGeneration += 1
        self.fullLoadTask = nil
        self.hasMore = false
        self.continuationToken = nil
        self.replacePlaylistDetail(nil)
        self.loadingState = .idle
    }

    private func cancelFullLoadTask() {
        self.fullLoadTask?.cancel()
        self.fullLoadTask = nil
    }

    private func isCurrentLoadGeneration(_ generation: Int?) -> Bool {
        guard let generation else { return true }
        return generation == self.loadGeneration
    }

    private func filterPlaylistRemovals(from detail: PlaylistDetail) -> PlaylistDetail {
        var countedSetVideoIDs: Set<String> = []
        let filteredTracks = detail.tracks.filter { track in
            guard let setVideoId = track.playlistSetVideoId,
                  self.isPlaylistRemovalTombstoned(setVideoId: setVideoId)
            else { return true }
            countedSetVideoIDs.insert(setVideoId)
            return false
        }
        let removedTrackCount = detail.tracks.count - filteredTracks.count
        self.countedPlaylistRemovalSetVideoIDs.formUnion(countedSetVideoIDs)
        guard removedTrackCount > 0 else { return detail }

        return self.updatedPlaylistDetail(
            from: detail,
            tracks: filteredTracks,
            trackCount: detail.trackCount.map { max(filteredTracks.count, $0 - removedTrackCount) }
        )
    }

    private func isPlaylistRemovalTombstoned(setVideoId: String) -> Bool {
        self.confirmedRemovedPlaylistSetVideoIDs.contains(setVideoId)
            || self.pendingRemovedPlaylistSetVideoID == setVideoId
    }

    private func finishTrackRemoval() {
        self.pendingRemovedPlaylistSetVideoID = nil
        self.isRemovingTrack = false
        let waiters = self.trackRemovalWaiters
        self.trackRemovalWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func updatedPlaylistDetail(from detail: PlaylistDetail, tracks: [Song], trackCount: Int?) -> PlaylistDetail {
        let updatedPlaylist = Playlist(
            id: detail.id,
            title: detail.title,
            description: detail.description,
            thumbnailURL: detail.thumbnailURL,
            trackCount: trackCount,
            author: detail.author,
            canDelete: detail.canDelete
        )

        return PlaylistDetail(
            playlist: updatedPlaylist,
            tracks: tracks,
            duration: detail.duration
        )
    }

    private func containsTrack(videoId: String) -> Bool {
        self.loadedTrackVideoIds.contains(videoId)
    }

    private func replacePlaylistDetail(_ detail: PlaylistDetail?) {
        self.playlistDetail = detail
        if detail == nil {
            self.releaseLoadedLikedMusicScope()
            self.loadedLikedMusicAccountID = nil
        }
        self.replaceLoadedTrackVideoIds(with: detail?.tracks ?? [])
    }

    private func releaseLoadedLikedMusicScope() {
        guard let loadedLikedMusicScope else { return }
        self.likeStatusManager.finishLikedMusicRequest(loadedLikedMusicScope)
        self.loadedLikedMusicScope = nil
    }

    private func replaceLoadedTrackVideoIds(with tracks: [Song]) {
        self.loadedTrackVideoIds = Set(tracks.map(\.videoId))
    }

    private func insertLoadedTrackVideoIds(from tracks: [Song]) {
        self.loadedTrackVideoIds.reserveCapacity(self.loadedTrackVideoIds.count + tracks.count)
        for track in tracks {
            self.loadedTrackVideoIds.insert(track.videoId)
        }
    }

    private func insertLiveSyncedLikedSong(
        _ song: Song,
        addsLikedMusicMembership: Bool
    ) {
        guard let currentDetail = self.playlistDetail else { return }
        guard !self.loadedTrackVideoIds.contains(song.videoId) else { return }

        var likedSong = song
        likedSong.likeStatus = .like
        let updatedTracks = [likedSong] + currentDetail.tracks
        let currentTotal = currentDetail.trackCount ?? currentDetail.tracks.count
        let restoresRemovedMembership = self.countedFilteredLikedMusicVideoIDs.contains(song.videoId)
        let adjustedTotal = currentTotal + (addsLikedMusicMembership || restoresRemovedMembership ? 1 : 0)
        let updatedTrackCount = max(adjustedTotal, updatedTracks.count)

        self.playlistDetail = self.updatedPlaylistDetail(
            from: currentDetail,
            tracks: updatedTracks,
            trackCount: updatedTrackCount
        )
        self.loadedTrackVideoIds.insert(song.videoId)
        self.countedFilteredLikedMusicVideoIDs.remove(song.videoId)
        self.logger.info("Live sync: added song \(song.videoId) to liked music")
    }

    private func removeLiveSyncedLikedSong(videoId: String) {
        guard let currentDetail = self.playlistDetail else { return }

        let updatedTracks = currentDetail.tracks.filter { $0.videoId != videoId }
        guard updatedTracks.count != currentDetail.tracks.count else { return }

        let currentTotal = currentDetail.trackCount ?? currentDetail.tracks.count
        let updatedTrackCount = max(currentTotal - 1, updatedTracks.count)

        self.playlistDetail = self.updatedPlaylistDetail(
            from: currentDetail,
            tracks: updatedTracks,
            trackCount: updatedTrackCount
        )
        self.loadedTrackVideoIds.remove(videoId)
        self.logger.info("Live sync: removed song \(videoId) from liked music")
    }

    private func startLiveSyncTask(
        for videoId: String,
        addsLikedMusicMembership: Bool
    ) {
        let taskID = UUID()
        let snapshot = self.isLikedMusicPlaylist
            ? self.likeStatusManager.beginLikedMusicRequest()
            : nil
        let likeStatusManager = self.likeStatusManager
        self.cancelLiveSyncTask(for: videoId)

        let task = Task { @MainActor [weak self, likeStatusManager] in
            defer {
                if let snapshot {
                    likeStatusManager.finishLikedMusicRequest(snapshot)
                }
            }
            guard let self else { return }
            await self.fetchAndInsertLiveSyncedLikedSong(
                videoId: videoId,
                taskID: taskID,
                snapshot: snapshot,
                addsLikedMusicMembership: addsLikedMusicMembership
            )
        }
        self.liveSyncTasks[videoId] = LiveSyncTask(id: taskID, snapshot: snapshot, task: task)
    }

    private func fetchAndInsertLiveSyncedLikedSong(
        videoId: String,
        taskID: UUID,
        snapshot: LikedMusicRequestSnapshot?,
        addsLikedMusicMembership: Bool
    ) async {
        defer {
            if self.liveSyncTasks[videoId]?.id == taskID {
                self.liveSyncTasks.removeValue(forKey: videoId)
            }
        }

        guard self.liveSyncTasks[videoId]?.id == taskID else { return }
        guard !Task.isCancelled else { return }
        guard self.isCurrentLikedMusicScope(snapshot) else { return }
        guard !self.containsTrack(videoId: videoId) else { return }

        do {
            let song = try await self.client.getSong(videoId: videoId)

            guard !Task.isCancelled else { return }
            guard self.liveSyncTasks[videoId]?.id == taskID else { return }
            guard self.isCurrentLikedMusicScope(snapshot) else { return }
            guard self.likeStatusManager.status(for: videoId) == .like else { return }
            guard !Self.requiresMetadataFetchForLiveSync(song) else {
                self.logger.warning("Live sync: skipping incomplete metadata for liked song \(videoId)")
                return
            }

            self.insertLiveSyncedLikedSong(
                song,
                addsLikedMusicMembership: addsLikedMusicMembership
            )
        } catch is CancellationError {
            return
        } catch {
            self.logger.warning("Live sync: failed to fetch metadata for liked song \(videoId): \(error.localizedDescription)")
        }
    }

    private func cancelLiveSyncTask(for videoId: String) {
        self.liveSyncTasks.removeValue(forKey: videoId)?.task.cancel()
    }

    private func cancelAllLiveSyncTasks() {
        let tasks = self.liveSyncTasks.values.map(\.task)
        self.liveSyncTasks.removeAll()
        tasks.forEach { $0.cancel() }
    }

    private static func requiresMetadataFetchForLiveSync(_ song: Song) -> Bool {
        song.title.isEmpty ||
            song.title == "Loading..." ||
            song.artists.isEmpty ||
            song.artists.allSatisfy { $0.name.isEmpty || $0.name == "Unknown Artist" }
    }
}
