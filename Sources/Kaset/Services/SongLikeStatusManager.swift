import Foundation

// MARK: - LikeStatusEvent

/// Represents a like status change event for reactive UI updates.
struct LikeStatusEvent: Equatable {
    let videoId: String
    let status: LikeStatus
    let song: Song?
    private let eventId = UUID()

    static func == (lhs: LikeStatusEvent, rhs: LikeStatusEvent) -> Bool {
        lhs.eventId == rhs.eventId
    }
}

// MARK: - SongLikeStatusManager

/// Manages like/dislike status for songs across the app.
/// This service caches like statuses locally and syncs with the YouTube Music API.
@MainActor
@Observable
final class SongLikeStatusManager {
    /// Shared singleton instance.
    static let shared = SongLikeStatusManager()

    private static let primaryAccountID = "primary"

    /// Cache of account ID to (video ID to like status).
    private var statusCacheByAccount: [String: [String: LikeStatus]] = [:]

    /// Currently active account scope for cache lookups.
    private(set) var activeAccountID = SongLikeStatusManager.primaryAccountID

    /// The most recent like status change event, for reactive observation by views.
    private(set) var lastLikeEvent: LikeStatusEvent?

    /// Reference to the YTMusic client for API calls.
    private var client: (any YTMusicClientProtocol)?

    private init() {}

    // MARK: - Configuration

    /// Sets the client to use for API calls.
    /// - Parameter client: The YTMusic client, or `nil` to clear the override.
    func setClient(_ client: (any YTMusicClientProtocol)?) {
        self.client = client
    }

    /// The currently configured client override.
    var currentClient: (any YTMusicClientProtocol)? {
        self.client
    }

    /// Updates the active account scope used for cache lookups and writes.
    /// - Parameter accountID: The active account identifier, or `nil` for the primary account.
    func setActiveAccountID(_ accountID: String?) {
        let resolvedAccountID = Self.resolvedAccountID(accountID)
        guard self.activeAccountID != resolvedAccountID else { return }

        self.activeAccountID = resolvedAccountID
        DiagnosticsLogger.api.debug("SongLikeStatusManager: Switched cache scope to account \(resolvedAccountID)")
    }

    // MARK: - Status Queries

    /// Gets the cached like status for a song.
    /// - Parameter videoId: The video ID of the song.
    /// - Returns: The cached status, or nil if not cached.
    func status(for videoId: String) -> LikeStatus? {
        self.status(for: videoId, accountID: self.activeAccountID)
    }

    /// Gets the like status for a song, using the song's own status as fallback.
    /// - Parameter song: The song to check.
    /// - Returns: The status from cache, song property, or nil.
    func status(for song: Song) -> LikeStatus? {
        self.status(for: song.videoId) ?? song.likeStatus
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
    /// - Parameters:
    ///   - song: The song to like.
    ///   - accountID: Optional account scope override.
    ///   - client: Optional client override.
    /// - Returns: The final status after the request settles.
    @discardableResult
    func like(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil
    ) async -> LikeStatus {
        await self.rate(song, status: .like, accountID: accountID, client: client)
    }

    /// Unlikes a song (removes rating).
    /// - Parameters:
    ///   - song: The song to unlike.
    ///   - accountID: Optional account scope override.
    ///   - client: Optional client override.
    /// - Returns: The final status after the request settles.
    @discardableResult
    func unlike(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil
    ) async -> LikeStatus {
        await self.rate(song, status: .indifferent, accountID: accountID, client: client)
    }

    /// Dislikes a song.
    /// - Parameters:
    ///   - song: The song to dislike.
    ///   - accountID: Optional account scope override.
    ///   - client: Optional client override.
    /// - Returns: The final status after the request settles.
    @discardableResult
    func dislike(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil
    ) async -> LikeStatus {
        await self.rate(song, status: .dislike, accountID: accountID, client: client)
    }

    /// Undislikes a song (removes rating).
    /// - Parameters:
    ///   - song: The song to undislike.
    ///   - accountID: Optional account scope override.
    ///   - client: Optional client override.
    /// - Returns: The final status after the request settles.
    @discardableResult
    func undislike(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil
    ) async -> LikeStatus {
        await self.rate(song, status: .indifferent, accountID: accountID, client: client)
    }

    /// Rates a song with the given status.
    /// - Parameters:
    ///   - song: The song to rate.
    ///   - status: The rating to apply.
    ///   - accountID: Optional account scope override.
    ///   - client: Optional client override.
    /// - Returns: The final status after the request settles.
    private func rate(
        _ song: Song,
        status: LikeStatus,
        accountID: String?,
        client overrideClient: (any YTMusicClientProtocol)?
    ) async -> LikeStatus {
        let resolvedAccountID = accountID.map(Self.resolvedAccountID) ?? self.activeAccountID

        guard let client = overrideClient ?? self.client else {
            DiagnosticsLogger.api.warning("SongLikeStatusManager: No client set, cannot rate song")
            return self.status(for: song.videoId, accountID: resolvedAccountID) ?? song.likeStatus ?? .indifferent
        }

        // Optimistically update cache and notify observers
        let previousStatus = self.status(for: song.videoId, accountID: resolvedAccountID)
        self.setStatus(status, for: song.videoId, accountID: resolvedAccountID)
        self.publishEvent(
            LikeStatusEvent(videoId: song.videoId, status: status, song: song),
            for: resolvedAccountID
        )

        do {
            try await client.rateSong(videoId: song.videoId, rating: status)
            DiagnosticsLogger.api.info("Rated song \(song.videoId) as \(status.rawValue)")
            return status
        } catch is CancellationError {
            // Task was cancelled - rollback optimistic update and notify
            let rollbackStatus = previousStatus ?? .indifferent
            self.restoreStatus(previousStatus, for: song.videoId, accountID: resolvedAccountID)
            self.publishEvent(
                LikeStatusEvent(videoId: song.videoId, status: rollbackStatus, song: song),
                for: resolvedAccountID
            )
            DiagnosticsLogger.api.debug("Rating cancelled for song \(song.videoId), rolled back")
            return rollbackStatus
        } catch {
            // Revert on failure and notify
            let rollbackStatus = previousStatus ?? .indifferent
            self.restoreStatus(previousStatus, for: song.videoId, accountID: resolvedAccountID)
            self.publishEvent(
                LikeStatusEvent(videoId: song.videoId, status: rollbackStatus, song: song),
                for: resolvedAccountID
            )
            DiagnosticsLogger.api.error("Failed to rate song: \(error.localizedDescription)")
            return rollbackStatus
        }
    }

    // MARK: - Cache Management

    /// Updates the cache with a known status (e.g., from API response).
    /// - Parameters:
    ///   - videoId: The video ID.
    ///   - status: The like status.
    func setStatus(_ status: LikeStatus, for videoId: String) {
        self.setStatus(status, for: videoId, accountID: self.activeAccountID)
    }

    /// Clears all cached statuses.
    func clearCache() {
        self.statusCacheByAccount.removeAll()
        self.lastLikeEvent = nil
    }

    private static func resolvedAccountID(_ accountID: String?) -> String {
        accountID ?? self.primaryAccountID
    }

    func status(for videoId: String, accountID: String?) -> LikeStatus? {
        self.statusCacheByAccount[Self.resolvedAccountID(accountID)]?[videoId]
    }

    private func setStatus(_ status: LikeStatus, for videoId: String, accountID: String) {
        var cache = self.statusCacheByAccount[accountID] ?? [:]
        cache[videoId] = status
        self.statusCacheByAccount[accountID] = cache
    }

    private func restoreStatus(_ status: LikeStatus?, for videoId: String, accountID: String) {
        if let status {
            self.setStatus(status, for: videoId, accountID: accountID)
        } else {
            self.removeStatus(for: videoId, accountID: accountID)
        }
    }

    private func removeStatus(for videoId: String, accountID: String) {
        guard var cache = self.statusCacheByAccount[accountID] else { return }

        cache.removeValue(forKey: videoId)
        if cache.isEmpty {
            self.statusCacheByAccount.removeValue(forKey: accountID)
        } else {
            self.statusCacheByAccount[accountID] = cache
        }
    }

    private func publishEvent(_ event: LikeStatusEvent, for accountID: String) {
        guard accountID == self.activeAccountID else { return }
        self.lastLikeEvent = event
    }
}
