import Foundation

// MARK: - SongLikeStatusManager

/// Manages like/dislike status for songs across the app.
/// This service caches like statuses locally and syncs with the YouTube Music API.
@MainActor
@Observable
final class SongLikeStatusManager {
    /// Shared singleton instance.
    static let shared = SongLikeStatusManager()

    /// Cache of video ID to like status.
    private var statusCache: [String: LikeStatus] = [:]

    /// Reference to the YTMusic client for API calls.
    private var client: (any YTMusicClientProtocol)?

    private init() {}

    // MARK: - Configuration

    /// Sets the client to use for API calls.
    /// - Parameter client: The YTMusic client.
    func setClient(_ client: any YTMusicClientProtocol) {
        self.client = client
    }

    // MARK: - Status Queries

    /// Gets the cached like status for a song.
    /// - Parameter videoId: The video ID of the song.
    /// - Returns: The cached status, or nil if not cached.
    func status(for videoId: String) -> LikeStatus? {
        self.statusCache[videoId]
    }

    /// Gets the like status for a song, using the song's own status as fallback.
    /// - Parameter song: The song to check.
    /// - Returns: The status from cache, song property, or nil.
    func status(for song: Song) -> LikeStatus? {
        self.statusCache[song.videoId] ?? song.likeStatus
    }

    /// Checks if a song is liked.
    /// - Parameter song: The song to check.
    /// - Returns: True if the song is liked.
    func isLiked(_ song: Song) -> Bool {
        self.status(for: song) == .like
    }

    /// Checks if a song is disliked.
    /// - Parameter song: The song to check.
    /// - Returns: True if the song is disliked.
    func isDisliked(_ song: Song) -> Bool {
        self.status(for: song) == .dislike
    }

    // MARK: - Rating Actions

    /// Likes a song.
    /// - Parameter song: The song to like.
    func like(_ song: Song) async {
        await self.rate(song, status: .like)
    }

    /// Unlikes a song (removes rating).
    /// - Parameter song: The song to unlike.
    func unlike(_ song: Song) async {
        await self.rate(song, status: .indifferent)
    }

    /// Dislikes a song.
    /// - Parameter song: The song to dislike.
    func dislike(_ song: Song) async {
        await self.rate(song, status: .dislike)
    }

    /// Undislikes a song (removes rating).
    /// - Parameter song: The song to undislike.
    func undislike(_ song: Song) async {
        await self.rate(song, status: .indifferent)
    }

    /// Rates a song with the given status.
    /// - Parameters:
    ///   - song: The song to rate.
    ///   - status: The rating to apply.
    private func rate(_ song: Song, status: LikeStatus) async {
        guard let client else {
            DiagnosticsLogger.api.warning("SongLikeStatusManager: No client set, cannot rate song")
            return
        }

        // Optimistically update cache
        let previousStatus = self.statusCache[song.videoId]
        self.statusCache[song.videoId] = status

        do {
            try await client.rateSong(videoId: song.videoId, rating: status)
            DiagnosticsLogger.api.info("Rated song \(song.videoId) as \(status.rawValue)")
        } catch is CancellationError {
            // Task was cancelled - rollback optimistic update
            if let previous = previousStatus {
                self.statusCache[song.videoId] = previous
            } else {
                self.statusCache.removeValue(forKey: song.videoId)
            }
            DiagnosticsLogger.api.debug("Rating cancelled for song \(song.videoId), rolled back")
        } catch {
            // Revert on failure
            if let previous = previousStatus {
                self.statusCache[song.videoId] = previous
            } else {
                self.statusCache.removeValue(forKey: song.videoId)
            }
            DiagnosticsLogger.api.error("Failed to rate song: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache Management

    /// Updates the cache with a known status (e.g., from API response).
    /// - Parameters:
    ///   - videoId: The video ID.
    ///   - status: The like status.
    func setStatus(_ status: LikeStatus, for videoId: String) {
        self.statusCache[videoId] = status
    }

    /// Clears all cached statuses.
    func clearCache() {
        self.statusCache.removeAll()
    }
}
