import Foundation
import MediaPlayer
import Testing
@testable import Kaset

@Suite("Now playing claim", .serialized, .tags(.service))
struct NowPlayingClaimTests {
    @Test("Actively playing or starting yields hands-off (WebKit owns the card)")
    func activePlaybackIsHandsOff() {
        let track = (title: "Song", artist: "Artist")
        #expect(NowPlayingManager.desiredClaim(state: .playing, track: track, activeVideo: nil) == .handsOff)
        #expect(NowPlayingManager.desiredClaim(state: .buffering, track: track, activeVideo: nil) == .handsOff)
        #expect(NowPlayingManager.desiredClaim(state: .loading, track: track, activeVideo: nil) == .handsOff)
    }

    @Test("Not playing with a track yields a minimal claim")
    func pausedWithTrackClaims() {
        let track = (title: "Song", artist: "Artist")
        let expected = NowPlayingManager.NowPlayingClaim.claim(
            title: "Song",
            artist: "Artist",
            playbackState: .paused
        )
        #expect(NowPlayingManager.desiredClaim(state: .paused, track: track, activeVideo: nil) == expected)
        #expect(NowPlayingManager.desiredClaim(state: .ended, track: track, activeVideo: nil) == expected)
        #expect(NowPlayingManager.desiredClaim(state: .idle, track: track, activeVideo: nil) == expected)
        #expect(NowPlayingManager.desiredClaim(state: .error("boom"), track: track, activeVideo: nil) == expected)
    }

    @Test("Not playing with no track releases the native claim")
    func idleWithoutTrackReleasesClaim() {
        #expect(NowPlayingManager.desiredClaim(state: .idle, track: nil, activeVideo: nil) == .release)
        #expect(NowPlayingManager.desiredClaim(state: .paused, track: nil, activeVideo: nil) == .release)
    }

    @Test("Video media-key ownership uses video metadata until playback is confirmed")
    func videoOwnershipUsesFallbackClaim() {
        let track = (title: "Song", artist: "Artist")
        let video = NowPlayingManager.ActiveVideoClaim(
            title: "Video",
            artist: "Channel",
            playbackState: .paused,
            isPlaybackConfirmed: false
        )
        let expected = NowPlayingManager.NowPlayingClaim.claim(
            title: "Video",
            artist: "Channel",
            playbackState: .paused
        )

        #expect(NowPlayingManager.desiredClaim(
            state: .paused,
            track: track,
            activeVideo: video
        ) == expected)
    }

    @Test("Confirmed video playback hands the Now Playing card to WebKit")
    func playingVideoIsHandsOff() {
        let track = (title: "Song", artist: "Artist")
        let video = NowPlayingManager.ActiveVideoClaim(
            title: "Video",
            artist: "Channel",
            playbackState: .playing,
            isPlaybackConfirmed: true
        )

        #expect(NowPlayingManager.desiredClaim(
            state: .paused,
            track: track,
            activeVideo: video
        ) == .handsOff)
    }

    @Test("A loading video keeps its fallback even if the previous document was playing")
    func loadingVideoWithStalePlayingStateKeepsClaim() {
        let video = NowPlayingManager.ActiveVideoClaim(
            title: "Next Video",
            artist: "Channel",
            playbackState: .playing,
            isPlaybackConfirmed: false
        )
        let expected = NowPlayingManager.NowPlayingClaim.claim(
            title: "Next Video",
            artist: "Channel",
            playbackState: .playing
        )

        #expect(NowPlayingManager.desiredClaim(
            state: .paused,
            track: nil,
            activeVideo: video
        ) == expected)
    }

    @Test("Only tagged native metadata is treated as Kaset's claim")
    func nativeClaimOwnershipTag() {
        let nativeInfo: [String: Any] = [
            MPNowPlayingInfoPropertyServiceIdentifier: NowPlayingManager.nativeClaimServiceIdentifier,
        ]
        let webKitInfo: [String: Any] = [MPMediaItemPropertyTitle: "Song"]

        #expect(NowPlayingManager.isNativeClaim(nativeInfo))
        #expect(NowPlayingManager.isNativeClaim(webKitInfo) == false)
        #expect(NowPlayingManager.isNativeClaim(nil) == false)
    }
}
