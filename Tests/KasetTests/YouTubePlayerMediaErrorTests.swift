import Testing
@testable import Kaset

@Suite("YouTube media-error recovery", .serialized, .tags(.service))
@MainActor
struct YouTubePlayerMediaErrorTests {
    private let controller: MockYouTubeWatchPlaybackController
    private let sut: YouTubePlayerService

    init() {
        self.controller = MockYouTubeWatchPlaybackController()
        self.sut = YouTubePlayerService(playbackController: self.controller)
    }

    @Test("A media error clears loading even when media never becomes ready")
    func mediaErrorClearsNeverReadyLoading() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            hasMediaError: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))

        #expect(!self.sut.isPlaybackLoading)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "abc")

        self.sut.resume()
        #expect(self.controller.reloadedVideoIds == ["abc"])
    }

    @Test("An active-document media error recovers before video identity is available")
    func unboundMediaErrorDefersCurrentVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            hasMediaError: true
        ))

        #expect(!self.sut.isPlaybackLoading)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "abc")

        self.sut.resume()
        #expect(self.controller.reloadedVideoIds == ["abc"])
    }

    @Test("A stale outgoing media error does not defer the newly reported video")
    func staleOutgoingMediaErrorDoesNotDeferNewVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))

        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            hasMediaError: true,
            videoId: "b",
            boundVideoId: "a"
        ))

        #expect(self.sut.currentVideo?.videoId == "b")
        #expect(self.sut.pendingPausedIdentityReloadVideoId == nil)
        #expect(self.sut.isPlaybackLoading)
    }

    @Test("An incoming media error follows and defers the incoming video")
    func incomingMediaErrorDefersIncomingVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))

        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            hasMediaError: true,
            videoId: "b",
            boundVideoId: "b"
        ))

        #expect(self.sut.currentVideo?.videoId == "b")
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "b")
        #expect(!self.sut.isPlaybackLoading)

        self.sut.resume()
        #expect(self.controller.reloadedVideoIds == ["b"])
    }

    @Test("An advertisement media error does not defer the content video")
    func advertisementMediaErrorDoesNotDeferContentVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            hasMediaError: true,
            videoId: "abc",
            boundVideoId: "abc",
            isAd: true
        ))

        #expect(self.sut.currentVideo?.videoId == "abc")
        #expect(self.sut.pendingPausedIdentityReloadVideoId == nil)
        #expect(self.sut.isPlaybackLoading)
    }
}
