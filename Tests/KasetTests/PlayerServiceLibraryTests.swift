import Foundation
import Testing
@testable import Kaset

/// Tests for PlayerService+Library extension (like/dislike/library actions).
@Suite("PlayerService+Library", .serialized, .tags(.service))
@MainActor
struct PlayerServiceLibraryTests {
    var playerService: PlayerService
    var mockClient: MockYTMusicClient

    init() {
        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
        self.playerService.setYTMusicClient(self.mockClient)
    }

    // MARK: - Like Current Track Tests

    @Test("likeCurrentTrack does nothing when no current track")
    func likeCurrentTrackNoTrack() async {
        #expect(self.playerService.currentTrack == nil)

        self.playerService.likeCurrentTrack()

        // Allow time for any async task to complete
        try? await Task.sleep(for: .milliseconds(50))

        #expect(self.mockClient.rateSongCalled == false)
    }

    @Test("likeCurrentTrack sets status to like when indifferent")
    func likeCurrentTrackSetsLike() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .indifferent

        self.playerService.likeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .like)

        // Wait for the async API call
        try? await Task.sleep(for: .milliseconds(50))

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

        try? await Task.sleep(for: .milliseconds(50))

        #expect(self.mockClient.rateSongRatings.first == .indifferent)
    }

    @Test("likeCurrentTrack changes dislike to like")
    func likeCurrentTrackFromDislike() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .dislike

        self.playerService.likeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .like)

        try? await Task.sleep(for: .milliseconds(50))

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

        // Wait for the async API call to fail and revert
        try? await Task.sleep(for: .milliseconds(100))

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)
    }

    // MARK: - Dislike Current Track Tests

    @Test("dislikeCurrentTrack does nothing when no current track")
    func dislikeCurrentTrackNoTrack() async {
        #expect(self.playerService.currentTrack == nil)

        self.playerService.dislikeCurrentTrack()

        try? await Task.sleep(for: .milliseconds(50))

        #expect(self.mockClient.rateSongCalled == false)
    }

    @Test("dislikeCurrentTrack sets status to dislike when indifferent")
    func dislikeCurrentTrackSetsDislike() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .indifferent

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .dislike)

        try? await Task.sleep(for: .milliseconds(50))

        #expect(self.mockClient.rateSongCalled == true)
        #expect(self.mockClient.rateSongRatings.first == .dislike)
    }

    @Test("dislikeCurrentTrack toggles to indifferent when already disliked")
    func dislikeCurrentTrackTogglesOff() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .dislike

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)

        try? await Task.sleep(for: .milliseconds(50))

        #expect(self.mockClient.rateSongRatings.first == .indifferent)
    }

    @Test("dislikeCurrentTrack changes like to dislike")
    func dislikeCurrentTrackFromLike() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .like

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .dislike)

        try? await Task.sleep(for: .milliseconds(50))

        #expect(self.mockClient.rateSongRatings.first == .dislike)
    }

    @Test("dislikeCurrentTrack reverts on API failure")
    func dislikeCurrentTrackRevertsOnFailure() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackLikeStatus = .indifferent
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        self.playerService.dislikeCurrentTrack()

        #expect(self.playerService.currentTrackLikeStatus == .dislike)

        try? await Task.sleep(for: .milliseconds(100))

        #expect(self.playerService.currentTrackLikeStatus == .indifferent)
    }

    // MARK: - Toggle Library Status Tests

    @Test("toggleLibraryStatus does nothing when no current track")
    func toggleLibraryStatusNoTrack() async {
        #expect(self.playerService.currentTrack == nil)

        self.playerService.toggleLibraryStatus()

        try? await Task.sleep(for: .milliseconds(50))

        #expect(self.mockClient.editSongLibraryStatusCalled == false)
    }

    @Test("toggleLibraryStatus does nothing when no feedback token")
    func toggleLibraryStatusNoToken() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "test-video")
        self.playerService.currentTrackFeedbackTokens = nil

        self.playerService.toggleLibraryStatus()

        try? await Task.sleep(for: .milliseconds(50))

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
