import Foundation
import MediaPlayer
import Testing
@testable import Kaset

// MARK: - NowPlayingClaimTests

@Suite("Now playing claim", .serialized, .tags(.service))
@MainActor
struct NowPlayingClaimTests {
    @Test("Started playback yields hands-off (WebKit owns the card)")
    func activePlaybackIsHandsOff() {
        // `buffering` is a stall inside playback that already started, so it belongs with
        // `playing`: re-claiming mid-track would recreate the competing second entry.
        let track = (title: "Song", artist: "Artist")
        #expect(NowPlayingManager.desiredClaim(state: .playing, track: track, activeVideo: nil) == .handsOff)
        #expect(NowPlayingManager.desiredClaim(state: .buffering, track: track, activeVideo: nil) == .handsOff)
    }

    @Test("A starting track keeps a playing claim until WebKit publishes its card")
    func startingPlaybackKeepsClaimUntilHandover() {
        // Withdrawing during the load would leave the app with no Now Playing entry, and
        // therefore no media keys, for as long as the track takes to start.
        let track = (title: "Song", artist: "Artist")
        let expected = NowPlayingManager.NowPlayingClaim.claim(
            title: "Song",
            artist: "Artist",
            playbackState: .playing
        )
        #expect(NowPlayingManager.desiredClaim(state: .loading, track: track, activeVideo: nil) == expected)
        #expect(NowPlayingManager.desiredClaim(state: .loading, track: nil, activeVideo: nil) == .release)
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

    @Test("Hands-off and release both withdraw Kaset's entry so only one card can exist")
    func nonClaimDecisionsWithdrawTheEntry() {
        // WebKit registers a separate Now Playing client rather than overwriting
        // `MPNowPlayingInfoCenter.default()`, so a claim kept during playback survives as a
        // second entry for the same app and can capture the media keys with a stale state.
        // Both non-claim decisions must therefore map onto the same withdrawal.
        let track = (title: "Song", artist: "Artist")
        let playingClaim = NowPlayingManager.desiredClaim(state: .playing, track: track, activeVideo: nil)
        let emptyClaim = NowPlayingManager.desiredClaim(state: .idle, track: nil, activeVideo: nil)

        #expect(playingClaim == .handsOff)
        #expect(emptyClaim == .release)
        for claim in [playingClaim, emptyClaim] {
            switch claim {
            case .handsOff, .release:
                break
            case .claim:
                Issue.record("Playback and empty states must not publish a native claim")
            }
        }
    }

    @Test("Handing the card to WebKit withdraws our entry")
    func handsOffClearsOwnedMetadata() {
        // The central fix: the hands-off branch used to wait for WebKit to replace the app-wide
        // metadata, which never happens, leaving a second permanently stale Control Center entry.
        let center = MockNowPlayingInfoCenter()
        NowPlayingManager.applyClaim(
            .claim(title: "Song", artist: "Artist", playbackState: .paused),
            isAssertingNativeClaim: false,
            to: center
        )
        #expect(NowPlayingManager.isNativeClaim(center.nowPlayingInfo))

        let stillAsserting = NowPlayingManager.applyClaim(
            .handsOff,
            isAssertingNativeClaim: true,
            to: center
        )

        #expect(stillAsserting == false)
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
    }

    @Test("Releasing with nothing to play withdraws our entry too")
    func releaseClearsOwnedMetadata() {
        let center = MockNowPlayingInfoCenter()
        NowPlayingManager.applyClaim(
            .claim(title: "Song", artist: "Artist", playbackState: .paused),
            isAssertingNativeClaim: false,
            to: center
        )

        NowPlayingManager.applyClaim(.release, isAssertingNativeClaim: true, to: center)

        #expect(center.nowPlayingInfo == nil)
    }

    @Test("A card we do not own is never cleared")
    func withdrawalLeavesForeignMetadataAlone() {
        // WebKit publishes through its own client, but anything landing in the shared center
        // that lacks our tag must survive a withdrawal untouched.
        let center = MockNowPlayingInfoCenter()
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "Someone else's card"]
        center.playbackState = .playing

        NowPlayingManager.applyClaim(.handsOff, isAssertingNativeClaim: true, to: center)

        #expect(center.nowPlayingInfo?.isEmpty == false)
        #expect(center.playbackState == .playing)
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

// MARK: - MockNowPlayingInfoCenter

@MainActor
final class MockNowPlayingInfoCenter: NowPlayingInfoCenter {
    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .unknown
}
