import Foundation
import Testing
@testable import Kaset

extension PlayerServiceWebQueueSyncTests {
    @Test("Track-ended processing stops when its document generation is invalidated")
    func staleTrackEndedGenerationStopsBeforeQueueMutation() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        var validationCount = 0

        await self.playerService.handleTrackEnded(
            observedVideoId: "v1",
            shouldContinue: {
                validationCount += 1
                return validationCount == 1
            }
        )

        #expect(validationCount >= 2)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
    }

    @Test("Injected track end keeps the outgoing song visible until expected media confirmation")
    func injectedTrackEndWaitsForExpectedMediaConfirmation() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        let previousWebVideoId = SingletonPlayerWebView.shared.currentVideoId
        defer { SingletonPlayerWebView.shared.currentVideoId = previousWebVideoId }
        SingletonPlayerWebView.shared.currentVideoId = "v1"

        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.state == .loading)
        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")
        #expect(!self.playerService.shouldAutoloadPendingVideo)
        #expect(SingletonPlayerWebView.shared.currentVideoId == "v1")

        let shouldContinue = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(
            videoId: "v2"
        )

        #expect(shouldContinue)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.shouldAutoloadPendingVideo)
        #expect(SingletonPlayerWebView.shared.currentVideoId == "v2")
    }

    @Test("Duplicate ended events do not bypass a pending native handoff")
    func duplicateEndedEventDoesNotBypassPendingNativeHandoff() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"

        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")
        self.playerService.clearPendingNativeQueueAdvance()
    }

    @Test("A target ended event confirms the handoff and continues to its successor")
    func targetEndedBeforeStateConfirmationContinuesQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 1, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], duration: 220, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        await self.playerService.handleTrackEnded(observedVideoId: "v2")

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.currentTrack?.videoId == "v3")
        #expect(self.playerService.pendingPlayVideoId == "v3")
    }

    @Test("Outgoing media observations wait for the pending native queue target")
    func outgoingMediaWaitsForPendingNativeQueueTarget() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        let shouldContinue = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(
            videoId: "v1"
        )

        #expect(!shouldContinue)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")
        self.playerService.clearPendingNativeQueueAdvance()
    }

    @Test("Unexpected native autoplay falls back to the expected queue target")
    func unexpectedNativeAutoplayFallsBackToExpectedTarget() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")

        let shouldContinue = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(
            videoId: "unexpected-video"
        )

        #expect(!shouldContinue)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingPlayVideoId == "v2")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.state == .loading)
    }

    @Test("Queue reordering during a native handoff recovers to the newly next entry")
    func queueReorderDuringNativeHandoffUsesNewAdjacency() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], duration: 220, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        let entries = self.playerService.queueEntries

        self.playerService.setQueue(entries: [entries[0], entries[2], entries[1]])
        try? await Task.sleep(for: .milliseconds(20))

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v3")
        #expect(self.playerService.pendingPlayVideoId == "v3")
    }

    @Test("Removing the source entry follows the queue's realigned current position")
    func removingSourceEntryUsesRealignedQueuePosition() async {
        let songs = [
            Song(id: "a", title: "A", artists: [], duration: 180, videoId: "va"),
            Song(id: "b", title: "B", artists: [], duration: 180, videoId: "vb"),
            Song(id: "c", title: "C", artists: [], duration: 180, videoId: "vc"),
            Song(id: "d", title: "D", artists: [], duration: 180, videoId: "vd"),
        ]
        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "vc"
        await self.playerService.handleTrackEnded(observedVideoId: "vb")
        let sourceEntryID = self.playerService.queueEntries[1].id

        self.playerService.removeFromQueue(entryIDs: [sourceEntryID])
        try? await Task.sleep(for: .milliseconds(20))

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "vc")
        #expect(self.playerService.pendingPlayVideoId == "vc")
    }

    @Test("Transient invalid adjacency does not cancel a restored valid handoff")
    func transientQueueInvalidationRevalidatesBeforeFallback() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], duration: 220, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        let entries = self.playerService.queueEntries

        self.playerService.setQueue(entries: [entries[0], entries[2], entries[1]])
        self.playerService.setQueue(entries: entries)
        await Task.yield()

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")
        self.playerService.clearPendingNativeQueueAdvance()
    }

    @Test("Removing the only successor during a native handoff ends playback")
    func removingOnlySuccessorDuringNativeHandoffEndsPlayback() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        let sourceEntry = self.playerService.queueEntries[0]

        self.playerService.setQueue(entries: [sourceEntry])
        try? await Task.sleep(for: .milliseconds(20))

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.state == .ended)
    }

    @Test("Native queue advance timeout deterministically loads the expected target")
    func nativeQueueAdvanceTimeoutLoadsExpectedTarget() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        let generation = self.playerService.pendingNativeQueueAdvanceGeneration

        await self.playerService.handleNativeQueueAdvanceTimeout(generation: generation)

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.state == .loading)
    }

    @Test("Cancelled native queue maintenance yields to a valid replacement fetch")
    func cancelledNativeQueueMaintenanceYieldsToReplacementFetch() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        let staleSong = Song(
            id: "stale",
            title: "Stale continuation",
            artists: [],
            duration: 220,
            videoId: "stale-video"
        )
        let freshSong = Song(
            id: "fresh",
            title: "Fresh continuation",
            artists: [],
            duration: 220,
            videoId: "fresh-video"
        )
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResults = [
            RadioQueueResult(songs: [staleSong], continuationToken: "next-page"),
            RadioQueueResult(songs: [freshSong], continuationToken: nil),
        ]
        let previousWebVideoId = SingletonPlayerWebView.shared.currentVideoId
        defer { SingletonPlayerWebView.shared.currentVideoId = previousWebVideoId }
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService[keyPath: \.mixContinuationToken] = "test-continuation"
        self.playerService.beginPendingNativeQueueAdvance(to: 1)

        let confirmed = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(videoId: "v2")
        #expect(confirmed)
        await Self.waitUntilNativeQueueMaintenanceStarts(mockClient: mockClient)
        #expect(mockClient.getMixQueueContinuationCallCount == 1)
        let cancelledMaintenance = self.playerService.nativeQueueMaintenanceTask

        await self.playerService.loadQueueSongForNavigation(at: 0)
        let replacementFetch = Task { @MainActor in
            await self.playerService.fetchMoreMixSongsIfNeeded()
        }
        await Self.waitUntilMixContinuationWaiterIsRegistered(playerService: self.playerService)
        #expect(self.playerService.mixContinuationFetchWaiters.count == 1)
        await continuationGate.open()
        await cancelledMaintenance?.value
        await replacementFetch.value

        #expect(self.playerService.queue.map(\.videoId) == ["v1", "v2", "fresh-video"])
        #expect(!self.playerService.queue.contains { $0.videoId == "stale-video" })
        #expect(mockClient.getMixQueueContinuationCallCount == 2)
        #expect(self.playerService.mixContinuationFetchWaiters.isEmpty)
    }

    @Test("Clearing the queue invalidates in-flight native continuation maintenance")
    func clearQueueInvalidatesNativeContinuationMaintenance() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        let staleSong = Song(
            id: "stale",
            title: "Stale continuation",
            artists: [],
            duration: 220,
            videoId: "stale-video"
        )
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResults = [
            RadioQueueResult(songs: [staleSong], continuationToken: nil),
        ]
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.mixContinuationToken = "test-continuation"
        self.playerService.beginPendingNativeQueueAdvance(to: 1)

        let confirmed = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(videoId: "v2")
        #expect(confirmed)
        await Self.waitUntilNativeQueueMaintenanceStarts(mockClient: mockClient)
        let cancelledMaintenance = self.playerService.nativeQueueMaintenanceTask

        self.playerService.clearQueueEntirely()
        await continuationGate.open()
        await cancelledMaintenance?.value

        #expect(self.playerService.queue.isEmpty)
        #expect(!self.playerService.queue.contains { $0.videoId == "stale-video" })
        #expect(self.playerService.nativeQueueMaintenanceTask == nil)
    }

    private static func waitUntilNativeQueueMaintenanceStarts(mockClient: MockYTMusicClient) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline {
            if mockClient.getMixQueueContinuationCallCount == 1 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func waitUntilMixContinuationWaiterIsRegistered(playerService: PlayerService) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline {
            if playerService.mixContinuationFetchWaiters.count == 1 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
