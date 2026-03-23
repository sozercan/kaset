import Foundation
import Observation

/// View model for the Liked Music view.
@MainActor
@Observable
final class LikedMusicViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Liked songs.
    private(set) var songs: [Song] = []

    /// Whether more songs are available to load.
    private(set) var hasMore: Bool = false

    /// The API client.
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    /// Loads liked songs.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        self.logger.info("Loading liked songs")

        do {
            let response = try await client.getLikedSongs()
            // Mark all songs as liked since they come from the liked songs API
            self.songs = response.songs.map { song in
                var mutableSong = song
                mutableSong.likeStatus = .like
                return mutableSong
            }
            self.hasMore = response.hasMore
            // Also populate the like status manager cache
            for song in self.songs {
                SongLikeStatusManager.shared.setStatus(.like, for: song.videoId)
            }
            self.loadingState = .loaded
            self.logger.info("Loaded \(response.songs.count) liked songs, hasMore: \(self.hasMore)")
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Liked songs load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load liked songs: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Loads more liked songs via continuation.
    func loadMore() async {
        guard self.loadingState == .loaded, self.hasMore else { return }

        self.loadingState = .loadingMore
        self.logger.info("Loading more liked songs")

        do {
            guard let response = try await client.getLikedSongsContinuation() else {
                self.hasMore = false
                self.loadingState = .loaded
                return
            }

            // Build a set of existing video IDs for deduplication
            let existingVideoIds = Set(self.songs.map(\.videoId))

            // Filter out duplicates and mark all songs as liked
            let newSongs = response.songs
                .filter { !existingVideoIds.contains($0.videoId) }
                .map { song in
                    var mutableSong = song
                    mutableSong.likeStatus = .like
                    return mutableSong
                }

            // If no new unique songs were added, stop pagination
            if newSongs.isEmpty {
                self.hasMore = false
                self.loadingState = .loaded
                self.logger.info("No new unique songs in continuation, stopping pagination")
                return
            }

            self.songs.append(contentsOf: newSongs)
            self.hasMore = response.hasMore

            // Populate the like status manager cache
            for song in newSongs {
                SongLikeStatusManager.shared.setStatus(.like, for: song.videoId)
            }

            self.loadingState = .loaded
            self.logger.info("Loaded \(newSongs.count) new liked songs (from \(response.songs.count)), total: \(self.songs.count), hasMore: \(self.hasMore)")
        } catch is CancellationError {
            self.logger.debug("Liked songs continuation cancelled")
            self.loadingState = .loaded
        } catch {
            self.logger.error("Failed to load more liked songs: \(error.localizedDescription)")
            // Keep loaded state so user can retry
            self.loadingState = .loaded
        }
    }

    /// Refreshes liked songs.
    func refresh() async {
        self.songs = []
        self.hasMore = false
        await self.load()
    }
}
