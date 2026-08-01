import Testing
@testable import Kaset

@Suite("Music playback occurrence regressions", .tags(.service))
@MainActor
struct MusicPlaybackOccurrenceRegressionTests {
    @Test("An unresolved Web identity inherits a consumed native occurrence")
    func unresolvedIdentityInheritsConsumedNativeOccurrence() throws {
        let identityPairs: [(native: String?, web: String?)] = [
            (nil, nil),
            (nil, "v1"),
            ("v1", nil),
        ]

        for identityPair in identityPairs {
            let playerService = PlayerService()
            let nativeOccurrence = playerService.beginNativeMusicPlaybackOccurrence(
                videoId: identityPair.native
            )
            #expect(playerService.claimTerminalMusicPlaybackOccurrence(nativeOccurrence))

            let webOccurrence = try #require(playerService.bindWebMusicPlaybackOccurrence(
                documentGeneration: 7,
                mediaGeneration: 1,
                nativeGeneration: nativeOccurrence.nativeGeneration,
                videoId: identityPair.web
            ))

            let didClaimWebOccurrence = playerService.claimTerminalMusicPlaybackOccurrence(
                webOccurrence
            )
            #expect(!didClaimWebOccurrence)
        }
    }

    @Test("A confirmed identity mismatch does not inherit a consumed native occurrence")
    func confirmedIdentityMismatchStartsUnconsumedWebOccurrence() throws {
        let playerService = PlayerService()
        let nativeOccurrence = playerService.beginNativeMusicPlaybackOccurrence(videoId: "v1")
        #expect(playerService.claimTerminalMusicPlaybackOccurrence(nativeOccurrence))

        let prospectiveWebOccurrence = MusicPlaybackOccurrence.web(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeOccurrence.nativeGeneration,
            videoId: "v2"
        )
        #expect(playerService.acceptsWebMusicPlaybackOccurrence(prospectiveWebOccurrence))

        let webOccurrence = try #require(playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeOccurrence.nativeGeneration,
            videoId: "v2"
        ))

        let didClaimWebOccurrence = playerService.claimTerminalMusicPlaybackOccurrence(
            webOccurrence
        )
        #expect(didClaimWebOccurrence)
    }

    @Test("Resuming a consumed Web occurrence starts a fresh native occurrence")
    func resumeConsumedWebOccurrenceStartsNativeReplay() async throws {
        let playerService = PlayerService()
        let song = Song(
            id: "1",
            title: "Song 1",
            artists: [],
            album: nil,
            duration: 10,
            thumbnailURL: nil,
            videoId: "v1"
        )
        playerService.currentTrack = song
        playerService.pendingPlayVideoId = song.videoId
        playerService.duration = 10
        playerService.state = .ended
        let nativeOccurrence = playerService.beginNativeMusicPlaybackOccurrence(videoId: "v1")
        let webOccurrence = try #require(playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeOccurrence.nativeGeneration,
            videoId: "v1"
        ))
        #expect(playerService.claimTerminalMusicPlaybackOccurrence(webOccurrence))

        await playerService.resume()

        let replayOccurrence = try #require(playerService.currentMusicPlaybackOccurrence)
        #expect(replayOccurrence.documentGeneration == nil)
        #expect(replayOccurrence.nativeGeneration > webOccurrence.nativeGeneration)
        #expect(playerService.state == .loading)
        #expect(playerService.progress == 0)

        let reboundWebOccurrence = try #require(playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: replayOccurrence.nativeGeneration,
            videoId: "v1"
        ))
        #expect(playerService.acceptsWebMusicPlaybackOccurrence(reboundWebOccurrence))
        #expect(playerService.claimTerminalMusicPlaybackOccurrence(reboundWebOccurrence))
    }

    @Test("A terminal event older than the current Web occurrence is rejected")
    func staleTerminalEventOlderThanCurrentOccurrenceIsRejected() throws {
        let playerService = PlayerService()
        let nativeOccurrence = playerService.beginNativeMusicPlaybackOccurrence(videoId: "v1")
        let staleOccurrence = try #require(playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeOccurrence.nativeGeneration,
            videoId: "v1"
        ))
        let currentOccurrence = try #require(playerService.bindWebMusicPlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 2,
            nativeGeneration: nativeOccurrence.nativeGeneration,
            videoId: "v1"
        ))

        let didClaimStaleOccurrence = playerService.claimTerminalMusicPlaybackOccurrence(
            staleOccurrence
        )

        #expect(!didClaimStaleOccurrence)
        #expect(playerService.currentMusicPlaybackOccurrence == currentOccurrence)
    }

    @Test("Stopped playback cannot resurrect a consumed occurrence without media")
    func stoppedPlaybackDoesNotResurrectConsumedOccurrence() async {
        let playerService = PlayerService()
        let occurrence = playerService.beginNativeMusicPlaybackOccurrence(videoId: "v1")
        #expect(playerService.claimTerminalMusicPlaybackOccurrence(occurrence))

        await playerService.stop()
        await playerService.playPause()

        #expect(playerService.state == .idle)
        #expect(playerService.currentTrack == nil)
        #expect(playerService.pendingPlayVideoId == nil)
        #expect(playerService.currentMusicPlaybackOccurrence == nil)
    }
}
