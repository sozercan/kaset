import Foundation
import Testing
@testable import Kaset

/// Tests for PlayerService+Library extension (like/dislike/library actions).
@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceLibraryTests {
    var playerService: PlayerService
    var mockClient: MockYTMusicClient

    init() {
        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
        self.playerService.setYTMusicClient(self.mockClient)
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
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

        // Wait for the async API call
        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.rateSongCalled == true)
        #expect(self.mockClient.rateSongVideoIds.first == "test-video")
        #expect(self.mockClient.rateSongRatings.first == .like)
    }

    @Test("likeCurrentTrack toggles to indifferent when already liked")
    func likeCurrentTrackTogglesOff() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .like

        self.playerService.likeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.rateSongRatings.first == .indifferent)
    }

    @Test("likeCurrentTrack changes dislike to like")
    func likeCurrentTrackFromDislike() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .dislike

        self.playerService.likeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .like)

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.rateSongRatings.first == .like)
    }

    @Test("likeCurrentTrack reverts on API failure")
    func likeCurrentTrackRevertsOnFailure() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .indifferent
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        self.playerService.likeCurrentTrack()

        // Optimistic update should happen immediately
        #expect(self.playerService.currentTrackLikeStatus == .like)

        // Wait for SongLikeStatusManager to call API, fail, rollback, and PlayerService to sync back
        try? await Task.sleep(for: .milliseconds(300))

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)
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

    @Test("likeCurrentTrack uses captured client even if singleton client changes before task runs")
    func likeCurrentTrackUsesCapturedClient() async {
        let replacementClient = MockYTMusicClient()
        let originalClient = SongLikeStatusManager.shared.currentClient
        defer { SongLikeStatusManager.shared.setClient(originalClient) }

        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .like

        self.playerService.likeCurrentTrack()
        SongLikeStatusManager.shared.setClient(replacementClient)

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.rateSongRatings.first == .indifferent)
        #expect(replacementClient.rateSongCalled == false)
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

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.rateSongCalled == true)
        #expect(self.mockClient.rateSongRatings.first == .dislike)
    }

    @Test("dislikeCurrentTrack toggles to indifferent when already disliked")
    func dislikeCurrentTrackTogglesOff() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .dislike

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.rateSongRatings.first == .indifferent)
    }

    @Test("dislikeCurrentTrack changes like to dislike")
    func dislikeCurrentTrackFromLike() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .like

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .dislike)

        try? await Task.sleep(for: .milliseconds(200))

        #expect(self.mockClient.rateSongRatings.first == .dislike)
    }

    @Test("dislikeCurrentTrack reverts on API failure")
    func dislikeCurrentTrackRevertsOnFailure() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .indifferent
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .dislike)

        // Wait for SongLikeStatusManager to call API, fail, rollback, and PlayerService to sync back
        try? await Task.sleep(for: .milliseconds(300))

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)
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

    @Test("toggleLibraryStatus adds to library when not in library")
    func toggleLibraryStatusAddsToLibrary() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackInLibrary = false
        self.playerService.currentTrackFeedbackTokens = FeedbackTokens(add: "add-token", remove: "remove-token")

        self.playerService.toggleLibraryStatus()

        #expect(self.playerService.currentTrackInLibrary == true)

        try? await Task.sleep(for: .milliseconds(100))

        #expect(self.mockClient.editSongLibraryStatusCalled == true)
        #expect(self.mockClient.editSongLibraryStatusTokens.first?.first == "add-token")
    }

    @Test("toggleLibraryStatus removes from library when in library")
    func toggleLibraryStatusRemovesFromLibrary() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackInLibrary = true
        self.playerService.currentTrackFeedbackTokens = FeedbackTokens(add: "add-token", remove: "remove-token")

        self.playerService.toggleLibraryStatus()

        #expect(self.playerService.currentTrackInLibrary == false)

        try? await Task.sleep(for: .milliseconds(100))

        #expect(self.mockClient.editSongLibraryStatusCalled == true)
        #expect(self.mockClient.editSongLibraryStatusTokens.first?.first == "remove-token")
    }

    @Test("toggleLibraryStatus reverts on API failure")
    func toggleLibraryStatusRevertsOnFailure() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackInLibrary = false
        self.playerService.currentTrackFeedbackTokens = FeedbackTokens(add: "add-token", remove: "remove-token")
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        self.playerService.toggleLibraryStatus()

        #expect(self.playerService.currentTrackInLibrary == true)

        try? await Task.sleep(for: .milliseconds(100))

        #expect(self.playerService.currentTrackInLibrary == false)
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
        #expect(self.playerService.currentTrackFeedbackTokens == FeedbackTokens(add: "remove-token", remove: "add-token"))
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
        #expect(self.playerService.currentTrackFeedbackTokens == FeedbackTokens(add: "remove-token", remove: "add-token"))
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

    @Test("fetchSongMetadata preserves cached like status when API like status is unknown")
    func fetchSongMetadataPreservesCachedLikeStatusWhenAPILikeStatusIsUnknown() async {
        let song = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrack = song
        self.playerService.currentTrackLikeStatus = .like
        SongLikeStatusManager.shared.setStatus(.like, for: song.videoId)
        self.mockClient.songResponses[song.videoId] = Song(
            id: song.videoId,
            title: "Fetched Song",
            artists: [Artist(id: "artist-1", name: "Artist")],
            videoId: song.videoId,
            likeStatus: nil
        )

        await self.playerService.fetchSongMetadata(videoId: song.videoId)

        #expect(SongLikeStatusManager.shared.status(for: song.videoId) == .like)
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
}
