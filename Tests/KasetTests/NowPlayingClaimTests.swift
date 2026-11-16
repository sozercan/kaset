import Foundation
import MediaPlayer
import Testing
@testable import Kaset

// MARK: - NowPlayingClaimTests

@Suite("Now playing claim", .serialized, .tags(.service))
struct NowPlayingClaimTests {
    @Test("Confirmed playback publishes state only (WebKit owns the card)")
    func activePlaybackIsStateOnly() {
        #expect(NowPlayingManager.desiredClaim(
            state: .playing,
            hasTrack: true,
            activeVideo: nil
        ) == .stateOnly(.playing))
    }

    @Test("Starting playback keeps an existing claim until playback is confirmed")
    func startingPlaybackIsHandsOff() {
        for state in [PlayerService.PlaybackState.loading, .buffering] {
            #expect(NowPlayingManager.desiredClaim(
                state: state,
                hasTrack: true,
                activeVideo: nil
            ) == .handsOff)
        }
    }

    /// WebKit's card for the music page is in Control Center as soon as the page loads a track,
    /// including on a cold launch before anything has played, so a titled claim next to it shows
    /// up as a second Kaset entry (#457).
    @Test("Not playing with a track publishes state only, even before the page has played")
    func pausedWithTrackIsStateOnly() {
        for state in [PlayerService.PlaybackState.paused, .ended, .idle, .error("boom")] {
            #expect(NowPlayingManager.desiredClaim(
                state: state,
                hasTrack: true,
                activeVideo: nil
            ) == .stateOnly(.paused))
        }
    }

    @Test("Not playing with no track releases the native claim")
    func idleWithoutTrackReleasesClaim() {
        for state in [PlayerService.PlaybackState.idle, .paused] {
            #expect(NowPlayingManager.desiredClaim(
                state: state,
                hasTrack: false,
                activeVideo: nil
            ) == .release)
        }
    }

    @Test("Video media-key ownership uses video metadata until playback is confirmed")
    func videoOwnershipUsesFallbackClaim() {
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
            hasTrack: true,
            activeVideo: video
        ) == expected)
    }

    @Test("Confirmed video playback keeps the video claim without publishing a new one")
    func playingVideoIsHandsOff() {
        let video = NowPlayingManager.ActiveVideoClaim(
            title: "Video",
            artist: "Channel",
            playbackState: .playing,
            isPlaybackConfirmed: true
        )

        #expect(NowPlayingManager.desiredClaim(
            state: .paused,
            hasTrack: true,
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
            hasTrack: false,
            activeVideo: video
        ) == expected)
    }

    @Test("Confirmed playback drops the claim's metadata but keeps Kaset's playback state")
    @MainActor
    func stateOnlyDropsClaimMetadata() {
        let center = FakeNowPlayingCenter()
        var ownership = NowPlayingManager.apply(
            .claim(title: "Video", artist: "Channel", playbackState: .paused),
            to: center,
            ownership: .none
        )

        ownership = NowPlayingManager.apply(.stateOnly(.playing), to: center, ownership: ownership)

        #expect(ownership == .stateOnly)
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .playing)
    }

    @Test("A paused track publishes no metadata, before or after playing")
    @MainActor
    func stateOnlyPauseHasNoMetadata() {
        let center = FakeNowPlayingCenter()
        var ownership = NowPlayingManager.apply(.stateOnly(.paused), to: center, ownership: .none)
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .paused)

        ownership = NowPlayingManager.apply(.stateOnly(.playing), to: center, ownership: ownership)
        ownership = NowPlayingManager.apply(.stateOnly(.paused), to: center, ownership: ownership)

        #expect(ownership == .stateOnly)
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .paused)
    }

    @Test("Hands-off keeps an existing claim marked as playing")
    @MainActor
    func handsOffKeepsClaim() {
        let center = FakeNowPlayingCenter()
        var ownership = NowPlayingManager.apply(
            .claim(title: "Video", artist: "Channel", playbackState: .paused),
            to: center,
            ownership: .none
        )

        ownership = NowPlayingManager.apply(.handsOff, to: center, ownership: ownership)

        #expect(ownership == .claim)
        #expect(NowPlayingManager.isNativeClaim(center.nowPlayingInfo))
        #expect(center.playbackState == .playing)
    }

    /// A track change mid-playback passes through `.loading` while WebKit's card is up, so
    /// hands-off must not publish an entry of its own.
    @Test("Hands-off never publishes a new claim")
    @MainActor
    func handsOffDoesNotPublish() {
        let center = FakeNowPlayingCenter()

        let ownership = NowPlayingManager.apply(.handsOff, to: center, ownership: .none)

        #expect(ownership == .none)
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .unknown)
    }

    @Test("Releasing after state-only playback stops Kaset's player")
    @MainActor
    func releaseAfterStateOnlyStops() {
        let center = FakeNowPlayingCenter()
        var ownership = NowPlayingManager.apply(.stateOnly(.paused), to: center, ownership: .none)

        ownership = NowPlayingManager.apply(.release, to: center, ownership: ownership)

        #expect(ownership == .none)
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
    }

    @Test("Releasing a video claim clears its metadata and stops Kaset's player")
    @MainActor
    func releaseClearsVideoClaim() {
        let center = FakeNowPlayingCenter()
        var ownership = NowPlayingManager.apply(
            .claim(title: "Video", artist: "Channel", playbackState: .paused),
            to: center,
            ownership: .none
        )

        ownership = NowPlayingManager.apply(.release, to: center, ownership: ownership)

        #expect(ownership == .none)
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
    }

    @Test("State-only never clears metadata Kaset did not publish")
    @MainActor
    func stateOnlyLeavesForeignMetadata() {
        let center = FakeNowPlayingCenter()
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "Someone else's card"]

        _ = NowPlayingManager.apply(.stateOnly(.paused), to: center, ownership: .claim)

        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Someone else's card")
    }

    @Test("A video claim hands over to music's state only through a session")
    @MainActor
    func videoClaimHandsOverToMusic() {
        let center = FakeNowPlayingCenter()
        // A paused video publishes its claim; confirmed video playback keeps it.
        var ownership = NowPlayingManager.apply(
            .claim(title: "Video", artist: "Channel", playbackState: .paused),
            to: center,
            ownership: .none
        )
        ownership = NowPlayingManager.apply(.handsOff, to: center, ownership: ownership)
        #expect(NowPlayingManager.isNativeClaim(center.nowPlayingInfo))

        // Back to paused music: the video's metadata goes, Kaset's playback state stays.
        ownership = NowPlayingManager.apply(.stateOnly(.paused), to: center, ownership: ownership)
        #expect(ownership == .stateOnly)
        #expect(center.nowPlayingInfo == nil)

        // Loading, playing and pausing music never brings metadata back.
        for claim in [NowPlayingManager.NowPlayingClaim.handsOff, .stateOnly(.playing), .stateOnly(.paused)] {
            ownership = NowPlayingManager.apply(claim, to: center, ownership: ownership)
            #expect(ownership == .stateOnly)
            #expect(center.nowPlayingInfo == nil)
        }
        #expect(center.playbackState == .paused)

        ownership = NowPlayingManager.apply(.release, to: center, ownership: ownership)
        #expect(ownership == .none)
        #expect(center.playbackState == .stopped)
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

// MARK: - FakeNowPlayingCenter

@MainActor
private final class FakeNowPlayingCenter: NowPlayingInfoPublishing {
    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .unknown
}
