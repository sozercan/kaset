import Foundation
import Testing
@testable import Kaset

/// Losing an audio route (Bluetooth disconnecting, headphones unplugged) reaches the app as an
/// ordinary `pause` remote command. Recording it as a deliberate user pause is what broke media
/// keys after reconnecting: `isExplicitPauseIntentActive` makes the observer re-pause the page
/// the moment a WebKit-handled media key resumes it, so playback starts and dies immediately.
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
        // The two flags that would otherwise fight the next resume.
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

        // A media key handled by WebKit resumes the page; the observer reports it.
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
        // A route needs a moment to become usable, so the first attempt can be rejected while
        // it settles. Retiring the marker on issue would leave the retry nothing to act on.
        let playerService = self.makeRouteLossPausedService(routeReturned: true)

        await playerService.resumeAfterRouteRestored()
        #expect(playerService.routeLossPauseAt != nil)

        playerService.confirmPlaybackStarted()
        #expect(playerService.routeLossPauseAt == nil)
    }

    @Test("The disconnect's own reconciliation does not resume")
    func disconnectDoesNotResumeItself() async {
        // Losing the route schedules the same reconciliation the reconnect uses, and its route
        // change predates the pause. Mistaking it for a reconnect would restart the music the
        // system just stopped.
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
        // The Core Audio listener publishes only after several synchronous device queries, so a
        // genuine route-loss pause can drain first and look deliberate. Classifying at admission
        // alone would leave the explicit pause intent set and recovery permanently disabled.
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

        // No disappearance can account for it, so the claim is refused.
        playerService.reattributeRemotePauseToRouteLoss { _ in false }

        #expect(playerService.isExplicitPauseIntentActive)
        #expect(playerService.routeLossPauseAt == nil)
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
