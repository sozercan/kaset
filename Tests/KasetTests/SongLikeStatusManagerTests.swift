import Foundation
import Testing
@testable import Kaset

/// Tests for SongLikeStatusManager.
@Suite("SongLikeStatusManager", .serialized, .tags(.service))
@MainActor
struct SongLikeStatusManagerTests {
    var manager: SongLikeStatusManager
    var mockClient: MockYTMusicClient

    init() {
        // Create a fresh instance for each test (not the shared singleton)
        self.manager = SongLikeStatusManager()
        self.mockClient = MockYTMusicClient()
        self.manager.setClient(self.mockClient)
    }

    // MARK: - Status Query Tests

    @Test("status for videoId returns nil when not cached")
    func statusForVideoIdReturnsNilWhenNotCached() {
        let status = self.manager.status(for: "unknown-video")
        #expect(status == nil)
    }

    @Test("status for videoId returns cached value")
    func statusForVideoIdReturnsCached() {
        self.manager.setStatus(.like, for: "test-video")

        let status = self.manager.status(for: "test-video")

        #expect(status == .like)
    }

    @Test("status for song uses cache over song property")
    func statusForSongUsesCacheOverProperty() {
        let song = Song(
            id: "test-video",
            title: "Test",
            artists: [],
            videoId: "test-video",
            likeStatus: .dislike
        )
        self.manager.setStatus(.like, for: "test-video")

        let status = self.manager.status(for: song)

        #expect(status == .like) // Cache takes precedence
    }

    @Test("status for song falls back to song property")
    func statusForSongFallsBackToProperty() {
        let song = Song(
            id: "test-video",
            title: "Test",
            artists: [],
            videoId: "test-video",
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

        await self.manager.like(song)

        #expect(self.manager.status(for: "test-video") == .like)
        #expect(self.mockClient.rateSongCalled == true)
        #expect(self.mockClient.rateSongVideoIds.first == "test-video")
        #expect(self.mockClient.rateSongRatings.first == .like)
    }

    @Test("unlike updates cache to indifferent")
    func unlikeUpdatesCacheToIndifferent() async {
        let song = TestFixtures.makeSong(id: "test-video")
        self.manager.setStatus(.like, for: "test-video")

        await self.manager.unlike(song)

        #expect(self.manager.status(for: "test-video") == .indifferent)
        #expect(self.mockClient.rateSongRatings.first == .indifferent)
    }

    @Test("dislike updates cache and calls API")
    func dislikeUpdatesCacheAndCallsAPI() async {
        let song = TestFixtures.makeSong(id: "test-video")

        await self.manager.dislike(song)

        #expect(self.manager.status(for: "test-video") == .dislike)
        #expect(self.mockClient.rateSongRatings.first == .dislike)
    }

    @Test("undislike updates cache to indifferent")
    func undislikeUpdatesCacheToIndifferent() async {
        let song = TestFixtures.makeSong(id: "test-video")
        self.manager.setStatus(.dislike, for: "test-video")

        await self.manager.undislike(song)

        #expect(self.manager.status(for: "test-video") == .indifferent)
    }

    // MARK: - Error Handling Tests

    @Test("like reverts cache on API failure")
    func likeRevertsCacheOnFailure() async {
        let song = TestFixtures.makeSong(id: "test-video")
        self.manager.setStatus(.indifferent, for: "test-video")
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.manager.like(song)

        // Should revert to previous status
        #expect(self.manager.status(for: "test-video") == .indifferent)
    }

    @Test("like removes cache entry on failure when no previous")
    func likeRemovesCacheOnFailureWhenNoPrevious() async {
        let song = TestFixtures.makeSong(id: "new-video")
        // No previous status set
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.manager.like(song)

        // Should remove the entry entirely
        #expect(self.manager.status(for: "new-video") == nil)
    }

    @Test("dislike reverts cache on API failure")
    func dislikeRevertsCacheOnFailure() async {
        let song = TestFixtures.makeSong(id: "test-video")
        self.manager.setStatus(.like, for: "test-video")
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.manager.dislike(song)

        // Should revert to previous status
        #expect(self.manager.status(for: "test-video") == .like)
    }

    @Test("rating without client does nothing")
    func ratingWithoutClientDoesNothing() async {
        let managerWithoutClient = SongLikeStatusManager()
        let song = TestFixtures.makeSong(id: "test-video")

        await managerWithoutClient.like(song)

        // Status should not be set since there's no client
        #expect(managerWithoutClient.status(for: "test-video") == nil)
    }

    // MARK: - Cache Management Tests

    @Test("setStatus updates cache")
    func setStatusUpdatesCache() {
        self.manager.setStatus(.like, for: "video-1")
        self.manager.setStatus(.dislike, for: "video-2")

        #expect(self.manager.status(for: "video-1") == .like)
        #expect(self.manager.status(for: "video-2") == .dislike)
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
