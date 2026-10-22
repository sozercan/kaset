import Foundation
import Testing
@testable import Kaset

extension PlayerServiceWebQueueSyncTests {
    @Test("Track end restarts a single-song queue when repeat all is enabled")
    func trackEndRestartsSingleSongWhenRepeatAllIsEnabled() async {
        let song = Song(
            id: "1",
            title: "Song 1",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "v1"
        )

        await self.playerService.playQueue([song], startingAt: 0)
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .all)
        self.playerService.state = .playing

        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingPlayVideoId == "v1")
        #expect(self.playerService.state != .ended)
        #expect(!self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }

    @Test("Manual seek to end restarts a single-song queue with repeat all")
    func manualSeekToEndRestartsSingleSongWithRepeatAll() async {
        let song = Song(
            id: "1",
            title: "Song 1",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "v1"
        )

        await self.playerService.playQueue([song], startingAt: 0)
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .all)
        self.playerService.state = .playing
        self.playerService.duration = 180

        await self.playerService.seek(to: 180)

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingPlayVideoId == "v1")
        #expect(self.playerService.state != .ended)
        #expect(!self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }

    @Test("Cancelled manual seek continuation cannot end replacement playback")
    func cancelledManualSeekContinuationDoesNotEndReplacementPlayback() async {
        let continuationGate = AsyncGate()
        let mockClient = MockYTMusicClient()
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(songs: [], continuationToken: nil)
        self.playerService.setYTMusicClient(mockClient)
        let original = TestFixtures.makeSong(id: "original")
        let replacement = TestFixtures.makeSong(id: "replacement")
        await self.playerService.playQueue([original], startingAt: 0)
        self.playerService.mixContinuationToken = "continuation"
        self.playerService.state = .playing
        self.playerService.duration = original.duration ?? 180
        let seekTime = self.playerService.duration

        let seekTask = Task { @MainActor in
            await self.playerService.seek(to: seekTime)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline, mockClient.getMixQueueContinuationCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(mockClient.getMixQueueContinuationCallCount == 1)

        seekTask.cancel()
        await self.playerService.playQueue([replacement], startingAt: 0)
        self.playerService.state = .playing
        await continuationGate.open()
        await seekTask.value

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == replacement.videoId)
        #expect(self.playerService.state == .playing)
        #expect(!self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }
}
