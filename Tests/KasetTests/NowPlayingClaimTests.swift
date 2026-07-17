import Foundation
import Testing
@testable import Kaset

@Suite("Now playing claim", .serialized, .tags(.service))
struct NowPlayingClaimTests {
    @Test("Actively playing or starting yields hands-off (WebKit owns the card)")
    func activePlaybackIsHandsOff() {
        let track = (title: "Song", artist: "Artist")
        #expect(NowPlayingManager.desiredClaim(state: .playing, track: track) == .handsOff)
        #expect(NowPlayingManager.desiredClaim(state: .buffering, track: track) == .handsOff)
        #expect(NowPlayingManager.desiredClaim(state: .loading, track: track) == .handsOff)
    }

    @Test("Not playing with a track yields a minimal claim")
    func pausedWithTrackClaims() {
        let track = (title: "Song", artist: "Artist")
        let expected = NowPlayingManager.NowPlayingClaim.claim(title: "Song", artist: "Artist")
        #expect(NowPlayingManager.desiredClaim(state: .paused, track: track) == expected)
        #expect(NowPlayingManager.desiredClaim(state: .ended, track: track) == expected)
        #expect(NowPlayingManager.desiredClaim(state: .idle, track: track) == expected)
        #expect(NowPlayingManager.desiredClaim(state: .error("boom"), track: track) == expected)
    }

    @Test("Not playing with no track yields hands-off (nothing to resume)")
    func idleWithoutTrackIsHandsOff() {
        #expect(NowPlayingManager.desiredClaim(state: .idle, track: nil) == .handsOff)
        #expect(NowPlayingManager.desiredClaim(state: .paused, track: nil) == .handsOff)
    }
}
