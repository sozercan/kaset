import Foundation
import Testing
@testable import Kaset

@Suite("Remote music command ingress", .serialized, .tags(.service))
struct RemoteMusicCommandIngressTests {
    @Test("Callbacks preserve capture order under one scheduled drain")
    func callbacksPreserveCaptureOrderUnderOneDrain() {
        let ingress = RemoteMusicCommandIngress()
        let admittedAt = ContinuousClock.now

        #expect(ingress.capture(
            .play,
            issuedAtMilliseconds: 1000,
            admittedAt: admittedAt
        ))
        #expect(!ingress.capture(
            .nextPrevious(direction: .forward),
            issuedAtMilliseconds: 1001,
            admittedAt: admittedAt
        ))

        let firstBatch = ingress.takePendingCommands()
        #expect(firstBatch.map(\.sequence) == [0, 1])
        #expect(firstBatch.map(\.payload) == [
            .play,
            .nextPrevious(direction: .forward),
        ])
        #expect(firstBatch.map(\.issuedAtMilliseconds) == [1000, 1001])

        // A callback arriving while the scheduled drain is handling its first
        // batch must be consumed by that same drain, not schedule a competing task.
        #expect(!ingress.capture(
            .absoluteSeek(position: 42),
            issuedAtMilliseconds: 1002,
            admittedAt: admittedAt
        ))
        #expect(ingress.finishDrainBatch())

        let secondBatch = ingress.takePendingCommands()
        #expect(secondBatch.map(\.sequence) == [2])
        #expect(secondBatch.map(\.payload) == [.absoluteSeek(position: 42)])
        #expect(!ingress.finishDrainBatch())

        // Once the drain atomically finishes, the next callback rearms it.
        #expect(ingress.capture(
            .pause,
            issuedAtMilliseconds: 1003,
            admittedAt: admittedAt
        ))
    }

    @Test("A callback captured before a newer native intent is stale when delivered")
    @MainActor
    func capturedCallbackCannotSupersedeNewerIntent() async {
        let ingress = RemoteMusicCommandIngress()
        let playerService = PlayerService()
        await playerService.playQueue([
            self.makeSong(id: "current"),
            self.makeSong(id: "next"),
        ], startingAt: 0)
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 999

        #expect(ingress.capture(
            .nextPrevious(direction: .forward),
            issuedAtMilliseconds: 1000,
            admittedAt: ContinuousClock.now
        ))
        let newerIntent = playerService.beginMusicPlaybackIntent(issuedAtMilliseconds: 1001)

        let captured = ingress.takePendingCommands()
        #expect(captured.count == 1)
        if let command = captured.first {
            playerService.enqueueRemoteMusicTransportCommand(
                .next,
                issuedAtMilliseconds: command.issuedAtMilliseconds
            )
        }

        #expect(playerService.currentMusicPlaybackIntent == newerIntent)
        #expect(playerService.currentIndex == 0)
        #expect(playerService.currentTrack?.videoId == "current")
        #expect(playerService.remoteMusicTransportTask == nil)
        #expect(!ingress.finishDrainBatch())
    }

    @Test("Absolute seek routes to video only while video owns media keys")
    func absoluteSeekRouting() {
        #expect(NowPlayingManager.routesAbsoluteSeekToVideo(
            routesToYouTubeVideo: true,
            hasYouTubePlayer: true
        ))
        #expect(!NowPlayingManager.routesAbsoluteSeekToVideo(
            routesToYouTubeVideo: false,
            hasYouTubePlayer: true
        ))
        #expect(!NowPlayingManager.routesAbsoluteSeekToVideo(
            routesToYouTubeVideo: true,
            hasYouTubePlayer: false
        ))
    }

    private func makeSong(id: String) -> Song {
        Song(
            id: id,
            title: id,
            artists: [],
            duration: 180,
            videoId: id,
            feedbackTokens: .init(add: nil, remove: nil)
        )
    }
}
