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
            // Deduplicate by videoId and mark all songs as liked
            var seenVideoIds = Set<String>()
            self.songs = response.songs.compactMap { song in
                guard seenVideoIds.insert(song.videoId).inserted else { return nil }
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

    // MARK: - Real-time Like Status Sync

    /// Handles a like status change event to keep the song list in sync.
    /// - When a song is liked: adds it to the top of the list (if not already present).
    /// - When a song is unliked/disliked: removes it from the list.
    func handleLikeStatusChange(_ event: LikeStatusEvent) {
        guard self.loadingState == .loaded || self.loadingState == .loadingMore else { return }

        switch event.status {
        case .like:
            // Add to top if not already in the list
            guard !self.songs.contains(where: { $0.videoId == event.videoId }) else { return }
            if let song = event.song {
                var likedSong = song
                likedSong.likeStatus = .like
                self.songs.insert(likedSong, at: 0)
                self.logger.info("Live sync: added song \(event.videoId) to liked music")
            }
        case .indifferent, .dislike:
            // Remove from list
            let countBefore = self.songs.count
            self.songs.removeAll { $0.videoId == event.videoId }
            if self.songs.count < countBefore {
                self.logger.info("Live sync: removed song \(event.videoId) from liked music")
            }
        }
    }
}
