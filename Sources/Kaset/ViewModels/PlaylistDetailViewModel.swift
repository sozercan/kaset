import Foundation
import Observation
import os

/// View model for the PlaylistDetailView.
@MainActor
@Observable
final class PlaylistDetailViewModel {
    private static let fullPlaylistLoadTrackThreshold = 100

    private struct LiveSyncTask {
        let id: UUID
        let task: Task<Void, Never>
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

    private var isLikedMusicPlaylist: Bool {
        LikedMusicPlaylist.matches(id: self.playlist.id)
    }

    init(playlist: Playlist, client: any YTMusicClientProtocol) {
        self.playlist = playlist
        self.client = client
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

    /// Loads the playlist details including tracks.
    func load() async {
        guard self.loadingState != .loading else { return }

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
            var detail = response.detail
            self.hasMore = response.hasMore
            var nextContinuationToken = response.continuationToken

            // If it's a radio playlist, always fetch all tracks via queue API
            // The browse API often returns hasMore=false even when there are more tracks
            if isRadioPlaylist {
                self.logger.info("Radio playlist detected, fetching all tracks via queue API")
                do {
                    let allTracks = try await client.getPlaylistAllTracks(playlistId: self.playlist.id)
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

            self.playlistDetail = detail
            self.continuationToken = self.hasMore ? nextContinuationToken : nil
            self.loadingState = .loaded
            let loadedTrackCount = detail.tracks.count
            let totalTrackCount = detail.trackCount ?? loadedTrackCount
            self.logger.info("Playlist loaded: \(loadedTrackCount) loaded tracks, total: \(totalTrackCount), hasMore: \(self.hasMore)")
            await self.loadRemainingTracksIfNeeded()
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Playlist detail load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load playlist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Loads more tracks via continuation.
    func loadMore() async {
        _ = await self.loadMoreBatch()
    }

    private func loadRemainingTracksIfNeeded() async {
        guard let currentDetail = self.playlistDetail,
              self.hasMore,
              self.shouldLoadFullPlaylist(currentDetail)
        else { return }

        let initialTrackCount = currentDetail.tracks.count
        let totalTrackCount = currentDetail.trackCount ?? self.playlist.trackCount ?? initialTrackCount
        self.logger.info("Loading full playlist: \(initialTrackCount) loaded tracks, total: \(totalTrackCount)")

        while self.hasMore {
            let didLoadTracks = await self.loadMoreBatch()
            guard didLoadTracks else { break }
        }
    }

    private func shouldLoadFullPlaylist(_ detail: PlaylistDetail) -> Bool {
        guard !detail.isAlbum else { return false }
        if self.isLikedMusicPlaylist { return true }

        let reportedTrackCount = max(detail.trackCount ?? 0, self.playlist.trackCount ?? 0)
        if reportedTrackCount > Self.fullPlaylistLoadTrackThreshold {
            return true
        }

        return detail.tracks.count >= Self.fullPlaylistLoadTrackThreshold
    }

    private func loadMoreBatch() async -> Bool {
        guard self.loadingState == .loaded,
              self.hasMore,
              let continuationToken,
              let currentDetail = self.playlistDetail
        else { return false }

        self.loadingState = .loadingMore
        self.logger.info("Loading more playlist tracks")

        do {
            let response = try await client.getPlaylistContinuation(token: continuationToken)

            // Build a set of existing video IDs for deduplication
            let existingVideoIds = Set(currentDetail.tracks.map(\.videoId))

            // Filter out duplicates from the new tracks
            let newTracks = response.tracks.filter { !existingVideoIds.contains($0.videoId) }

            // If no new unique tracks were added, stop pagination
            // This handles radio playlists that return overlapping data
            if newTracks.isEmpty {
                self.hasMore = false
                self.continuationToken = nil
                self.loadingState = .loaded
                self.logger.info("No new unique tracks in continuation, stopping pagination")
                return false
            }

            let normalizedNewTracks: [Song] = if self.isLikedMusicPlaylist {
                self.markSongsAsLiked(newTracks)
            } else {
                newTracks
            }

            // Append only new tracks to existing playlist
            let allTracks = currentDetail.tracks + normalizedNewTracks
            let preservedTrackCount = max(allTracks.count, currentDetail.trackCount ?? 0)
            let updatedPlaylist = Playlist(
                id: currentDetail.id,
                title: currentDetail.title,
                description: currentDetail.description,
                thumbnailURL: currentDetail.thumbnailURL,
                trackCount: preservedTrackCount,
                author: currentDetail.author,
                canDelete: currentDetail.canDelete
            )
            self.playlistDetail = PlaylistDetail(
                playlist: updatedPlaylist,
                tracks: allTracks,
                duration: currentDetail.duration
            )

            if self.isLikedMusicPlaylist {
                for song in normalizedNewTracks {
                    SongLikeStatusManager.shared.setStatus(.like, for: song.videoId)
                }
            }

            self.continuationToken = response.continuationToken
            self.hasMore = response.hasMore

            self.loadingState = .loaded
            self.logger.info("Loaded \(normalizedNewTracks.count) new tracks (from \(response.tracks.count)), loaded total: \(allTracks.count), reported total: \(preservedTrackCount), hasMore: \(self.hasMore)")
            return true
        } catch is CancellationError {
            self.logger.debug("Playlist continuation cancelled")
            self.loadingState = .loaded
            return false
        } catch {
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
            if let song = event.song, !Self.requiresMetadataFetchForLiveSync(song) {
                self.cancelLiveSyncTask(for: event.videoId)
                self.insertLiveSyncedLikedSong(song)
            } else {
                guard !self.containsTrack(videoId: event.videoId) else { return }
                self.startLiveSyncTask(for: event.videoId)
            }
        // - Unliked/disliked songs are removed immediately.
        case .indifferent, .dislike:
            self.cancelLiveSyncTask(for: event.videoId)
            self.removeLiveSyncedLikedSong(videoId: event.videoId)
        }
    }

    /// Refreshes the playlist.
    func refresh() async {
        self.cancelAllLiveSyncTasks()
        self.playlistDetail = nil
        self.hasMore = false
        self.continuationToken = nil
        await self.load()
    }

    private func normalizeLikedMusicDetail(_ detail: PlaylistDetail) -> PlaylistDetail {
        let likedTracks = self.markSongsAsLiked(detail.tracks, deduplicating: true)
        for song in likedTracks {
            SongLikeStatusManager.shared.setStatus(.like, for: song.videoId)
        }

        let resolvedTrackCount = max(detail.trackCount ?? 0, likedTracks.count)
        return self.updatedPlaylistDetail(
            from: detail,
            tracks: likedTracks,
            trackCount: resolvedTrackCount
        )
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
        self.playlistDetail?.tracks.contains(where: { $0.videoId == videoId }) == true
    }

    private func insertLiveSyncedLikedSong(_ song: Song) {
        guard let currentDetail = self.playlistDetail else { return }
        guard !currentDetail.tracks.contains(where: { $0.videoId == song.videoId }) else { return }

        var likedSong = song
        likedSong.likeStatus = .like

        let updatedTracks = [likedSong] + currentDetail.tracks
        let currentTotal = currentDetail.trackCount ?? currentDetail.tracks.count
        let updatedTrackCount = max(currentTotal + 1, updatedTracks.count)

        self.playlistDetail = self.updatedPlaylistDetail(
            from: currentDetail,
            tracks: updatedTracks,
            trackCount: updatedTrackCount
        )
        SongLikeStatusManager.shared.setStatus(.like, for: song.videoId)
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
