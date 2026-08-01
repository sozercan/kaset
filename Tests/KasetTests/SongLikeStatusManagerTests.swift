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

    // MARK: - Liked Music Reconciliation Tests

    @Test("Overlapping Liked Music requests keep a stale unlike filtered until each finishes")
    func overlappingLikedMusicRequestsKeepStaleUnlikeFiltered() async {
        let song = TestFixtures.makeSong(id: "request-scoped-unlike")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.manager.setStatus(.like, for: song.videoId)
        self.mockClient.beforeRateSongReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let earlySnapshot = self.manager.beginLikedMusicRequest()
        let rating = self.manager.enqueueRating(
            song,
            status: .indifferent,
            client: self.mockClient
        )
        await requestStarted.wait()
        let lateSnapshot = self.manager.beginLikedMusicRequest()
        let pendingEarlyReconciliation = self.manager.reconcileLikedMusicTracks(
            [song],
            snapshot: earlySnapshot
        )
        let pendingLateReconciliation = self.manager.reconcileLikedMusicTracks(
            [song],
            snapshot: lateSnapshot
        )

        await releaseRequest.open()
        let finalStatus = await rating.value
        let settledEarlyReconciliation = self.manager.reconcileLikedMusicTracks(
            [song],
            snapshot: earlySnapshot
        )
        self.manager.finishLikedMusicRequest(earlySnapshot)
        let remainingLateReconciliation = self.manager.reconcileLikedMusicTracks(
            [song],
            snapshot: lateSnapshot
        )
        self.manager.finishLikedMusicRequest(lateSnapshot)

        let freshSnapshot = self.manager.beginLikedMusicRequest()
        let freshReconciliation = self.manager.reconcileLikedMusicTracks(
            [song],
            snapshot: freshSnapshot
        )
        self.manager.finishLikedMusicRequest(freshSnapshot)

        let filteredVideoIDs = Set([song.videoId])
        #expect(finalStatus == .indifferent)
        #expect(self.manager.hasPendingRating(for: song.videoId) == false)
        #expect(pendingEarlyReconciliation?.tracks.isEmpty == true)
        #expect(pendingEarlyReconciliation?.filteredVideoIDs == filteredVideoIDs)
        #expect(pendingLateReconciliation?.tracks.isEmpty == true)
        #expect(pendingLateReconciliation?.filteredVideoIDs == filteredVideoIDs)
        #expect(settledEarlyReconciliation?.tracks.isEmpty == true)
        #expect(settledEarlyReconciliation?.filteredVideoIDs == filteredVideoIDs)
        #expect(remainingLateReconciliation?.tracks.isEmpty == true)
        #expect(remainingLateReconciliation?.filteredVideoIDs == filteredVideoIDs)
        #expect(freshReconciliation?.tracks.map(\.videoId) == [song.videoId])
        #expect(freshReconciliation?.filteredVideoIDs.isEmpty == true)
    }

    @Test("A request begun during a pending like restores a track omitted by stale server snapshots")
    func likedMusicRequestBegunDuringPendingLikeRestoresOmittedTrack() async {
        let song = TestFixtures.makeSong(id: "request-scoped-like")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeRateSongReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let rating = self.manager.enqueueRating(
            song,
            status: .like,
            client: self.mockClient
        )
        await requestStarted.wait()
        let snapshot = self.manager.beginLikedMusicRequest()
        let pendingReconciliation = self.manager.reconcileLikedMusicTracks(
            [],
            snapshot: snapshot
        )

        await releaseRequest.open()
        let finalStatus = await rating.value
        let settledReconciliation = self.manager.reconcileLikedMusicTracks(
            [],
            snapshot: snapshot
        )
        self.manager.finishLikedMusicRequest(snapshot)

        let freshSnapshot = self.manager.beginLikedMusicRequest()
        let freshReconciliation = self.manager.reconcileLikedMusicTracks(
            [],
            snapshot: freshSnapshot
        )
        self.manager.finishLikedMusicRequest(freshSnapshot)

        #expect(finalStatus == .like)
        #expect(self.manager.hasPendingRating(for: song.videoId) == false)
        #expect(pendingReconciliation?.tracks.map(\.videoId) == [song.videoId])
        #expect(pendingReconciliation?.tracks.first?.likeStatus == .like)
        #expect(pendingReconciliation?.filteredVideoIDs.isEmpty == true)
        #expect(settledReconciliation?.tracks.map(\.videoId) == [song.videoId])
        #expect(settledReconciliation?.tracks.first?.likeStatus == .like)
        #expect(settledReconciliation?.filteredVideoIDs.isEmpty == true)
        #expect(freshReconciliation?.tracks.isEmpty == true)
        #expect(freshReconciliation?.filteredVideoIDs.isEmpty == true)
    }

    @Test("A failed re-like keeps the rollback status protected from an older request")
    func failedRelikeKeepsRollbackStatusProtectedFromOlderRequest() async {
        let song = TestFixtures.makeSong(id: "protected-re-like-rollback")
        self.manager.setStatus(.like, for: song.videoId)
        let snapshot = self.manager.beginLikedMusicRequest()

        #expect(await self.manager.unlike(song, client: self.mockClient) == .indifferent)

        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        #expect(await self.manager.like(song, client: self.mockClient) == .indifferent)

        let reconciliation = self.manager.reconcileLikedMusicTracks(
            [song],
            snapshot: snapshot
        )
        self.manager.finishLikedMusicRequest(snapshot)

        #expect(reconciliation?.tracks.isEmpty == true)
        #expect(reconciliation?.filteredVideoIDs == [song.videoId])
        #expect(self.manager.status(for: song.videoId) == .indifferent)
    }

    @Test("Queued unlike and re-like preserve the original liked membership baseline")
    func queuedUnlikeAndRelikePreserveOriginalMembershipBaseline() async {
        let song = TestFixtures.makeSong(id: "queued-membership-baseline")
        let unlikeStarted = AsyncGate()
        let releaseUnlike = AsyncGate()
        self.manager.setStatus(.like, for: song.videoId)
        let snapshot = self.manager.beginLikedMusicRequest()
        self.mockClient.beforeRateSongReturn = { _, rating in
            guard rating == .indifferent else { return }
            await unlikeStarted.open()
            await releaseUnlike.wait()
        }

        let unlike = self.manager.enqueueRating(
            song,
            status: .indifferent,
            client: self.mockClient
        )
        await unlikeStarted.wait()
        let relike = self.manager.enqueueRating(
            song,
            status: .like,
            client: self.mockClient
        )

        let reconciliation = self.manager.reconcileLikedMusicTracks(
            [],
            snapshot: snapshot
        )

        #expect(reconciliation?.tracks.map(\.videoId) == [song.videoId])
        #expect(reconciliation?.newLikedMembershipVideoIDs.isEmpty == true)

        await releaseUnlike.open()
        _ = await unlike.value
        _ = await relike.value
        self.manager.finishLikedMusicRequest(snapshot)
    }

    @Test("Multiple pending likes reconcile newest first")
    func multiplePendingLikesReconcileNewestFirst() async {
        let firstSong = TestFixtures.makeSong(id: "pending-like-first", title: "First")
        let secondSong = TestFixtures.makeSong(id: "pending-like-second", title: "Second")
        let releaseRequests = AsyncGate()
        let snapshot = self.manager.beginLikedMusicRequest()
        self.mockClient.beforeRateSongReturn = { _, _ in
            await releaseRequests.wait()
        }

        let firstRating = self.manager.enqueueRating(
            firstSong,
            status: .like,
            client: self.mockClient
        )
        let secondRating = self.manager.enqueueRating(
            secondSong,
            status: .like,
            client: self.mockClient
        )

        let reconciliation = self.manager.reconcileLikedMusicTracks(
            [],
            snapshot: snapshot
        )

        #expect(reconciliation?.tracks.map(\.videoId) == [secondSong.videoId, firstSong.videoId])

        await releaseRequests.open()
        _ = await firstRating.value
        _ = await secondRating.value
        self.manager.finishLikedMusicRequest(snapshot)
    }

    @Test("Session invalidation rejects an old Liked Music request snapshot")
    func sessionInvalidationRejectsOldLikedMusicRequestSnapshot() {
        let song = TestFixtures.makeSong(id: "invalidated-session-snapshot")
        self.manager.setStatus(.dislike, for: song.videoId)
        let snapshot = self.manager.beginLikedMusicRequest()

        self.manager.invalidateSession(clearsActiveCache: false)
        let reconciliation = self.manager.reconcileLikedMusicTracks(
            [song],
            snapshot: snapshot
        )
        self.manager.finishLikedMusicRequest(snapshot)

        #expect(self.manager.matchesCurrentScope(snapshot) == false)
        #expect(reconciliation == nil)
        #expect(self.manager.status(for: song.videoId) == .dislike)
    }

    @Test("Session invalidation rollback events retain the pending song metadata")
    func sessionInvalidationRollbackEventsRetainPendingSongMetadata() async throws {
        let song = TestFixtures.makeSong(
            id: "rollback-event-song",
            title: "Rollback Event Song"
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.manager.setStatus(.like, for: song.videoId)
        self.mockClient.beforeRateSongReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let rating = self.manager.enqueueRating(
            song,
            status: .indifferent,
            client: self.mockClient
        )
        await requestStarted.wait()

        self.manager.invalidateSession(clearsActiveCache: false)
        let event = try #require(
            self.manager.lastLikeEventBatch?.events.first { $0.videoId == song.videoId }
        )

        #expect(event.status == .like)
        #expect(event.song?.videoId == song.videoId)
        #expect(event.song?.title == song.title)

        await releaseRequest.open()
        _ = await rating.value
    }

    @Test("Session invalidation publishes rollback events in submission order")
    func sessionInvalidationPublishesRollbackEventsInSubmissionOrder() async throws {
        let firstSong = TestFixtures.makeSong(id: "rollback-order-first", title: "First")
        let secondSong = TestFixtures.makeSong(id: "rollback-order-second", title: "Second")
        let releaseRequests = AsyncGate()
        self.manager.setStatus(.like, for: firstSong.videoId)
        self.manager.setStatus(.like, for: secondSong.videoId)
        self.mockClient.beforeRateSongReturn = { _, _ in
            await releaseRequests.wait()
        }

        let firstRating = self.manager.enqueueRating(
            firstSong,
            status: .indifferent,
            client: self.mockClient
        )
        let secondRating = self.manager.enqueueRating(
            secondSong,
            status: .indifferent,
            client: self.mockClient
        )

        self.manager.invalidateSession(clearsActiveCache: false)
        let batch = try #require(self.manager.lastLikeEventBatch)

        #expect(batch.events.map(\.videoId) == [firstSong.videoId, secondSong.videoId])

        await releaseRequests.open()
        _ = await firstRating.value
        _ = await secondRating.value
    }

    @Test("Returning to an account does not revalidate its old Liked Music snapshot")
    func returningToAccountDoesNotRevalidateOldLikedMusicSnapshot() {
        let accountID = "snapshot-account"
        let song = TestFixtures.makeSong(id: "invalidated-account-snapshot")
        self.manager.setActiveAccountID(accountID)
        self.manager.setStatus(.dislike, for: song.videoId)
        let snapshot = self.manager.beginLikedMusicRequest()

        self.manager.setActiveAccountID("other-snapshot-account")
        self.manager.setActiveAccountID(accountID)
        let reconciliation = self.manager.reconcileLikedMusicTracks(
            [song],
            snapshot: snapshot
        )
        self.manager.finishLikedMusicRequest(snapshot)

        #expect(self.manager.activeAccountID == snapshot.accountID)
        #expect(self.manager.matchesCurrentScope(snapshot) == false)
        #expect(reconciliation == nil)
        #expect(self.manager.status(for: song.videoId, accountID: accountID) == .dislike)
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

    @Test("Status seeding preserves a protected optimistic overlay")
    func statusSeedingPreservesProtectedOptimisticOverlay() async {
        let song = TestFixtures.makeSong(id: "protected-status-seed")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.manager.setStatus(.like, for: song.videoId)
        let snapshot = self.manager.beginLikedMusicRequest()
        self.mockClient.beforeRateSongReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let rating = self.manager.enqueueRating(
            song,
            status: .indifferent,
            client: self.mockClient
        )
        await requestStarted.wait()

        self.manager.setStatus(.like, for: song.videoId)
        let reconciliation = self.manager.reconcileLikedMusicTracks(
            [song],
            snapshot: snapshot
        )

        #expect(self.manager.status(for: song.videoId) == .indifferent)
        #expect(reconciliation?.tracks.isEmpty == true)
        #expect(reconciliation?.filteredVideoIDs == [song.videoId])

        await releaseRequest.open()
        _ = await rating.value
        self.manager.finishLikedMusicRequest(snapshot)
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

    @Test("Same-account session invalidation preserves in-flight rating order")
    func sameAccountSessionInvalidationPreservesInFlightRatingOrder() async {
        let song = TestFixtures.makeSong(id: "same-account-invalidation-order")
        let accountID = "same-account-invalidation"
        let olderRequestStarted = AsyncGate()
        let releaseOlderRequest = AsyncGate()
        let newerRequestStarted = AsyncGate()
        self.manager.setActiveAccountID(accountID)
        self.mockClient.beforeRateSongReturn = { _, rating in
            switch rating {
            case .like:
                await olderRequestStarted.open()
                await releaseOlderRequest.wait()
            case .dislike:
                await newerRequestStarted.open()
            case .indifferent:
                break
            }
        }

        let olderRating = self.manager.enqueueRating(
            song,
            status: .like,
            accountID: accountID,
            client: self.mockClient
        )
        await olderRequestStarted.wait()

        self.manager.invalidateSession(clearsActiveCache: false)
        let newerRating = self.manager.enqueueRating(
            song,
            status: .dislike,
            accountID: accountID,
            client: self.mockClient
        )
        await Task.yield()

        #expect(self.mockClient.rateSongRatings == [.like])
        #expect(self.mockClient.appliedRateSongRatings.isEmpty)

        await releaseOlderRequest.open()
        await newerRequestStarted.wait()
        _ = await olderRating.value
        _ = await newerRating.value

        #expect(self.mockClient.rateSongRatings == [.like, .dislike])
        #expect(self.mockClient.appliedRateSongRatings == [.like, .dislike])
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
