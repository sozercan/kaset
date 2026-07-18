// swiftlint:disable file_length

import Foundation
import Testing
@testable import Kaset

/// Tests for PlayerService+Library extension (like/dislike/library actions).
@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceLibraryTests { // swiftlint:disable:this type_body_length
    var playerService: PlayerService
    var mockClient: MockYTMusicClient
    var authService: AuthService

    init() {
        self.mockClient = MockYTMusicClient()
        self.authService = AuthService(webKitManager: MockWebKitManager())
        self.authService.completeLogin(sapisid: "REDACTED")
        self.playerService = PlayerService()
        let likeStatusManager = SongLikeStatusManager()
        likeStatusManager.setActiveAccountID(nil)
        self.playerService.setSongLikeStatusManager(likeStatusManager)
        self.playerService.setYTMusicClient(self.mockClient)
        self.playerService.setAuthService(self.authService)
    }

    // MARK: - Like Current Track Tests

    @Test("likeCurrentTrack does nothing when no current track")
    func likeCurrentTrackNoTrack() async {
        #expect(self.playerService.currentTrack == nil)

        self.playerService.likeCurrentTrack()

        // Allow time for any async task to complete
        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.rateSongCalled == false)
    }

    @Test("likeCurrentTrack sets status to like when indifferent")
    func likeCurrentTrackSetsLike() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .indifferent

        self.playerService.likeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .like)

        let didCallAPI = await self.waitUntilRateSongCalled()

        #expect(didCallAPI)
        #expect(self.mockClient.rateSongVideoIds.first == "test-video")
        #expect(self.mockClient.rateSongRatings.first == .like)
    }

    @Test("likeCurrentTrack toggles to indifferent when already liked")
    func likeCurrentTrackTogglesOff() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .like

        self.playerService.likeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)

        let didCallAPI = await self.waitUntilRateSongCallCount(1)

        #expect(didCallAPI)
        #expect(self.mockClient.rateSongRatings.first == .indifferent)
    }

    @Test("likeCurrentTrack changes dislike to like")
    func likeCurrentTrackFromDislike() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .dislike

        self.playerService.likeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .like)

        let didCallAPI = await self.waitUntilRateSongCallCount(1)

        #expect(didCallAPI)
        #expect(self.mockClient.rateSongRatings.first == .like)
    }

    @Test("likeCurrentTrack reverts on API failure")
    func likeCurrentTrackRevertsOnFailure() async {
        let accountID = "like-failure-\(UUID().uuidString)"
        self.playerService.songLikeStatusManager.setActiveAccountID(accountID)
        defer { self.playerService.songLikeStatusManager.setActiveAccountID(nil) }
        self.playerService.currentTrack = TestFixtures.makeSong(id: "like-failure-video-\(UUID().uuidString)")
        self.playerService.currentTrackLikeStatus = .indifferent
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        self.playerService.likeCurrentTrack()

        // Optimistic update should happen immediately
        #expect(self.playerService.currentTrackLikeStatus == .like)

        // Wait for SongLikeStatusManager to call API, fail, rollback, and PlayerService to sync back.
        let reverted = await self.waitUntilLikeStatus(.indifferent)
        #expect(reverted)
    }

    @Test("likeCurrentTrack rolls back to visible status when manager cache is stale")
    func likeCurrentTrackRollsBackToVisibleStatusWhenManagerCacheIsStale() async {
        let accountID = "stale-like-cache-\(UUID().uuidString)"
        self.playerService.songLikeStatusManager.setActiveAccountID(accountID)
        defer { self.playerService.songLikeStatusManager.setActiveAccountID(nil) }
        let song = TestFixtures.makeSong(id: "stale-like-cache-video")
        self.playerService.currentTrack = song
        self.playerService.currentTrackLikeStatus = .indifferent
        self.playerService.songLikeStatusManager.setCachedStatus(.like, for: song.videoId)
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        self.playerService.likeCurrentTrack()
        #expect(self.playerService.currentTrackLikeStatus == .like)

        let reverted = await self.waitUntilLikeStatus(.indifferent)
        #expect(reverted)
    }

    @Test("likeCurrentTrack ignores stale completion after current track changes")
    func likeCurrentTrackIgnoresStaleCompletionAfterTrackChange() async {
        self.mockClient.rateSongDelay = .milliseconds(200)
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-a")
        self.playerService.currentTrackLikeStatus = .indifferent

        self.playerService.likeCurrentTrack()
        #expect(self.playerService.currentTrackLikeStatus == .like)

        try? await Task.sleep(for: .milliseconds(50))
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-b")
        self.playerService.currentTrackLikeStatus = .indifferent

        try? await Task.sleep(for: .milliseconds(250))

        #expect(self.playerService.currentTrack?.videoId == "song-b")
        #expect(self.playerService.currentTrackLikeStatus == .indifferent)
    }

    @Test("A delayed like completion cannot overwrite a newer dislike")
    func latestRatingOperationWins() async {
        let song = TestFixtures.makeSong(id: "latest-rating")
        self.playerService.currentTrack = song
        self.playerService.currentTrackLikeStatus = .indifferent
        self.mockClient.rateSongDelay = .milliseconds(200)

        self.playerService.likeCurrentTrack()
        try? await Task.sleep(for: .milliseconds(25))
        self.mockClient.rateSongDelay = nil
        self.playerService.dislikeCurrentTrack()
        _ = await self.waitUntilRateSongCallCount(2)

        #expect(self.playerService.currentTrackLikeStatus == .dislike)
        #expect(self.mockClient.rateSongRatings == [.like, .dislike])
    }

    @Test("Stale metadata cannot overwrite a newer rating")
    func staleMetadataPreservesNewerRating() async {
        let song = TestFixtures.makeSong(id: "metadata-rating")
        self.playerService.currentTrack = song
        self.playerService.currentTrackLikeStatus = .indifferent
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        self.mockClient.songResponses[song.videoId] = Song(
            id: song.id,
            title: song.title,
            artists: song.artists,
            videoId: song.videoId,
            likeStatus: .indifferent
        )
        self.mockClient.beforeGetSongReturn = { _ in
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        let metadataTask = Task { @MainActor in
            await self.playerService.fetchSongMetadata(videoId: song.videoId, queueOwner: .none)
        }
        await metadataStarted.wait()
        self.playerService.likeCurrentTrack()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while !self.mockClient.rateSongCalled, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await releaseMetadata.open()
        await metadataTask.value

        #expect(self.playerService.currentTrackLikeStatus == .like)
    }

    @Test("likeCurrentTrack uses captured client even if singleton client changes before task runs")
    func likeCurrentTrackUsesCapturedClient() async {
        let replacementClient = MockYTMusicClient()
        let originalClient = self.playerService.songLikeStatusManager.currentClient
        defer { self.playerService.songLikeStatusManager.setClient(originalClient) }

        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .like

        self.playerService.likeCurrentTrack()
        self.playerService.songLikeStatusManager.setClient(replacementClient)

        let didCallAPI = await self.waitUntilRateSongCallCount(1)

        #expect(didCallAPI)
        #expect(self.mockClient.rateSongRatings.first == .indifferent)
        #expect(replacementClient.rateSongCalled == false)
    }

    @Test("likeCurrentTrack clears optimistic status when active account changes before completion")
    func likeCurrentTrackClearsOptimisticStatusWhenActiveAccountChangesBeforeCompletion() async {
        self.mockClient.rateSongDelay = .milliseconds(50)
        let originalAccountID = "account-switch-original-\(UUID().uuidString)"
        let switchedAccountID = "account-switch-new-\(UUID().uuidString)"
        self.playerService.songLikeStatusManager.setActiveAccountID(originalAccountID)
        defer { self.playerService.songLikeStatusManager.setActiveAccountID(nil) }
        var song = TestFixtures.makeSong(id: "account-switch-video")
        song.likeStatus = .like
        self.playerService.currentTrack = song
        self.playerService.currentTrackLikeStatus = .indifferent

        self.playerService.likeCurrentTrack()
        #expect(self.playerService.currentTrackLikeStatus == .like)

        self.playerService.songLikeStatusManager.setActiveAccountID(switchedAccountID)

        let reverted = await self.waitUntilLikeStatus(.indifferent)
        #expect(reverted)
    }

    @Test("likeCurrentTrack is ignored while signed out")
    func likeCurrentTrackIgnoredWhenSignedOut() async {
        let authService = AuthService(webKitManager: MockWebKitManager())
        await authService.checkLoginStatus()
        self.playerService.setAuthService(authService)
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .indifferent

        self.playerService.likeCurrentTrack()

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)
        #expect(self.mockClient.rateSongCalled == false)
    }

    // MARK: - Dislike Current Track Tests

    @Test("dislikeCurrentTrack does nothing when no current track")
    func dislikeCurrentTrackNoTrack() async {
        #expect(self.playerService.currentTrack == nil)

        self.playerService.dislikeCurrentTrack()

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.rateSongCalled == false)
    }

    @Test("dislikeCurrentTrack sets status to dislike when indifferent")
    func dislikeCurrentTrackSetsDislike() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .indifferent

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .dislike)

        let didCallAPI = await self.waitUntilRateSongCallCount(1)

        #expect(didCallAPI)
        #expect(self.mockClient.rateSongRatings.first == .dislike)
    }

    @Test("dislikeCurrentTrack toggles to indifferent when already disliked")
    func dislikeCurrentTrackTogglesOff() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .dislike

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)

        let didCallAPI = await self.waitUntilRateSongCallCount(1)

        #expect(didCallAPI)
        #expect(self.mockClient.rateSongRatings.first == .indifferent)
    }

    @Test("dislikeCurrentTrack changes like to dislike")
    func dislikeCurrentTrackFromLike() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .like

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .dislike)

        let didCallAPI = await self.waitUntilRateSongCallCount(1)

        #expect(didCallAPI)
        #expect(self.mockClient.rateSongRatings.first == .dislike)
    }

    @Test("dislikeCurrentTrack reverts on API failure")
    func dislikeCurrentTrackRevertsOnFailure() async {
        let accountID = "dislike-failure-\(UUID().uuidString)"
        self.playerService.songLikeStatusManager.setActiveAccountID(accountID)
        defer { self.playerService.songLikeStatusManager.setActiveAccountID(nil) }
        self.playerService.currentTrack = TestFixtures.makeSong(id: "dislike-failure-video-\(UUID().uuidString)")
        self.playerService.currentTrackLikeStatus = .indifferent
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .dislike)

        // Wait for SongLikeStatusManager to call API, fail, rollback, and PlayerService to sync back.
        let reverted = await self.waitUntilLikeStatus(.indifferent)
        #expect(reverted)
    }

    @Test("dislikeCurrentTrack ignores stale completion after current track changes")
    func dislikeCurrentTrackIgnoresStaleCompletionAfterTrackChange() async {
        self.mockClient.rateSongDelay = .milliseconds(200)
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-a")
        self.playerService.currentTrackLikeStatus = .indifferent

        self.playerService.dislikeCurrentTrack()
        #expect(self.playerService.currentTrackLikeStatus == .dislike)

        try? await Task.sleep(for: .milliseconds(50))
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-b")
        self.playerService.currentTrackLikeStatus = .indifferent

        try? await Task.sleep(for: .milliseconds(250))

        #expect(self.playerService.currentTrack?.videoId == "song-b")
        #expect(self.playerService.currentTrackLikeStatus == .indifferent)
    }

    @Test("dislikeCurrentTrack is ignored while signed out")
    func dislikeCurrentTrackIgnoredWhenSignedOut() async {
        let authService = AuthService(webKitManager: MockWebKitManager())
        await authService.checkLoginStatus()
        self.playerService.setAuthService(authService)
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .indifferent

        self.playerService.dislikeCurrentTrack()

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)
        #expect(self.mockClient.rateSongCalled == false)
    }

    // MARK: - Toggle Library Status Tests

    @Test("toggleLibraryStatus does nothing when no current track")
    func toggleLibraryStatusNoTrack() async {
        #expect(self.playerService.currentTrack == nil)

        self.playerService.toggleLibraryStatus()

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.editSongLibraryStatusCalled == false)
    }

    @Test("toggleLibraryStatus does nothing when no feedback token")
    func toggleLibraryStatusNoToken() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackFeedbackTokens = nil

        self.playerService.toggleLibraryStatus()

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.editSongLibraryStatusCalled == false)
    }

    @Test("toggleLibraryStatus is ignored while signed out")
    func toggleLibraryStatusIgnoredWhenSignedOut() async {
        let authService = AuthService(webKitManager: MockWebKitManager())
        await authService.checkLoginStatus()
        self.playerService.setAuthService(authService)
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackInLibrary = false
        let feedback = FeedbackTokens(add: "add-token", remove: "remove-token")
        self.playerService[keyPath: \.currentTrackFeedbackTokens] = feedback

        self.playerService.toggleLibraryStatus()

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.playerService.currentTrackInLibrary == false)
        #expect(self.mockClient.editSongLibraryStatusCalled == false)
    }

    @Test("toggleLibraryStatus adds to library when not in library")
    func toggleLibraryStatusAddsToLibrary() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackInLibrary = false
        self.playerService.currentTrackFeedbackTokens = FeedbackTokens(add: "add-token", remove: "remove-token")

        self.playerService.toggleLibraryStatus()

        #expect(self.playerService.currentTrackInLibrary == true)

        let didCallAPI = await self.waitUntilLibraryEditCallCount(1)

        #expect(didCallAPI)
        #expect(self.mockClient.editSongLibraryStatusTokens.first?.first == "add-token")
    }

    @Test("toggleLibraryStatus removes from library when in library")
    func toggleLibraryStatusRemovesFromLibrary() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackInLibrary = true
        self.playerService.currentTrackFeedbackTokens = FeedbackTokens(add: "add-token", remove: "remove-token")

        self.playerService.toggleLibraryStatus()

        #expect(self.playerService.currentTrackInLibrary == false)

        let didCallAPI = await self.waitUntilLibraryEditCallCount(1)

        #expect(didCallAPI)
        #expect(self.mockClient.editSongLibraryStatusTokens.first?.first == "remove-token")
    }

    @Test("Library toggle updates the complete owning queue entry")
    func libraryToggleUpdatesOwningQueueEntry() async {
        let song = Song(
            id: "queue-library",
            title: "Queue Library",
            artists: [Artist(id: "artist", name: "Artist")],
            thumbnailURL: URL(string: "https://example.com/art.jpg"),
            videoId: "queue-library",
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "add-token", remove: "remove-token")
        )
        await self.playerService.playQueue([song], startingAt: 0)

        self.playerService.toggleLibraryStatus()

        #expect(self.playerService.queue[0].isInLibrary == true)
        #expect(self.playerService.queue[0].feedbackTokens == FeedbackTokens(
            add: "add-token",
            remove: "remove-token"
        ))
    }

    @Test("Library state stays synchronized across duplicate video occurrences")
    func libraryStateSynchronizesAcrossDuplicateOccurrences() async {
        let oldTokens = FeedbackTokens(add: "duplicate-old-add", remove: "duplicate-old-remove")
        let authoritativeTokens = FeedbackTokens(add: "duplicate-new-add", remove: "duplicate-new-remove")
        let first = Song(
            id: "duplicate-first",
            title: "First Duplicate",
            artists: [],
            videoId: "duplicate-library-video",
            isInLibrary: false,
            feedbackTokens: oldTokens
        )
        let second = Song(
            id: "duplicate-second",
            title: "Second Duplicate",
            artists: [],
            videoId: "duplicate-library-video",
            isInLibrary: false,
            feedbackTokens: oldTokens
        )
        self.mockClient.songResponses[first.videoId] = Song(
            id: first.id,
            title: first.title,
            artists: first.artists,
            videoId: first.videoId,
            isInLibrary: true,
            feedbackTokens: authoritativeTokens
        )
        await self.playerService.playQueue([first, second], startingAt: 0)

        await self.playerService.fetchSongMetadata(videoId: first.videoId)

        #expect(self.playerService.queue.allSatisfy { $0.isInLibrary == true })
        #expect(self.playerService.queue.allSatisfy { $0.feedbackTokens == authoritativeTokens })
        let metadataCallCount = self.mockClient.getSongVideoIds.count
        await self.playerService.playFromQueue(at: 1)
        #expect(self.mockClient.getSongVideoIds.count == metadataCallCount)
        #expect(self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == authoritativeTokens)

        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeEditSongLibraryStatusReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        self.playerService.toggleLibraryStatus()
        await requestStarted.wait()
        #expect(self.playerService.queue.allSatisfy { $0.isInLibrary == false })

        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        await releaseRequest.open()
        for _ in 0 ..< 100 where !self.playerService.currentTrackInLibrary {
            await Task.yield()
        }

        #expect(self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == authoritativeTokens)
        #expect(self.playerService.queue.allSatisfy { $0.isInLibrary == true })
        #expect(self.playerService.queue.allSatisfy { $0.feedbackTokens == authoritativeTokens })
    }

    @Test("A delayed library toggle cannot overwrite a newer toggle")
    func latestLibraryToggleWins() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "latest-library")
        self.playerService.currentTrackInLibrary = false
        self.playerService.currentTrackFeedbackTokens = FeedbackTokens(
            add: "add-token",
            remove: "remove-token"
        )
        self.mockClient.editSongLibraryStatusResponseDelays = [
            .milliseconds(200),
            .zero,
        ]

        self.playerService.toggleLibraryStatus()
        self.playerService.toggleLibraryStatus()
        let mutationKey = self.playerService.songLikeStatusManager.activeAccountID
            + "\u{0}latest-library"
        let latestRevision = self.playerService.libraryMutationRevisionCounter
        #expect(self.playerService.libraryMutationTailGenerations[mutationKey] == latestRevision)
        #expect(self.playerService.libraryMutationTails[mutationKey] != nil)

        let didFinish = await self.waitUntil {
            self.mockClient.editSongLibraryStatusTokens.count == 2
                && self.playerService.libraryMutationTails[mutationKey] == nil
                && !self.playerService.currentTrackInLibrary
        }

        #expect(didFinish)
        #expect(!self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrack?.isInLibrary == false)
        #expect(self.mockClient.editSongLibraryStatusTokens.count == 2)
    }

    @Test("Overlapping failed library toggles restore the confirmed baseline")
    func overlappingLibraryFailuresRestoreConfirmedState() async {
        let originalTokens = FeedbackTokens(add: "add-token", remove: "remove-token")
        self.playerService.currentTrack = Song(
            id: "failed-library-chain",
            title: "Failed Library Chain",
            artists: [],
            videoId: "failed-library-chain",
            isInLibrary: false,
            feedbackTokens: originalTokens
        )
        self.playerService.currentTrackInLibrary = false
        self.playerService.currentTrackFeedbackTokens = originalTokens
        self.mockClient.editSongLibraryStatusResponseDelays = [.milliseconds(200), .zero]
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )

        self.playerService.toggleLibraryStatus()
        self.playerService.toggleLibraryStatus()
        try? await Task.sleep(for: .milliseconds(350))

        #expect(!self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == originalTokens)
        #expect(self.playerService.currentTrack?.isInLibrary == false)
    }

    @Test("toggleLibraryStatus reverts on API failure")
    func toggleLibraryStatusRevertsOnFailure() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackInLibrary = false
        self.playerService.currentTrackFeedbackTokens = FeedbackTokens(add: "add-token", remove: "remove-token")
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        self.playerService.toggleLibraryStatus()

        #expect(self.playerService.currentTrackInLibrary == true)

        let didRevert = await self.waitUntil {
            self.playerService.currentTrackInLibrary == false
        }

        #expect(didRevert)
        #expect(self.playerService.currentTrackInLibrary == false)
    }

    @Test("Failed library mutation restores its original queue entry after track change")
    func failedLibraryMutationRestoresOriginalQueueEntry() async {
        let first = Song(
            id: "rollback-first",
            title: "First",
            artists: [],
            videoId: "rollback-first",
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "add-token", remove: "remove-token")
        )
        let second = TestFixtures.makeSong(id: "rollback-second")
        await self.playerService.playQueue([first, second], startingAt: 0)
        let firstEntryID = self.playerService.queueEntryIDs[0]
        self.mockClient.editSongLibraryStatusResponseDelays = [.milliseconds(200)]
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )

        self.playerService.toggleLibraryStatus()
        await self.playerService.playFromQueue(at: 1)
        let didRestore = await self.waitUntil {
            self.playerService.queueEntries.first(where: { $0.id == firstEntryID })?.song.isInLibrary == false
                && self.playerService.queueEntries.first(where: { $0.id == firstEntryID })?.song.feedbackTokens == first.feedbackTokens
        }

        let restoredEntry = self.playerService.queueEntries.first(where: { $0.id == firstEntryID })
        #expect(didRestore)
        #expect(restoredEntry?.song.isInLibrary == false)
        #expect(restoredEntry?.song.feedbackTokens == first.feedbackTokens)
        #expect(self.playerService.currentTrack?.videoId == second.videoId)
    }

    @Test("A stale library completion cannot repopulate confirmed state after an identity switch")
    func staleLibraryCompletionCannotRepopulateConfirmedStateAfterIdentitySwitch() async {
        let song = Song(
            id: "stale-library-session",
            title: "Stale Library Session",
            artists: [Artist(id: "artist", name: "Artist")],
            videoId: "stale-library-session",
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "old-add-token", remove: "old-remove-token")
        )
        self.playerService.currentTrack = song
        self.playerService.currentTrackInLibrary = false
        self.playerService.currentTrackFeedbackTokens = song.feedbackTokens
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeEditSongLibraryStatusReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        self.playerService.toggleLibraryStatus()
        await requestStarted.wait()
        #expect(!self.playerService.confirmedLibraryStateByKey.isEmpty)

        self.playerService.reloadCurrentTrackForIdentitySwitch()
        #expect(self.playerService.confirmedLibraryStateByKey.isEmpty)
        await releaseRequest.open()
        for _ in 0 ..< 20 where self.mockClient.appliedEditSongLibraryStatusTokens.isEmpty {
            await Task.yield()
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(self.mockClient.appliedEditSongLibraryStatusTokens == [["old-add-token"]])
        #expect(self.playerService.confirmedLibraryStateByKey.isEmpty)
    }

    @Test("Metadata cannot replace rollback state while a library mutation is pending")
    func metadataCannotReplacePendingLibraryMutationBaseline() async {
        let originalTokens = FeedbackTokens(add: "fresh-add", remove: "fresh-remove")
        let optimisticTokens = originalTokens
        let staleTokens = FeedbackTokens(add: "stale-add", remove: "stale-remove")
        let song = Song(
            id: "pending-library-metadata",
            title: "Pending Library Metadata",
            artists: [Artist(id: "artist", name: "Artist")],
            videoId: "pending-library-metadata",
            isInLibrary: true,
            feedbackTokens: originalTokens
        )
        await self.playerService.playQueue([song], startingAt: 0)
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeEditSongLibraryStatusReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        self.mockClient.songResponses[song.videoId] = Song(
            id: song.id,
            title: song.title,
            artists: song.artists,
            videoId: song.videoId,
            isInLibrary: false,
            feedbackTokens: staleTokens
        )

        self.playerService.toggleLibraryStatus()
        await requestStarted.wait()
        #expect(!self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == optimisticTokens)

        await self.playerService.fetchSongMetadata(videoId: song.videoId)
        #expect(!self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == optimisticTokens)
        #expect(self.playerService.queue[0].feedbackTokens == optimisticTokens)

        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        await releaseRequest.open()
        for _ in 0 ..< 100 where !self.playerService.currentTrackInLibrary {
            await Task.yield()
        }

        #expect(self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == originalTokens)
        #expect(self.playerService.queue[0].isInLibrary == true)
        #expect(self.playerService.queue[0].feedbackTokens == originalTokens)
    }

    @Test("Successful library refresh preserves server tokens and rollback baseline")
    func successfulLibraryRefreshPreservesServerTokensAndRollbackBaseline() async {
        let song = Song(
            id: "rotated-library-token",
            title: "Rotated Library Token",
            artists: [Artist(id: "artist", name: "Artist")],
            videoId: "rotated-library-token",
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "old-add", remove: "old-remove")
        )
        let serverTokens = FeedbackTokens(add: "server-add-v2", remove: "server-remove-v2")
        self.mockClient.songResponses[song.videoId] = Song(
            id: song.id,
            title: song.title,
            artists: song.artists,
            videoId: song.videoId,
            isInLibrary: true,
            feedbackTokens: serverTokens
        )
        await self.playerService.playQueue([song], startingAt: 0)
        let refreshStarted = AsyncGate()
        let releaseRefresh = AsyncGate()
        self.mockClient.beforeGetSongReturn = { _ in
            await refreshStarted.open()
            await releaseRefresh.wait()
        }

        self.playerService.toggleLibraryStatus()
        await refreshStarted.wait()
        await releaseRefresh.open()
        for _ in 0 ..< 100 where self.playerService.currentTrackFeedbackTokens != serverTokens {
            await Task.yield()
        }

        let mutationKey = self.playerService.songLikeStatusManager.activeAccountID
            + "\u{0}" + song.videoId
        #expect(self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == serverTokens)
        #expect(self.playerService.currentTrack?.feedbackTokens == serverTokens)
        #expect(self.playerService.queue[0].feedbackTokens == serverTokens)
        #expect(self.playerService.confirmedLibraryStateByKey[mutationKey] == MusicLibraryConfirmedState(
            isInLibrary: true,
            feedbackTokens: serverTokens
        ))

        self.mockClient.beforeGetSongReturn = nil
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        self.playerService.toggleLibraryStatus()
        let didSubmitRemoval = await self.waitUntilLibraryEditCallCount(2)
        for _ in 0 ..< 100 where !self.playerService.currentTrackInLibrary {
            await Task.yield()
        }

        #expect(didSubmitRemoval)
        #expect(self.mockClient.editSongLibraryStatusTokens.last == ["server-remove-v2"])
        #expect(self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == serverTokens)
        #expect(self.playerService.queue[0].feedbackTokens == serverTokens)
    }

    @Test("toggleLibraryStatus preserves optimistic add when metadata refresh is stale")
    func toggleLibraryStatusPreservesOptimisticAddWhenMetadataIsStale() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackInLibrary = false
        self.playerService.currentTrackFeedbackTokens = FeedbackTokens(add: "add-token", remove: "remove-token")
        self.mockClient.songResponses["test-video"] = Song(
            id: "test-video",
            title: "Stale Song",
            artists: [Artist(id: "artist", name: "Artist")],
            videoId: "test-video",
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "add-token", remove: "remove-token")
        )

        self.playerService.toggleLibraryStatus()

        #expect(self.playerService.currentTrackInLibrary == true)

        try? await Task.sleep(for: .milliseconds(650))

        #expect(self.playerService.currentTrackInLibrary == true)
        #expect(self.playerService.currentTrack?.isInLibrary == true)
        #expect(self.playerService.currentTrackFeedbackTokens == FeedbackTokens(add: "add-token", remove: "remove-token"))
    }

    @Test("toggleLibraryStatus preserves optimistic removal when metadata refresh is stale")
    func toggleLibraryStatusPreservesOptimisticRemovalWhenMetadataIsStale() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackInLibrary = true
        self.playerService.currentTrackFeedbackTokens = FeedbackTokens(add: "add-token", remove: "remove-token")
        self.mockClient.songResponses["test-video"] = Song(
            id: "test-video",
            title: "Stale Song",
            artists: [Artist(id: "artist", name: "Artist")],
            videoId: "test-video",
            isInLibrary: true,
            feedbackTokens: FeedbackTokens(add: "add-token", remove: "remove-token")
        )

        self.playerService.toggleLibraryStatus()

        #expect(self.playerService.currentTrackInLibrary == false)

        try? await Task.sleep(for: .milliseconds(650))

        #expect(self.playerService.currentTrackInLibrary == false)
        #expect(self.playerService.currentTrack?.isInLibrary == false)
        #expect(self.playerService.currentTrackFeedbackTokens == FeedbackTokens(add: "add-token", remove: "remove-token"))
    }

    @Test("A stale account owner cannot create a captured queue playlist")
    func staleAccountOwnerCannotCreateCapturedQueuePlaylist() async {
        let songs = [TestFixtures.makeSong(id: "stale-playlist-owner")]
        let owner = self.playerService.currentAccountMutationOwner
        self.playerService.songLikeStatusManager.setActiveAccountID("brand-account")

        await #expect(throws: CancellationError.self) {
            _ = try await self.playerService.saveQueueAsPlaylist(
                title: "Stale Snapshot",
                songs: songs,
                owner: owner
            )
        }

        #expect(self.mockClient.createPlaylistCalls.isEmpty)
    }

    @Test("An account switch during playlist reconciliation removes the stale optimistic playlist")
    func accountSwitchDuringPlaylistReconciliationRemovesOptimisticPlaylist() async {
        let libraryViewModel = LibraryViewModel(client: self.mockClient)
        let songs = [TestFixtures.makeSong(id: "reconcile-account-switch")]
        let owner = self.playerService.currentAccountMutationOwner
        self.mockClient.shouldWaitForLibraryContentResponse = true

        var saveTask: Task<Playlist, any Error>!
        await withCheckedContinuation { continuation in
            self.mockClient.onGetLibraryContent = {
                self.mockClient.onGetLibraryContent = nil
                continuation.resume()
            }
            saveTask = Task { @MainActor in
                try await self.playerService.saveQueueAsPlaylist(
                    title: "Old Account Playlist",
                    songs: songs,
                    owner: owner
                )
            }
        }

        #expect(libraryViewModel.isInLibrary(playlistId: "PLCREATED"))
        self.playerService.songLikeStatusManager.setActiveAccountID("brand-account")
        self.mockClient.shouldWaitForLibraryContentResponse = false
        self.mockClient.resumeNextLibraryContentResponse()

        await #expect(throws: CancellationError.self) {
            _ = try await saveTask.value
        }
        #expect(!libraryViewModel.isInLibrary(playlistId: "PLCREATED"))
        #expect(!libraryViewModel.playlists.contains { $0.id == "PLCREATED" })
    }

    // MARK: - Update Like Status Tests

    @Test("updateLikeStatus updates status")
    func updateLikeStatus() {
        #expect(self.playerService.currentTrackLikeStatus == .indifferent)

        self.playerService.updateLikeStatus(.like)
        #expect(self.playerService.currentTrackLikeStatus == .like)

        self.playerService.updateLikeStatus(.dislike)
        #expect(self.playerService.currentTrackLikeStatus == .dislike)

        self.playerService.updateLikeStatus(.indifferent)
        #expect(self.playerService.currentTrackLikeStatus == .indifferent)
    }

    @Test("Account metadata refresh updates a complete owning queue entry")
    func metadataRefreshUpdatesCompleteQueueAccountFields() async {
        let song = Song(
            id: "account-metadata",
            title: "Complete",
            artists: [Artist(id: "artist", name: "Artist")],
            thumbnailURL: URL(string: "https://example.com/complete.jpg"),
            videoId: "account-metadata",
            likeStatus: .like,
            isInLibrary: true,
            feedbackTokens: FeedbackTokens(add: "old-add", remove: "old-remove")
        )
        self.mockClient.songResponses[song.videoId] = Song(
            id: song.id,
            title: song.title,
            artists: song.artists,
            thumbnailURL: song.thumbnailURL,
            videoId: song.videoId,
            likeStatus: .dislike,
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "new-add", remove: "new-remove")
        )
        await self.playerService.playQueue([song], startingAt: 0)

        await self.playerService.fetchSongMetadata(videoId: song.videoId)

        #expect(self.playerService.queue[0].likeStatus == .dislike)
        #expect(self.playerService.queue[0].isInLibrary == false)
        #expect(self.playerService.queue[0].feedbackTokens == FeedbackTokens(
            add: "new-add",
            remove: "new-remove"
        ))
    }

    @Test("fetchSongMetadata preserves cached like status when API like status is unknown")
    func fetchSongMetadataPreservesCachedLikeStatusWhenAPILikeStatusIsUnknown() async {
        let song = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrack = song
        self.playerService.currentTrackLikeStatus = .like
        self.playerService.songLikeStatusManager.setStatus(.like, for: song.videoId)
        self.mockClient.songResponses[song.videoId] = Song(
            id: song.videoId,
            title: "Fetched Song",
            artists: [Artist(id: "artist-1", name: "Artist")],
            videoId: song.videoId,
            likeStatus: nil
        )

        await self.playerService.fetchSongMetadata(videoId: song.videoId)

        #expect(self.playerService.songLikeStatusManager.status(for: song.videoId) == .like)
        #expect(self.playerService.currentTrackLikeStatus == .like)
        #expect(self.playerService.currentTrack?.likeStatus == .like)
    }

    // MARK: - Reset Track Status Tests

    @Test("resetTrackStatus resets all status properties")
    func resetTrackStatus() {
        self.playerService.currentTrackLikeStatus = .like
        self.playerService.currentTrackInLibrary = true
        self.playerService.currentTrackFeedbackTokens = FeedbackTokens(add: "add", remove: "remove")

        self.playerService.resetTrackStatus()

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)
        #expect(self.playerService.currentTrackInLibrary == false)
        #expect(self.playerService.currentTrackFeedbackTokens == nil)
    }

    @Test("A failed newer rating rolls back to a successful predecessor")
    func failedNewerRatingRollsBackToSuccessfulPredecessor() async {
        let song = TestFixtures.makeSong(id: "rating-success-then-failure")
        let failure = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        self.playerService.currentTrack = song
        self.playerService.currentTrackLikeStatus = .indifferent
        self.mockClient.rateSongDelay = .milliseconds(150)
        self.mockClient.rateSongErrors = [nil, failure]

        self.playerService.likeCurrentTrack()
        let didStartLike = await self.waitUntilRateSongCallCount(1)
        #expect(didStartLike)

        self.mockClient.rateSongDelay = nil
        self.playerService.dislikeCurrentTrack()
        let didAttemptDislike = await self.waitUntilRateSongCallCount(2)
        #expect(didAttemptDislike)
        let didRollbackToLike = await self.waitUntilLikeStatus(.like)
        #expect(didRollbackToLike)
        #expect(self.mockClient.appliedRateSongRatings == [.like])
    }

    @Test("A failed newer library toggle rolls back to a successful predecessor")
    func failedNewerLibraryToggleRollsBackToSuccessfulPredecessor() async {
        let failure = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        let tokens = FeedbackTokens(add: "add-token", remove: "remove-token")
        let song = Song(
            id: "library-success-then-failure",
            title: "Library Success Then Failure",
            artists: [],
            videoId: "library-success-then-failure",
            isInLibrary: false,
            feedbackTokens: tokens
        )
        self.playerService.currentTrack = song
        self.playerService.currentTrackInLibrary = false
        self.playerService.currentTrackFeedbackTokens = tokens
        self.mockClient.editSongLibraryStatusResponseDelays = [.milliseconds(150), .zero]
        self.mockClient.editSongLibraryStatusErrors = [nil, failure]

        self.playerService.toggleLibraryStatus()
        let didStartAdd = await self.waitUntilLibraryEditCallCount(1)
        #expect(didStartAdd)

        self.playerService.toggleLibraryStatus()
        let didAttemptRemove = await self.waitUntilLibraryEditCallCount(2)
        #expect(didAttemptRemove)
        let didRollbackToAdded = await self.waitUntil {
            self.playerService.currentTrackInLibrary
        }
        #expect(didRollbackToAdded)
        #expect(self.playerService.currentTrackFeedbackTokens == tokens)
        #expect(self.mockClient.appliedEditSongLibraryStatusTokens == [["add-token"]])
    }

    @Test("Rapid rating submissions preserve user action order")
    func rapidRatingSubmissionsPreserveOrder() async {
        let song = TestFixtures.makeSong(id: "rapid-rating-order")
        self.playerService.currentTrack = song
        self.playerService.currentTrackLikeStatus = .indifferent

        self.playerService.likeCurrentTrack()
        self.playerService.dislikeCurrentTrack()

        let didSubmitBoth = await self.waitUntilRateSongCallCount(2)
        #expect(didSubmitBoth)
        let didApplyBoth = await self.waitUntil {
            self.mockClient.appliedRateSongRatings.count == 2
        }
        #expect(didApplyBoth)
        let didSettle = await self.waitUntilLikeStatus(.dislike)
        #expect(didSettle)
        #expect(self.mockClient.rateSongRatings == [.like, .dislike])
        #expect(self.mockClient.appliedRateSongRatings == [.like, .dislike])
    }

    @Test("Rapid rating failures preserve the API-confirmed baseline")
    func rapidRatingFailuresPreserveConfirmedBaseline() async {
        let song = TestFixtures.makeSong(id: "rapid-rating-baseline")
        self.playerService.currentTrack = song
        self.playerService.currentTrackLikeStatus = .indifferent
        self.mockClient.rateSongDelay = .milliseconds(200)
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )

        self.playerService.likeCurrentTrack()
        let didStartLike = await self.waitUntilRateSongCallCount(1)
        #expect(didStartLike)

        self.mockClient.rateSongDelay = nil
        self.playerService.dislikeCurrentTrack()
        let didAttemptDislike = await self.waitUntilRateSongCallCount(2)
        #expect(didAttemptDislike)
        let didRollback = await self.waitUntilLikeStatus(.indifferent)
        #expect(didRollback)
    }

    @Test("Rapid add/remove uses the action token for each requested state")
    func rapidLibraryToggleUsesDistinctActionTokens() async {
        let song = Song(
            id: "rapid-library-token",
            title: "Rapid Library Token",
            artists: [],
            videoId: "rapid-library-token",
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "add-token", remove: "remove-token")
        )
        self.playerService.currentTrack = song
        self.playerService.currentTrackInLibrary = false
        self.playerService.currentTrackFeedbackTokens = song.feedbackTokens

        self.playerService.toggleLibraryStatus()
        self.playerService.toggleLibraryStatus()

        let didCallTwice = await self.waitUntilLibraryEditCallCount(2)
        #expect(didCallTwice)
        #expect(self.mockClient.editSongLibraryStatusTokens == [
            ["add-token"],
            ["remove-token"],
        ])
    }

    private func waitUntil(
        attempts: Int = 1000,
        pollInterval: Duration = .milliseconds(10),
        condition: () -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if condition() {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    private func waitUntilRateSongCallCount(
        _ expectedCount: Int,
        attempts: Int = 1000,
        pollInterval: Duration = .milliseconds(10)
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if self.mockClient.rateSongRatings.count >= expectedCount {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    private func waitUntilLibraryEditCallCount(
        _ expectedCount: Int,
        attempts: Int = 1000,
        pollInterval: Duration = .milliseconds(10)
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if self.mockClient.editSongLibraryStatusTokens.count >= expectedCount {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    private func waitUntilRateSongCalled(
        attempts: Int = 1000,
        pollInterval: Duration = .milliseconds(10)
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if self.mockClient.rateSongCalled {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    private func waitUntilLikeStatus(
        _ expectedStatus: LikeStatus,
        attempts: Int = 1000,
        pollInterval: Duration = .milliseconds(10)
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if self.playerService.currentTrackLikeStatus == expectedStatus {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }
}
