import Foundation
import Testing
@testable import Kaset

/// Tests for SongLikeStatusManager.
@Suite(.serialized, .tags(.service))
@MainActor
struct SongLikeStatusManagerTests {
    var manager: SongLikeStatusManager
    var mockClient: MockYTMusicClient

    init() {
        // Use the shared singleton (init is private)
        self.manager = SongLikeStatusManager.shared
        self.mockClient = MockYTMusicClient()
        self.manager.clearCache()
        self.manager.setActiveAccountID(nil)
        self.manager.setClient(nil)
    }

    // MARK: - Status Query Tests

    @Test("status for videoId returns nil when not cached")
    func statusForVideoIdReturnsNilWhenNotCached() {
        let status = self.manager.status(for: "unknown-video")
        #expect(status == nil)
    }

    @Test("status for videoId returns cached value")
    func statusForVideoIdReturnsCached() {
        let videoID = "status-cached-video"
        self.manager.setStatus(.like, for: videoID)

        let status = self.manager.status(for: videoID)

        #expect(status == .like)
    }

    @Test("status for song uses cache over song property")
    func statusForSongUsesCacheOverProperty() {
        let videoID = "status-cache-over-property-video"
        let song = Song(
            id: videoID,
            title: "Test",
            artists: [],
            videoId: videoID,
            likeStatus: .dislike
        )
        self.manager.setStatus(.like, for: videoID)

        let status = self.manager.status(for: song)

        #expect(status == .like) // Cache takes precedence
    }

    @Test("status for song falls back to song property")
    func statusForSongFallsBackToProperty() {
        let videoID = "status-fallback-to-property-video"
        let song = Song(
            id: videoID,
            title: "Test",
            artists: [],
            videoId: videoID,
            likeStatus: .dislike
        )
        // No cache set

        let status = self.manager.status(for: song)

        #expect(status == .dislike)
    }

    @Test("isLiked returns true when liked")
    func isLikedReturnsTrue() {
        let song = TestFixtures.makeSong(id: "test-video")
        self.manager.setStatus(.like, for: "test-video")

        #expect(self.manager.isLiked(song) == true)
        #expect(self.manager.isDisliked(song) == false)
    }

    @Test("isDisliked returns true when disliked")
    func isDislikedReturnsTrue() {
        let song = TestFixtures.makeSong(id: "test-video")
        self.manager.setStatus(.dislike, for: "test-video")

        #expect(self.manager.isDisliked(song) == true)
        #expect(self.manager.isLiked(song) == false)
    }

    // MARK: - Rating Action Tests

    @Test("like updates cache and calls API")
    func likeUpdatesCacheAndCallsAPI() async {
        let song = TestFixtures.makeSong(id: "test-video")

        await self.manager.like(song, client: self.mockClient)

        #expect(self.manager.status(for: "test-video") == .like)
        #expect(self.mockClient.rateSongCalled == true)
        #expect(self.mockClient.rateSongVideoIds.first == "test-video")
        #expect(self.mockClient.rateSongRatings.first == .like)
    }

    @Test("unlike updates cache to indifferent")
    func unlikeUpdatesCacheToIndifferent() async {
        let song = TestFixtures.makeSong(id: "test-video")
        self.manager.setStatus(.like, for: "test-video")

        await self.manager.unlike(song, client: self.mockClient)

        #expect(self.manager.status(for: "test-video") == .indifferent)
        #expect(self.mockClient.rateSongRatings.first == .indifferent)
    }

    @Test("dislike updates cache and calls API")
    func dislikeUpdatesCacheAndCallsAPI() async {
        let song = TestFixtures.makeSong(id: "test-video")

        await self.manager.dislike(song, client: self.mockClient)

        #expect(self.manager.status(for: "test-video") == .dislike)
        #expect(self.mockClient.rateSongRatings.first == .dislike)
    }

    @Test("undislike updates cache to indifferent")
    func undislikeUpdatesCacheToIndifferent() async {
        let song = TestFixtures.makeSong(id: "test-video")
        self.manager.setStatus(.dislike, for: "test-video")

        await self.manager.undislike(song, client: self.mockClient)

        #expect(self.manager.status(for: "test-video") == .indifferent)
    }

    // MARK: - Error Handling Tests

    @Test("like reverts cache on API failure")
    func likeRevertsCacheOnFailure() async {
        let song = TestFixtures.makeSong(id: "test-video")
        self.manager.setStatus(.indifferent, for: "test-video")
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.manager.like(song, client: self.mockClient)

        // Should revert to previous status
        #expect(self.manager.status(for: "test-video") == .indifferent)
    }

    @Test("like removes cache entry on failure when no previous")
    func likeRemovesCacheOnFailureWhenNoPrevious() async {
        let song = TestFixtures.makeSong(id: "new-video")
        // No previous status set
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.manager.like(song, client: self.mockClient)

        // Should remove the entry entirely
        #expect(self.manager.status(for: "new-video") == nil)
    }

    @Test("dislike reverts cache on API failure")
    func dislikeRevertsCacheOnFailure() async {
        let song = TestFixtures.makeSong(id: "test-video")
        self.manager.setStatus(.like, for: "test-video")
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.manager.dislike(song, client: self.mockClient)

        // Should revert to previous status
        #expect(self.manager.status(for: "test-video") == .like)
    }

    // MARK: - Cache Management Tests

    @Test("setStatus updates cache")
    func setStatusUpdatesCache() {
        self.manager.setStatus(.like, for: "video-1")
        self.manager.setStatus(.dislike, for: "video-2")

        #expect(self.manager.status(for: "video-1") == .like)
        #expect(self.manager.status(for: "video-2") == .dislike)
    }

    @Test("cache is isolated by active account")
    func cacheIsIsolatedByActiveAccount() {
        self.manager.setActiveAccountID("primary")
        self.manager.setStatus(.like, for: "video-1")

        self.manager.setActiveAccountID("brand-account")
        #expect(self.manager.status(for: "video-1") == nil)

        self.manager.setStatus(.dislike, for: "video-1")
        #expect(self.manager.status(for: "video-1") == .dislike)

        self.manager.setActiveAccountID("primary")
        #expect(self.manager.status(for: "video-1") == .like)
    }

    @Test("clearCache removes all entries")
    func clearCacheRemovesAllEntries() {
        self.manager.setStatus(.like, for: "video-1")
        self.manager.setStatus(.dislike, for: "video-2")

        self.manager.clearCache()

        #expect(self.manager.status(for: "video-1") == nil)
        #expect(self.manager.status(for: "video-2") == nil)
    }
}
