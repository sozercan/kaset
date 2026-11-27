import Foundation
import Testing
@testable import Kaset

@Suite("Player service route-change pause", .serialized, .tags(.service))
@MainActor
struct PlayerServiceRouteChangePauseTests {
    @Test("A user pause records a standing intent to stay paused")
    func userPauseHoldsPauseIntent() async {
        let playerService = self.makePlayingService()

        await playerService.pause(intent: playerService.currentMusicPlaybackIntent)

        #expect(playerService.state == .paused)
        #expect(playerService.isExplicitPauseIntentActive)
        #expect(playerService.shouldResumeAfterInterruption == false)
    }

    @Test("A route-change pause stops playback without claiming the user wants it paused")
    func routeChangePauseKeepsResumeIntent() async {
        let playerService = self.makePlayingService()

        await playerService.pause(
            intent: playerService.currentMusicPlaybackIntent,
            origin: .routeLoss(at: .now)
        )

        #expect(playerService.state == .paused)
        #expect(playerService.isExplicitPauseIntentActive == false)
        #expect(playerService.shouldResumeAfterInterruption)
    }

    @Test("After a route-change pause the page resuming is adopted, not undone")
    func resumeAfterRouteChangePauseSurvives() async {
        let playerService = self.makePlayingService()
        await playerService.pause(
            intent: playerService.currentMusicPlaybackIntent,
            origin: .routeLoss(at: .now)
        )

        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 137,
            duration: 300,
            observedVideoId: "route-change"
        )

        #expect(playerService.state == .playing)
    }

    @Test("After a user pause the page resuming is still refused")
    func resumeAfterUserPauseIsStillRefused() async {
        let playerService = self.makePlayingService()
        await playerService.pause(intent: playerService.currentMusicPlaybackIntent)

        playerService.updatePlaybackState(
            isPlaying: true,
            progress: 137,
            duration: 300,
            observedVideoId: "route-change"
        )

        #expect(playerService.state == .paused)
    }

    @Test("A returning route resumes what the route loss stopped")
    func routeRestoredResumes() async {
        let playerService = self.makeRouteLossPausedService(routeReturned: true)

        await playerService.resumeAfterRouteRestored()

        #expect(playerService.isAwaitingPlaybackConfirmation)
    }

    @Test("The recovery marker survives an unconfirmed resume so the retry can act")
    func markerSurvivesUntilPlaybackConfirms() async {
        let playerService = self.makeRouteLossPausedService(routeReturned: true)

        await playerService.resumeAfterRouteRestored()
        #expect(playerService.routeLossPauseAt != nil)

        playerService.confirmPlaybackStarted()
        #expect(playerService.routeLossPauseAt == nil)
    }

    @Test("The disconnect's own reconciliation does not resume")
    func disconnectDoesNotResumeItself() async {
        let playerService = self.makeRouteLossPausedService(routeReturned: false)

        await playerService.resumeAfterRouteRestored()

        #expect(playerService.isAwaitingPlaybackConfirmation == false)
        #expect(playerService.state == .paused)
    }

    @Test("A user pause is never resumed by a returning route")
    func userPauseIsNotResumed() async {
        let playerService = self.makeRouteLossPausedService(routeReturned: true)
        await playerService.pause(intent: playerService.currentMusicPlaybackIntent)

        await playerService.resumeAfterRouteRestored()

        #expect(playerService.isAwaitingPlaybackConfirmation == false)
        #expect(playerService.state == .paused)
    }

    @Test("A pause that beat the route event is re-attributed once it lands")
    func lateRouteEventReattributesThePause() async {
        let playerService = self.makePlayingService()
        let admittedAt = ContinuousClock.now
        await playerService.pause(
            intent: playerService.currentMusicPlaybackIntent,
            origin: .unattributedRemote(admittedAt: admittedAt)
        )
        #expect(playerService.isExplicitPauseIntentActive)

        playerService.reattributeRemotePauseToRouteLoss { $0 == admittedAt }

        #expect(playerService.isExplicitPauseIntentActive == false)
        #expect(playerService.shouldResumeAfterInterruption)
        #expect(playerService.routeLossPauseAt == admittedAt)
    }

    @Test("A pause no route loss explains keeps its user semantics")
    func unclaimedPauseStaysDeliberate() async {
        let playerService = self.makePlayingService()
        await playerService.pause(
            intent: playerService.currentMusicPlaybackIntent,
            origin: .unattributedRemote(admittedAt: .now)
        )

        playerService.reattributeRemotePauseToRouteLoss { _ in false }

        #expect(playerService.isExplicitPauseIntentActive)
        #expect(playerService.routeLossPauseAt == nil)
    }

    @Test("A late route event does not undo a pause the user already made")
    func lateRouteEventKeepsAnEarlierUserPause() async {
        let playerService = self.makePlayingService()
        await playerService.pause(intent: playerService.currentMusicPlaybackIntent)
        let admittedAt = ContinuousClock.now
        await playerService.pause(
            intent: playerService.currentMusicPlaybackIntent,
            origin: .unattributedRemote(admittedAt: admittedAt)
        )

        playerService.reattributeRemotePauseToRouteLoss { $0 == admittedAt }
        playerService.hasAudioRouteReturned = { _ in true }
        await playerService.resumeAfterRouteRestored()

        #expect(playerService.isExplicitPauseIntentActive)
        #expect(playerService.shouldResumeAfterInterruption == false)
        #expect(playerService.routeLossPauseAt == nil)
        #expect(playerService.isAwaitingPlaybackConfirmation == false)
        #expect(playerService.state == .paused)
    }

    @Test("A route-loss pause on playback that was already stopped does not arm recovery")
    func routeLossWhileAlreadyPausedDoesNotResume() async {
        let playerService = self.makePlayingService()
        playerService.state = .paused

        await playerService.pause(
            intent: playerService.currentMusicPlaybackIntent,
            origin: .routeLoss(at: .now)
        )
        playerService.hasAudioRouteReturned = { _ in true }
        await playerService.resumeAfterRouteRestored()

        #expect(playerService.routeLossPauseAt == nil)
        #expect(playerService.isAwaitingPlaybackConfirmation == false)
        #expect(playerService.state == .paused)
    }

    @Test("A late route event does not arm recovery for playback that was already stopped")
    func lateRouteEventWhileAlreadyPausedDoesNotResume() async {
        let playerService = self.makePlayingService()
        playerService.state = .paused
        let admittedAt = ContinuousClock.now
        await playerService.pause(
            intent: playerService.currentMusicPlaybackIntent,
            origin: .unattributedRemote(admittedAt: admittedAt)
        )

        playerService.reattributeRemotePauseToRouteLoss { $0 == admittedAt }
        playerService.hasAudioRouteReturned = { _ in true }
        await playerService.resumeAfterRouteRestored()

        #expect(playerService.unattributedRemotePauseAt == nil)
        #expect(playerService.routeLossPauseAt == nil)
        #expect(playerService.isAwaitingPlaybackConfirmation == false)
        #expect(playerService.state == .paused)
    }

    @Test("A paused clock restoration retires a pending remote-pause attribution")
    func pausedRestorationRetiresUnattributedPause() async {
        let playerService = self.makePlayingService()
        let admittedAt = ContinuousClock.now
        await playerService.pause(
            intent: playerService.currentMusicPlaybackIntent,
            origin: .unattributedRemote(admittedAt: admittedAt)
        )

        playerService.beginPlaybackClockRestoration(
            MusicPlaybackRestoreClock(progress: 30, duration: 300),
            songDuration: 300,
            startsPaused: true
        )
        playerService.reattributeRemotePauseToRouteLoss { $0 == admittedAt }
        playerService.hasAudioRouteReturned = { _ in true }
        await playerService.resumeAfterRouteRestored()

        #expect(playerService.isExplicitPauseIntentActive)
        #expect(playerService.routeLossPauseAt == nil)
        #expect(playerService.isAwaitingPlaybackConfirmation == false)
        #expect(playerService.state == .paused)
    }

    @Test("A stale remote pause refused at admission leaves the disappearance for the next pause")
    func refusedPauseDoesNotConsumeTheDisappearance() async {
        let playerService = self.makePlayingService()
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000
        var isDisappearanceUnclaimed = true
        playerService.claimsRouteLossPause = { _ in
            defer { isDisappearanceUnclaimed = false }
            return isDisappearanceUnclaimed
        }
        let admittedAt = ContinuousClock.now

        playerService.enqueueRemoteMusicTransportCommand(.pause(admittedAt: admittedAt), issuedAtMilliseconds: 999)
        #expect(playerService.remoteMusicTransportTask == nil)
        #expect(isDisappearanceUnclaimed)

        playerService.enqueueRemoteMusicTransportCommand(.pause(admittedAt: admittedAt), issuedAtMilliseconds: 1001)
        await playerService.remoteMusicTransportTask?.value

        #expect(playerService.state == .paused)
        #expect(playerService.routeLossPauseAt == admittedAt)
        #expect(playerService.isExplicitPauseIntentActive == false)
    }

    @Test("A remote pause discarded by a newer intent does not consume the disappearance")
    func discardedPauseDoesNotConsumeTheDisappearance() async {
        let playerService = self.makePlayingService()
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000
        var claimCount = 0
        playerService.claimsRouteLossPause = { _ in
            claimCount += 1
            return true
        }

        playerService.enqueueRemoteMusicTransportCommand(.pause(admittedAt: .now), issuedAtMilliseconds: 1001)
        let remoteTask = playerService.remoteMusicTransportTask
        playerService.beginMusicPlaybackIntent()
        await remoteTask?.value

        #expect(claimCount == 0)
        #expect(playerService.state == .playing)
    }

    @Test("A remote pause queued before route recovery reaches the player instead of being discarded")
    func queuedPauseWinsOverRouteRecovery() async {
        let playerService = self.makeRouteLossPausedService(routeReturned: true)
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000
        playerService.claimsRouteLossPause = { _ in false }

        playerService.enqueueRemoteMusicTransportCommand(.pause(admittedAt: .now), issuedAtMilliseconds: 1001)
        await playerService.resumeAfterRouteRestored()

        #expect(playerService.isExplicitPauseIntentActive)
        #expect(playerService.routeLossPauseAt == nil)
        #expect(playerService.isAwaitingPlaybackConfirmation == false)
        #expect(playerService.state == .paused)
    }

    @Test("A remote pause captured while recovery waits on queued commands still reaches the player")
    func pauseCapturedDuringRecoveryWaitWins() async {
        let playerService = self.makeRouteLossPausedService(routeReturned: true)
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000
        playerService.claimsRouteLossPause = { _ in false }
        playerService.enqueueRemoteMusicTransportCommand(.absoluteSeek(position: 30), issuedAtMilliseconds: 1001)

        var drainCount = 0
        await playerService.resumeAfterRouteRestored {
            drainCount += 1
            guard drainCount == 2 else { return }
            playerService.enqueueRemoteMusicTransportCommand(.pause(admittedAt: .now), issuedAtMilliseconds: 1002)
        }

        #expect(drainCount >= 2)
        #expect(playerService.isExplicitPauseIntentActive)
        #expect(playerService.isAwaitingPlaybackConfirmation == false)
        #expect(playerService.state == .paused)
    }

    @Test("Starting other playback retires recovery for what the route loss interrupted")
    func newPlaybackRetiresRouteRecovery() async {
        SingletonPlayerWebView.shared.currentVideoId = nil
        let playerService = self.makeRouteLossPausedService(routeReturned: true)
        playerService.setYTMusicClient(MockYTMusicClient())

        await playerService.play(song: Song(id: "next", title: "next", artists: [], duration: 200, videoId: "next"))

        #expect(playerService.routeLossPauseAt == nil)
        #expect(playerService.currentTrack?.videoId == "next")
    }

    private func makeRouteLossPausedService(routeReturned: Bool) -> PlayerService {
        let playerService = self.makePlayingService()
        playerService.hasAudioRouteReturned = { _ in routeReturned }
        playerService.state = .paused
        playerService.routeLossPauseAt = .now
        return playerService
    }

    private func makePlayingService() -> PlayerService {
        let playerService = PlayerService()
        playerService.currentTrack = Song(
            id: "route-change",
            title: "route-change",
            artists: [],
            duration: 300,
            videoId: "route-change"
        )
        playerService.state = .playing
        playerService.shouldResumeAfterInterruption = true
        playerService.isExplicitPauseIntentActive = false
        return playerService
    }
}
