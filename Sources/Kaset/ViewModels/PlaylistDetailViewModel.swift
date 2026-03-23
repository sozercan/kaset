import Foundation
import Observation
import os

/// View model for the PlaylistDetailView.
@MainActor
@Observable
final class PlaylistDetailViewModel {
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

    init(playlist: Playlist, client: any YTMusicClientProtocol) {
        self.playlist = playlist
        self.client = client
    }

    /// Strips song count patterns from author text (e.g., " • 145 songs").
    /// Used to clean fallback author values that may contain redundant song counts.
    private func stripSongCount(from text: String?) -> String? {
        guard var result = text else { return nil }
        result = result.replacingOccurrences(
            of: #" • \d+ songs?"#,
            with: "",
            options: .regularExpression
        )
        if result.hasPrefix(" • ") {
            result = String(result.dropFirst(3))
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    /// Loads the playlist details including tracks.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
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
                            author: detail.author
                        )
                        detail = PlaylistDetail(
                            playlist: updatedPlaylist,
                            tracks: allTracks,
                            duration: detail.duration
                        )
                        self.hasMore = false
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
                // Merge with original playlist info or add fallback thumbnail
                // Strip song counts from fallback author since we display the count separately
                let mergedPlaylist = Playlist(
                    id: playlist.id,
                    title: needsMerge ? self.playlist.title : detail.title,
                    description: detail.description ?? self.playlist.description,
                    thumbnailURL: resolvedThumbnailURL,
                    trackCount: detail.tracks.count,
                    author: detail.author ?? self.stripSongCount(from: self.playlist.author)
                )
                detail = PlaylistDetail(
                    playlist: mergedPlaylist,
                    tracks: detail.tracks,
                    duration: detail.duration
                )
            }

            self.playlistDetail = detail
            self.loadingState = .loaded
            let trackCount = detail.tracks.count
            self.logger.info("Playlist loaded: \(trackCount) tracks, hasMore: \(self.hasMore)")
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
        guard self.loadingState == .loaded, self.hasMore, let currentDetail = playlistDetail else { return }

        self.loadingState = .loadingMore
        self.logger.info("Loading more playlist tracks")

        do {
            guard let response = try await client.getPlaylistContinuation() else {
                self.hasMore = false
                self.loadingState = .loaded
                return
            }

            // Build a set of existing video IDs for deduplication
            let existingVideoIds = Set(currentDetail.tracks.map(\.videoId))

            // Filter out duplicates from the new tracks
            let newTracks = response.tracks.filter { !existingVideoIds.contains($0.videoId) }

            // If no new unique tracks were added, stop pagination
            // This handles radio playlists that return overlapping data
            if newTracks.isEmpty {
                self.hasMore = false
                self.loadingState = .loaded
                self.logger.info("No new unique tracks in continuation, stopping pagination")
                return
            }

            // Append only new tracks to existing playlist
            let allTracks = currentDetail.tracks + newTracks
            let updatedPlaylist = Playlist(
                id: currentDetail.id,
                title: currentDetail.title,
                description: currentDetail.description,
                thumbnailURL: currentDetail.thumbnailURL,
                trackCount: allTracks.count,
                author: currentDetail.author
            )
            self.playlistDetail = PlaylistDetail(
                playlist: updatedPlaylist,
                tracks: allTracks,
                duration: currentDetail.duration
            )
            self.hasMore = response.hasMore

            self.loadingState = .loaded
            self.logger.info("Loaded \(newTracks.count) new tracks (from \(response.tracks.count)), total: \(allTracks.count), hasMore: \(self.hasMore)")
        } catch is CancellationError {
            self.logger.debug("Playlist continuation cancelled")
            self.loadingState = .loaded
        } catch {
            self.logger.error("Failed to load more playlist tracks: \(error.localizedDescription)")
            // Keep loaded state so user can retry
            self.loadingState = .loaded
        }
    }

    /// Refreshes the playlist.
    func refresh() async {
        self.playlistDetail = nil
        self.hasMore = false
        await self.load()
    }
}
