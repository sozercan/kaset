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
        self.manager = SongLikeStatusManager()
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

    @Test("Optimistic cache observers cannot replace the confirmed rollback baseline")
    func optimisticCacheWritePreservesConfirmedRollback() async {
        let song = TestFixtures.makeSong(id: "optimistic-observer-rollback")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.manager.setStatus(.indifferent, for: song.videoId)
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        self.mockClient.beforeRateSongReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let likeTask = Task { @MainActor in
            await self.manager.like(song, client: self.mockClient)
        }
        await requestStarted.wait()
        self.manager.setCachedStatus(.like, for: song.videoId)
        await releaseRequest.open()

        #expect(await likeTask.value == .indifferent)
        #expect(self.manager.status(for: song.videoId) == .indifferent)
    }

    @Test("A delayed rating completion cannot overwrite a newer rating")
    func latestRatingCompletionWins() async {
        let song = TestFixtures.makeSong(id: "latest-rating-manager")
        let accountID = "latest-rating-account"
        self.manager.setActiveAccountID(accountID)
        self.mockClient.rateSongDelay = .milliseconds(200)
        let likeTask = Task { @MainActor in
            await self.manager.like(
                song,
                accountID: accountID,
                client: self.mockClient
            )
        }
        try? await Task.sleep(for: .milliseconds(25))
        self.mockClient.rateSongDelay = nil

        let dislikeStatus = await self.manager.dislike(
            song,
            accountID: accountID,
            client: self.mockClient
        )
        let lateLikeStatus = await likeTask.value

        #expect(dislikeStatus == .dislike)
        #expect(lateLikeStatus == .dislike)
        #expect(self.manager.status(for: song.videoId, accountID: accountID) == .dislike)
        #expect(self.mockClient.appliedRateSongRatings.last == .dislike)
    }

    @Test("A stale successful rating cannot seed rollback state after session invalidation")
    func staleSuccessfulRatingCannotSeedRollbackAfterSessionInvalidation() async {
        let song = TestFixtures.makeSong(id: "stale-rating-session")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeRateSongReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let staleLike = Task { @MainActor in
            await self.manager.like(song, client: self.mockClient)
        }
        await requestStarted.wait()
        self.manager.invalidateSession()
        #expect(self.manager.status(for: song.videoId) == nil)

        await releaseRequest.open()
        _ = await staleLike.value
        self.mockClient.beforeRateSongReturn = nil
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )

        let finalStatus = await self.manager.dislike(song, client: self.mockClient)

        #expect(finalStatus == .indifferent)
        #expect(self.manager.status(for: song.videoId) == nil)
    }

    @Test("Overlapping failed ratings roll back to the confirmed baseline")
    func overlappingRatingFailuresRestoreConfirmedState() async {
        let song = TestFixtures.makeSong(id: "failed-rating-chain")
        self.mockClient.rateSongDelay = .milliseconds(200)
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        let likeTask = Task { @MainActor in
            await self.manager.like(song, client: self.mockClient)
        }
        try? await Task.sleep(for: .milliseconds(25))
        self.mockClient.rateSongDelay = nil
        let dislikeStatus = await self.manager.dislike(song, client: self.mockClient)
        let likeStatus = await likeTask.value

        #expect(dislikeStatus == .indifferent)
        #expect(likeStatus == .dislike || likeStatus == .indifferent)
        #expect(self.manager.status(for: song.videoId) == nil)
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

    @Test("bulk setStatus updates cache for active account")
    func bulkSetStatusUpdatesCacheForActiveAccount() {
        let videoIds = ["bulk-video-1", "bulk-video-2", "bulk-video-3"]

        self.manager.setStatus(.like, for: videoIds)

        for videoId in videoIds {
            #expect(self.manager.status(for: videoId) == .like)
        }
    }

    @Test("bulk setStatus respects active account scope")
    func bulkSetStatusRespectsActiveAccountScope() {
        let videoIds = ["bulk-scoped-video-1", "bulk-scoped-video-2"]

        self.manager.setActiveAccountID("brand-account")
        self.manager.setStatus(.like, for: videoIds)

        for videoId in videoIds {
            #expect(self.manager.status(for: videoId) == .like)
            #expect(self.manager.status(for: videoId, accountID: "primary") == nil)
        }
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
