import Foundation
import Testing
@testable import Kaset

extension PlayerServiceWebQueueSyncTests {
    @Test("Stale mix continuation cannot mutate a replacement queue or token")
    func staleMixContinuationDoesNotMutateReplacementQueue() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let original = TestFixtures.makeSong(id: "original")
        let stale = TestFixtures.makeSong(id: "stale")
        let replacement = [
            TestFixtures.makeSong(id: "replacement-1"),
            TestFixtures.makeSong(id: "replacement-2"),
        ]
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(
            songs: [stale],
            continuationToken: nil
        )
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue([original], startingAt: 0)
        self.playerService.mixContinuationToken = "test"

        let fetchTask = Task { @MainActor in
            await self.playerService.fetchMoreMixSongsIfNeeded()
        }
        await Self.waitUntilMixContinuationStarts(mockClient: mockClient)

        self.playerService.setQueue(replacement)
        self.playerService.currentIndex = 0
        self.playerService.currentTrack = replacement[0]
        self.playerService.pendingPlayVideoId = replacement[0].videoId
        self.playerService.mixContinuationToken = "none"
        await continuationGate.open()
        await fetchTask.value

        #expect(self.playerService.queue.map(\.videoId) == replacement.map(\.videoId))
        #expect(self.playerService.mixContinuationToken == "none")
        #expect(!self.playerService.queue.contains { $0.videoId == stale.videoId })
    }

    @Test("Stale mix continuation cannot mutate a replacement queue with the same token")
    func staleMixContinuationDoesNotMutateSameTokenReplacement() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let original = TestFixtures.makeSong(id: "original")
        let stale = TestFixtures.makeSong(id: "stale")
        let replacement = [
            TestFixtures.makeSong(id: "replacement-1"),
            TestFixtures.makeSong(id: "replacement-2"),
        ]
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(songs: [stale], continuationToken: nil)
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue([original], startingAt: 0)
        self.playerService.mixContinuationToken = "test"

        let fetchTask = Task { @MainActor in
            await self.playerService.fetchMoreMixSongsIfNeeded()
        }
        await Self.waitUntilMixContinuationStarts(mockClient: mockClient)

        self.playerService.setQueue(replacement)
        self.playerService.currentIndex = 0
        self.playerService.currentTrack = replacement[0]
        self.playerService.pendingPlayVideoId = replacement[0].videoId
        await continuationGate.open()
        await fetchTask.value

        #expect(self.playerService.queue.map(\.videoId) == replacement.map(\.videoId))
        #expect(self.playerService.mixContinuationToken == "test")
        #expect(!self.playerService.queue.contains { $0.videoId == stale.videoId })
    }

    @Test("Delayed Next cannot advance a larger replacement queue")
    func delayedNextDoesNotAdvanceReplacementQueue() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let original = TestFixtures.makeSong(id: "original")
        let replacement = [
            TestFixtures.makeSong(id: "replacement-1"),
            TestFixtures.makeSong(id: "replacement-2"),
            TestFixtures.makeSong(id: "replacement-3"),
        ]
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(songs: [], continuationToken: nil)
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue([original], startingAt: 0)
        self.playerService.mixContinuationToken = "test"

        let nextTask = Task { @MainActor in
            await self.playerService.next()
        }
        await Self.waitUntilMixContinuationStarts(mockClient: mockClient)

        await self.playerService.playQueue(replacement, startingAt: 0)
        self.playerService.state = .playing
        await continuationGate.open()
        await nextTask.value

        #expect(self.playerService.queue.map(\.videoId) == replacement.map(\.videoId))
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == replacement[0].videoId)
        #expect(self.playerService.state == .playing)
    }

    @Test("Delayed radio Next cannot replace or skip new same-video playback")
    func delayedRadioNextDoesNotMutateSameVideoReplacement() async {
        let mockClient = MockYTMusicClient()
        let radioGate = AsyncGate()
        let seed = TestFixtures.makeSong(id: "shared-video", title: "Original Seed")
        let staleRadio = TestFixtures.makeSong(id: "stale-radio")
        let replacement = [
            TestFixtures.makeSong(id: "shared-video", title: "Replacement Seed"),
            TestFixtures.makeSong(id: "replacement-next"),
        ]
        mockClient.getRadioQueueGate = radioGate
        mockClient.radioQueueSongs[seed.videoId] = [seed, staleRadio]
        self.playerService.setYTMusicClient(mockClient)
        self.playerService.currentTrack = seed
        self.playerService.pendingPlayVideoId = seed.videoId
        self.playerService.state = .playing

        let nextTask = Task { @MainActor in
            await self.playerService.next()
        }
        await Self.waitUntilRadioQueueStartsForRace(mockClient: mockClient)

        await self.playerService.playQueue(replacement, startingAt: 0)
        self.playerService.state = .playing
        await radioGate.open()
        await nextTask.value

        #expect(self.playerService.queue.map(\.videoId) == replacement.map(\.videoId))
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == replacement[0].videoId)
        #expect(self.playerService.state == .playing)
    }

    @Test("Delayed radio failure cannot advance new same-video playback")
    func delayedRadioFailureDoesNotAdvanceSameVideoReplacement() async {
        let mockClient = MockYTMusicClient()
        let radioGate = AsyncGate()
        let seed = TestFixtures.makeSong(id: "shared-video", title: "Original Seed")
        let replacement = [
            TestFixtures.makeSong(id: "shared-video", title: "Replacement Seed"),
            TestFixtures.makeSong(id: "replacement-next"),
        ]
        mockClient.getRadioQueueGate = radioGate
        self.playerService.setYTMusicClient(mockClient)
        self.playerService.currentTrack = seed
        self.playerService.pendingPlayVideoId = seed.videoId
        self.playerService.state = .playing

        let nextTask = Task { @MainActor in
            await self.playerService.next()
        }
        await Self.waitUntilRadioQueueStartsForRace(mockClient: mockClient)

        await self.playerService.playQueue(replacement, startingAt: 0)
        self.playerService.state = .playing
        mockClient.shouldThrowError = NSError(domain: "Radio", code: 500)
        await radioGate.open()
        await nextTask.value

        #expect(self.playerService.queue.map(\.videoId) == replacement.map(\.videoId))
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == replacement[0].videoId)
        #expect(self.playerService.state == .playing)
    }

    @Test("Stale radio playback cannot start after its initial metadata await")
    func staleRadioPlaybackDoesNotStartAfterMetadataAwait() async {
        let mockClient = MockYTMusicClient()
        let seed = TestFixtures.makeSong(id: "shared-video", title: "Original Seed")
        let replacement = [
            TestFixtures.makeSong(id: "shared-video", title: "Replacement Seed"),
            TestFixtures.makeSong(id: "replacement-next"),
        ]
        mockClient.getSongDelay = .milliseconds(200)
        mockClient.radioQueueSongs[seed.videoId] = [
            seed,
            TestFixtures.makeSong(id: "stale-radio"),
        ]
        self.playerService.setYTMusicClient(mockClient)

        let radioTask = Task { @MainActor in
            await self.playerService.playWithRadio(song: seed)
        }
        await Self.waitUntilSongRequestStarts(videoId: seed.videoId, mockClient: mockClient)

        mockClient.getSongDelay = nil
        await self.playerService.playQueue(replacement, startingAt: 0)
        self.playerService.state = .playing
        await radioTask.value

        #expect(!mockClient.getRadioQueueCalled)
        #expect(self.playerService.queue.map(\.videoId) == replacement.map(\.videoId))
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == replacement[0].videoId)
        #expect(self.playerService.state == .playing)
    }

    @Test("Delayed radio fetch cannot repopulate a queue the user cleared")
    func delayedRadioFetchDoesNotRepopulateClearedQueue() async {
        let mockClient = MockYTMusicClient()
        let radioGate = AsyncGate()
        let seed = TestFixtures.makeSong(id: "seed")
        let staleRadio = TestFixtures.makeSong(id: "stale-radio")
        mockClient.getRadioQueueGate = radioGate
        mockClient.radioQueueSongs[seed.videoId] = [seed, staleRadio]
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue([seed], startingAt: 0)

        let radioTask = Task { @MainActor in
            await self.playerService.fetchAndApplyRadioQueue(for: seed.videoId)
        }
        await Self.waitUntilRadioQueueStartsForRace(mockClient: mockClient)

        self.playerService.clearQueue()
        await radioGate.open()
        let outcome = await radioTask.value

        #expect(outcome == .queueMutated)
        #expect(self.playerService.queue.map(\.videoId) == [seed.videoId])
        #expect(!self.playerService.queue.contains { $0.videoId == staleRadio.videoId })
    }

    @Test("Manual Next uses a queue entry added while radio fetch is pending")
    func manualNextUsesQueueEntryAddedDuringRadioFetch() async {
        let mockClient = MockYTMusicClient()
        let radioGate = AsyncGate()
        let seed = TestFixtures.makeSong(id: "seed")
        let manuallyQueued = TestFixtures.makeSong(id: "manually-queued")
        mockClient.getRadioQueueGate = radioGate
        mockClient.radioQueueSongs[seed.videoId] = [
            seed,
            TestFixtures.makeSong(id: "stale-radio"),
        ]
        self.playerService.setYTMusicClient(mockClient)
        self.playerService.currentTrack = seed
        self.playerService.pendingPlayVideoId = seed.videoId
        self.playerService.state = .playing

        let nextTask = Task { @MainActor in
            await self.playerService.next()
        }
        await Self.waitUntilRadioQueueStartsForRace(mockClient: mockClient)

        self.playerService.appendToQueue([manuallyQueued])
        await radioGate.open()
        await nextTask.value

        #expect(self.playerService.queue.map(\.videoId) == [manuallyQueued.videoId])
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == manuallyQueued.videoId)
    }

    @Test("Metadata-only queue updates preserve an in-flight radio fetch")
    func metadataOnlyQueueUpdatePreservesRadioFetch() async {
        let mockClient = MockYTMusicClient()
        let radioGate = AsyncGate()
        let seed = TestFixtures.makeSong(id: "seed", title: "Seed")
        let radioNext = TestFixtures.makeSong(id: "radio-next")
        mockClient.getRadioQueueGate = radioGate
        mockClient.radioQueueSongs[seed.videoId] = [seed, radioNext]
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue([seed], startingAt: 0)
        let entryID = self.playerService.queueEntryIDs[0]

        let radioTask = Task { @MainActor in
            await self.playerService.fetchAndApplyRadioQueue(for: seed.videoId)
        }
        await Self.waitUntilRadioQueueStartsForRace(mockClient: mockClient)

        let refreshedSeed = TestFixtures.makeSong(id: "seed", title: "Refreshed Seed")
        self.playerService.setQueue(entries: [QueueEntry(id: entryID, song: refreshedSeed)])
        await radioGate.open()
        let outcome = await radioTask.value

        #expect(outcome == .applied)
        #expect(self.playerService.queue.map(\.videoId) == [seed.videoId, radioNext.videoId])
        #expect(self.playerService.currentQueueEntryID == entryID)
    }

    @Test("Stale track-end continuation cannot end replacement playback")
    func staleTrackEndContinuationDoesNotEndReplacementPlayback() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let original = TestFixtures.makeSong(id: "original")
        let replacement = [
            TestFixtures.makeSong(id: "replacement-1"),
            TestFixtures.makeSong(id: "replacement-2"),
        ]
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(songs: [], continuationToken: nil)
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue([original], startingAt: 0)
        self.playerService.mixContinuationToken = "test"
        self.playerService.state = .playing

        let endedTask = Task { @MainActor in
            await self.playerService.handleTrackEnded(observedVideoId: original.videoId)
        }
        await Self.waitUntilMixContinuationStarts(mockClient: mockClient)

        await self.playerService.playQueue(replacement, startingAt: 0)
        self.playerService.state = .playing
        await continuationGate.open()
        await endedTask.value

        #expect(self.playerService.queue.map(\.videoId) == replacement.map(\.videoId))
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == replacement[0].videoId)
        #expect(self.playerService.state == .playing)
        #expect(!self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }

    @Test("Clearing the queue during track-end continuation still finalizes playback")
    func queueClearDuringTrackEndContinuationStillEndsPlayback() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let original = TestFixtures.makeSong(id: "original")
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(songs: [], continuationToken: nil)
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue([original], startingAt: 0)
        self.playerService.mixContinuationToken = "test"
        self.playerService.state = .playing

        let endedTask = Task { @MainActor in
            await self.playerService.handleTrackEnded(observedVideoId: original.videoId)
        }
        await Self.waitUntilMixContinuationStarts(mockClient: mockClient)

        self.playerService.clearQueue()
        await continuationGate.open()
        await endedTask.value

        #expect(self.playerService.queue.map(\.videoId) == [original.videoId])
        #expect(self.playerService.currentTrack?.videoId == original.videoId)
        #expect(self.playerService.state == .ended)
        #expect(self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }

    @Test("Concurrent queue navigation supersedes a pending manual seek-to-end")
    func queueNavigationSupersedesPendingManualSeekToEnd() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let songs = TestFixtures.makeSongs(count: 3)
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(songs: [], continuationToken: nil)
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue(songs, startingAt: 2)
        self.playerService.mixContinuationToken = "test"
        self.playerService.state = .playing
        self.playerService.duration = songs[2].duration ?? 180

        let seekTask = Task { @MainActor in
            await self.playerService.seek(to: self.playerService.duration)
        }
        await Self.waitUntilMixContinuationStarts(mockClient: mockClient)

        await self.playerService.loadQueueSongForNavigation(at: 1)
        self.playerService.state = .playing
        await continuationGate.open()
        await seekTask.value

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == songs[1].videoId)
        #expect(self.playerService.state == .playing)
        #expect(!self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }

    @Test("Concurrent queue navigation supersedes pending track-end continuation")
    func queueNavigationSupersedesPendingTrackEndContinuation() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let songs = TestFixtures.makeSongs(count: 3)
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(songs: [], continuationToken: nil)
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue(songs, startingAt: 2)
        self.playerService.mixContinuationToken = "test"
        self.playerService.state = .playing

        let endedTask = Task { @MainActor in
            await self.playerService.handleTrackEnded(observedVideoId: songs[2].videoId)
        }
        await Self.waitUntilMixContinuationStarts(mockClient: mockClient)

        await self.playerService.loadQueueSongForNavigation(at: 1)
        self.playerService.state = .playing
        await continuationGate.open()
        await endedTask.value

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == songs[1].videoId)
        #expect(self.playerService.state == .playing)
        #expect(!self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }

    @Test("Removing a duplicate source occurrence resumes at the realigned index")
    func removedDuplicateSourceUsesRealignedQueueIndex() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let first = Song(id: "first", title: "First Occurrence", artists: [], videoId: "duplicate-video")
        let second = Song(id: "second", title: "Second Occurrence", artists: [], videoId: "duplicate-video")
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(songs: [], continuationToken: nil)
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue([first, second], startingAt: 1)
        let firstEntryID = self.playerService.queueEntryIDs[0]
        self.playerService.mixContinuationToken = "test"
        self.playerService.state = .playing

        let endedTask = Task { @MainActor in
            await self.playerService.handleTrackEnded(observedVideoId: second.videoId)
        }
        await Self.waitUntilMixContinuationStarts(mockClient: mockClient)

        self.playerService.removeFromQueue(at: 1)
        await continuationGate.open()
        await endedTask.value

        #expect(self.playerService.queueEntryIDs == [firstEntryID])
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentQueueEntryID == firstEntryID)
        #expect(self.playerService.currentTrack?.videoId == first.videoId)
        #expect(self.playerService.state != .ended)
        #expect(!self.playerService.shouldSuppressAutoplayAfterQueueEnd)
    }

    private static func waitUntilMixContinuationStarts(mockClient: MockYTMusicClient) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline {
            if mockClient.getMixQueueContinuationCallCount == 1 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for mix continuation")
    }

    private static func waitUntilRadioQueueStartsForRace(mockClient: MockYTMusicClient) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline {
            if mockClient.getRadioQueueCalled {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for radio queue")
    }

    private static func waitUntilSongRequestStarts(
        videoId: String,
        mockClient: MockYTMusicClient
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline {
            if mockClient.getSongVideoIds.contains(videoId) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for song request")
    }
}
