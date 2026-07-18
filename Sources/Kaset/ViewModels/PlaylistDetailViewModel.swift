import Foundation
import Observation
import os

/// View model for the PlaylistDetailView.
@MainActor
@Observable
final class PlaylistDetailViewModel {
    private struct LiveSyncTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct ContinuationDrainBatch {
        let generation: Int
        let continuation: String
        let currentDetail: PlaylistDetail
        let isLikedMusicPlaylist: Bool
        let requiresAuth: Bool
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
    private let logger = DiagnosticsLogger.api
    private var continuationToken: String?

    @ObservationIgnored
    private var liveSyncTasks: [String: LiveSyncTask] = [:]

    @ObservationIgnored
    private var loadGeneration = 0

    @ObservationIgnored
    private var loadedTrackVideoIds: Set<String> = []

    private var removedLikedMusicVideoIDs: Set<String> = []
    private var countedRemovedLikedMusicVideoIDs: Set<String> = []
    private var insertedLikedMusicVideoIDs: Set<String> = []

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

    init(playlist: Playlist, client: any YTMusicClientProtocol) {
        self.playlist = playlist
        self.client = client
    }

    var playlistID: String {
        self.playlist.id
    }

    deinit {
        for liveSyncTask in self.liveSyncTasks.values {
            liveSyncTask.task.cancel()
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

    /// Loads the playlist details including tracks.
    func load() async {
        await self.load(restartingInFlightLoad: false)
    }

    private func load(restartingInFlightLoad: Bool) async {
        guard restartingInFlightLoad || (self.loadingState != .loading && self.loadingState != .loadingMore) else { return }

        self.cancelFullLoadTask()
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.countedPlaylistRemovalSetVideoIDs = []
        self.removedLikedMusicVideoIDs = []
        self.countedRemovedLikedMusicVideoIDs = []
        self.insertedLikedMusicVideoIDs = []

        self.loadingState = .loading
        self.continuationToken = nil
        let playlistTitle = self.playlist.title
        let playlistId = self.playlist.id
        self.logger.info("Loading playlist: \(playlistTitle), ID: \(playlistId)")

        do {
            // For radio playlists (RDCLAK prefix), use the queue API to get all tracks at once
            // This bypasses the broken continuation pagination for these playlists
            // Check for both VL-prefixed and raw RDCLAK IDs
            let isRadioPlaylist = playlistId.contains("RDCLAK") || playlistId.hasPrefix("RD")
            self.logger.debug("Playlist ID: \(playlistId), isRadioPlaylist: \(isRadioPlaylist)")

            let response = try await client.getPlaylist(id: self.playlist.id)
            guard self.isCurrentLoadGeneration(generation) else { return }

            var detail = response.detail
            self.hasMore = response.hasMore
            var nextContinuationToken = response.continuationToken

            // If it's a radio playlist, always fetch all tracks via queue API
            // The browse API often returns hasMore=false even when there are more tracks
            if isRadioPlaylist {
                self.logger.info("Radio playlist detected, fetching all tracks via queue API")
                do {
                    let allTracks = try await client.getPlaylistAllTracks(playlistId: self.playlist.id)
                    guard self.isCurrentLoadGeneration(generation) else { return }

                    if allTracks.count > detail.tracks.count {
                        self.logger.info("Queue API returned \(allTracks.count) tracks (vs \(detail.tracks.count) from browse)")
                        // Update the detail with all tracks from queue API
                        let updatedPlaylist = Playlist(
                            id: detail.id,
                            title: detail.title,
                            description: detail.description,
                            thumbnailURL: detail.thumbnailURL,
                            trackCount: allTracks.count,
                            author: detail.author,
                            canDelete: detail.canDelete || self.playlist.canDelete
                        )
                        detail = PlaylistDetail(
                            playlist: updatedPlaylist,
                            tracks: allTracks,
                            duration: detail.duration
                        )
                        self.hasMore = false
                        nextContinuationToken = nil
                    }
                } catch {
                    // If queue API fails, fall back to browse results
                    self.logger.warning("Queue API failed, using browse results: \(error.localizedDescription)")
                }
            }

            // Determine the best thumbnail to use:
            // 1. API response header thumbnail
            // 2. Original playlist thumbnail (from navigation)
            // 3. First track's thumbnail as fallback
            let resolvedThumbnailURL = detail.thumbnailURL
                ?? self.playlist.thumbnailURL
                ?? detail.tracks.first?.thumbnailURL

            // Check if we need to merge with original playlist info
            let needsMerge = detail.title == "Unknown Playlist" && self.playlist.title != "Unknown Playlist"
            let thumbnailMissing = detail.thumbnailURL == nil && resolvedThumbnailURL != nil

            if needsMerge || thumbnailMissing {
                let mergedTrackCount = max(
                    detail.tracks.count,
                    max(detail.trackCount ?? 0, self.playlist.trackCount ?? 0)
                )

                // Merge with original playlist info or add fallback thumbnail
                // Strip song counts from fallback author since we display the count separately
                let mergedPlaylist = Playlist(
                    id: playlist.id,
                    title: needsMerge ? self.playlist.title : detail.title,
                    description: detail.description ?? self.playlist.description,
                    thumbnailURL: resolvedThumbnailURL,
                    trackCount: mergedTrackCount,
                    author: detail.author ?? self.stripSongCountAuthor(from: self.playlist.author),
                    canDelete: detail.canDelete || self.playlist.canDelete
                )
                detail = PlaylistDetail(
                    playlist: mergedPlaylist,
                    tracks: detail.tracks,
                    duration: detail.duration
                )
            }

            if self.isLikedMusicPlaylist {
                detail = self.normalizeLikedMusicDetail(detail)
            }

            detail = self.filterPlaylistRemovals(from: detail)

            self.playlistDetail = detail
            self.continuationToken = self.hasMore ? nextContinuationToken : nil
            self.loadingState = .loaded
            let loadedTrackCount = detail.tracks.count
            let totalTrackCount = detail.trackCount ?? loadedTrackCount
            self.logger.info("Playlist loaded: \(loadedTrackCount) loaded tracks, total: \(totalTrackCount), hasMore: \(self.hasMore)")
            self.replaceLoadedTrackVideoIds(with: detail.tracks)
        } catch is CancellationError {
            guard self.isCurrentLoadGeneration(generation) else { return }

            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Playlist detail load cancelled")
            self.loadingState = .idle
        } catch {
            guard self.isCurrentLoadGeneration(generation) else { return }

            self.logger.error("Failed to load playlist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
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

    private func applyRemainingTracksResponse(_ response: PlaylistContinuationResponse, batch: ContinuationDrainBatch) -> Bool {
        guard batch.generation == self.loadGeneration,
              !Task.isCancelled,
              let latestDetail = self.playlistDetail
        else { return false }

        let skippedRemovedVideoIDs = batch.isLikedMusicPlaylist
            ? response.tracks.compactMap { song -> String? in
                guard self.removedLikedMusicVideoIDs.contains(song.videoId),
                      self.countedRemovedLikedMusicVideoIDs.insert(song.videoId).inserted
                else { return nil }
                return song.videoId
            }
            : []
        let skippedConfirmedPlaylistRemovalCount = response.tracks.reduce(into: 0) { count, track in
            guard let setVideoId = track.playlistSetVideoId,
                  self.isPlaylistRemovalTombstoned(setVideoId: setVideoId),
                  self.countedPlaylistRemovalSetVideoIDs.insert(setVideoId).inserted
            else { return }
            count += 1
        }
        let skippedRemovalCount = skippedRemovedVideoIDs.count + skippedConfirmedPlaylistRemovalCount
        let playlistFilteredTracks = response.tracks.filter { track in
            guard let setVideoId = track.playlistSetVideoId else { return true }
            return !self.isPlaylistRemovalTombstoned(setVideoId: setVideoId)
        }
        let candidateTracks = batch.isLikedMusicPlaylist
            ? playlistFilteredTracks.filter { !self.removedLikedMusicVideoIDs.contains($0.videoId) }
            : playlistFilteredTracks
        let skippedLiveRemovedTracks = candidateTracks.count != response.tracks.count
        let responseContainsLiveInsertedTrack = batch.isLikedMusicPlaylist && response.tracks.contains { self.insertedLikedMusicVideoIDs.contains($0.videoId) }
        let originalExistingVideoIds = Set(batch.currentDetail.tracks.map(\.videoId))
        let newTracks = candidateTracks.filter {
            !self.loadedTrackVideoIds.contains($0.videoId)
                && !originalExistingVideoIds.contains($0.videoId)
        }

        if newTracks.isEmpty {
            let duplicatesWereAlreadyPresent = candidateTracks.allSatisfy { originalExistingVideoIds.contains($0.videoId) }
            if duplicatesWereAlreadyPresent, !skippedLiveRemovedTracks, !responseContainsLiveInsertedTrack {
                self.hasMore = false
                self.continuationToken = nil
                self.loadingState = .loaded
                self.logger.info("No new unique tracks in continuation, stopping pagination")
                return false
            }

            self.applySkippedRemovalCount(skippedRemovalCount, to: latestDetail)
            self.continuationToken = response.continuationToken
            self.hasMore = response.hasMore
            self.loadingState = .loaded
            self.logger.info("Continuation tracks already live-synced; advancing cursor, hasMore: \(self.hasMore)")
            return self.hasMore
        }

        let normalizedNewTracks: [Song] = if batch.isLikedMusicPlaylist {
            self.markSongsAsLiked(newTracks)
        } else {
            newTracks
        }

        var allTracks = latestDetail.tracks
        allTracks.reserveCapacity(latestDetail.tracks.count + normalizedNewTracks.count)
        allTracks.append(contentsOf: normalizedNewTracks)
        let adjustedTrackCount = self.adjustedTrackCount(latestDetail.trackCount, skippedRemovalCount: skippedRemovalCount)
        let preservedTrackCount = max(allTracks.count, adjustedTrackCount ?? 0)
        let updatedPlaylist = Playlist(
            id: latestDetail.id,
            title: latestDetail.title,
            description: latestDetail.description,
            thumbnailURL: latestDetail.thumbnailURL,
            trackCount: preservedTrackCount,
            author: latestDetail.author,
            canDelete: latestDetail.canDelete
        )
        self.playlistDetail = PlaylistDetail(
            playlist: updatedPlaylist,
            tracks: allTracks,
            duration: latestDetail.duration
        )
        self.insertLoadedTrackVideoIds(from: normalizedNewTracks)

        if batch.isLikedMusicPlaylist {
            SongLikeStatusManager.shared.setStatus(.like, for: normalizedNewTracks.lazy.map(\.videoId))
        }

        self.continuationToken = response.continuationToken
        self.hasMore = response.hasMore
        self.loadingState = .loaded
        self.logger.info("Loaded \(normalizedNewTracks.count) new tracks (from \(response.tracks.count)), loaded total: \(allTracks.count), reported total: \(preservedTrackCount), hasMore: \(self.hasMore)")
        return self.hasMore
    }

    private func adjustedTrackCount(_ trackCount: Int?, skippedRemovalCount: Int) -> Int? {
        guard skippedRemovalCount > 0, let trackCount else { return trackCount }
        return max(0, trackCount - skippedRemovalCount)
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

        self.loadingState = .loadingMore
        self.logger.info("Loading more playlist tracks")

        do {
            let continuation = continuationToken
            let response = try await client.getPlaylistContinuation(
                token: continuation,
                requiresAuth: currentDetail.requiresPersonalAccountForContinuations
            )
            let batch = ContinuationDrainBatch(
                generation: generation ?? self.loadGeneration,
                continuation: continuation,
                currentDetail: currentDetail,
                isLikedMusicPlaylist: self.isLikedMusicPlaylist,
                requiresAuth: currentDetail.requiresPersonalAccountForContinuations
            )
            return self.applyRemainingTracksResponse(response, batch: batch)
        } catch is CancellationError {
            guard self.isCurrentLoadGeneration(generation) else { return false }
            self.logger.debug("Playlist continuation cancelled")
            self.loadingState = .loaded
            return false
        } catch {
            guard self.isCurrentLoadGeneration(generation) else { return false }
            self.logger.error("Failed to load more playlist tracks: \(error.localizedDescription)")
            // Keep loaded state so user can retry
            self.loadingState = .loaded
            return false
        }
    }

    /// Handles like status updates for the Liked Music playlist.
    func handleLikeStatusChange(_ event: LikeStatusEvent) {
        guard self.isLikedMusicPlaylist else { return }
        guard self.loadingState == .loaded || self.loadingState == .loadingMore else { return }

        switch event.status {
        // - Liked songs are inserted at the top.
        case .like:
            self.removedLikedMusicVideoIDs.remove(event.videoId)
            self.countedRemovedLikedMusicVideoIDs.remove(event.videoId)
            if let song = event.song, !Self.requiresMetadataFetchForLiveSync(song) {
                self.cancelLiveSyncTask(for: event.videoId)
                self.insertLiveSyncedLikedSong(song)
            } else {
                guard !self.containsTrack(videoId: event.videoId) else { return }
                self.startLiveSyncTask(for: event.videoId)
            }
        // - Unliked/disliked songs are removed immediately.
        case .indifferent, .dislike:
            let wasLoaded = self.containsTrack(videoId: event.videoId)
            self.removedLikedMusicVideoIDs.insert(event.videoId)
            if wasLoaded {
                self.countedRemovedLikedMusicVideoIDs.insert(event.videoId)
            }
            self.insertedLikedMusicVideoIDs.remove(event.videoId)
            SongLikeStatusManager.shared.setCachedStatus(event.status, for: event.videoId)
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

    private func cancelFullLoadTask() {
        self.fullLoadTask?.cancel()
        self.fullLoadTask = nil
    }

    private func isCurrentLoadGeneration(_ generation: Int?) -> Bool {
        guard let generation else { return true }
        return generation == self.loadGeneration
    }

    private func normalizeLikedMusicDetail(_ detail: PlaylistDetail) -> PlaylistDetail {
        let likedTracks = self.markSongsAsLiked(detail.tracks, deduplicating: true)
        SongLikeStatusManager.shared.setStatus(.like, for: likedTracks.lazy.map(\.videoId))

        let resolvedTrackCount = max(detail.trackCount ?? 0, likedTracks.count)
        return self.updatedPlaylistDetail(
            from: detail,
            tracks: likedTracks,
            trackCount: resolvedTrackCount
        )
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

    private func markSongsAsLiked(_ tracks: [Song], deduplicating: Bool = false) -> [Song] {
        var seenVideoIds = Set<String>()

        return tracks.compactMap { song in
            if deduplicating, !seenVideoIds.insert(song.videoId).inserted {
                return nil
            }

            var likedSong = song
            likedSong.likeStatus = .like
            return likedSong
        }
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
        self.replaceLoadedTrackVideoIds(with: detail?.tracks ?? [])
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

    private func insertLiveSyncedLikedSong(_ song: Song) {
        guard let currentDetail = self.playlistDetail else { return }
        guard !self.loadedTrackVideoIds.contains(song.videoId) else { return }

        var likedSong = song
        likedSong.likeStatus = .like
        self.insertedLikedMusicVideoIDs.insert(song.videoId)

        let updatedTracks = [likedSong] + currentDetail.tracks
        let currentTotal = currentDetail.trackCount ?? currentDetail.tracks.count
        let updatedTrackCount = max(currentTotal + 1, updatedTracks.count)

        self.playlistDetail = self.updatedPlaylistDetail(
            from: currentDetail,
            tracks: updatedTracks,
            trackCount: updatedTrackCount
        )
        self.loadedTrackVideoIds.insert(song.videoId)
        SongLikeStatusManager.shared.setCachedStatus(.like, for: song.videoId)
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

    private func startLiveSyncTask(for videoId: String) {
        let taskID = UUID()
        self.cancelLiveSyncTask(for: videoId)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchAndInsertLiveSyncedLikedSong(videoId: videoId, taskID: taskID)
        }
        self.liveSyncTasks[videoId] = LiveSyncTask(id: taskID, task: task)
    }

    private func fetchAndInsertLiveSyncedLikedSong(videoId: String, taskID: UUID) async {
        defer {
            if self.liveSyncTasks[videoId]?.id == taskID {
                self.liveSyncTasks.removeValue(forKey: videoId)
            }
        }

        guard self.liveSyncTasks[videoId]?.id == taskID else { return }
        guard !Task.isCancelled else { return }
        guard !self.containsTrack(videoId: videoId) else { return }

        do {
            let song = try await self.client.getSong(videoId: videoId)

            guard !Task.isCancelled else { return }
            guard self.liveSyncTasks[videoId]?.id == taskID else { return }
            guard !Self.requiresMetadataFetchForLiveSync(song) else {
                self.logger.warning("Live sync: skipping incomplete metadata for liked song \(videoId)")
                return
            }

            self.insertLiveSyncedLikedSong(song)
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
