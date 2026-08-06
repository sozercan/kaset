// swiftlint:disable file_length

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

    @Test("Canceled observation cannot confirm a pending native handoff")
    func canceledObservationDoesNotConfirmNativeHandoff() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        var validationCount = 0

        let shouldContinue = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(
            videoId: "v2",
            shouldContinue: {
                validationCount += 1
                return validationCount == 1
            }
        )

        #expect(validationCount >= 2)
        #expect(!shouldContinue)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")
        self.playerService.clearPendingNativeQueueAdvance()
    }

    @Test("Paused media confirmation completes a native handoff as paused")
    func pausedMediaConfirmationCompletesNativeHandoffAsPaused() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"

        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        let shouldContinue = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(
            videoId: "v2"
        )
        self.playerService.updatePlaybackState(
            isPlaying: false,
            progress: 0,
            duration: 200,
            observedVideoId: "v2"
        )

        #expect(shouldContinue)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.state == .paused)
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

    @Test("Identity deadline bypasses native handoff and advances once")
    func identityDeadlineDeterministicallyAdvancesOnce() async throws {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], duration: 220, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        let nativeOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        let deadlineOccurrence = MusicPlaybackOccurrence.web(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeOccurrence.nativeGeneration
        )

        await self.playerService.handleTrackEnded(
            observedVideoId: nil,
            playbackOccurrence: deadlineOccurrence,
            identityResolutionTimedOut: true
        )
        await self.playerService.handleTrackEnded(
            observedVideoId: nil,
            playbackOccurrence: deadlineOccurrence,
            identityResolutionTimedOut: true
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.injectedWebQueueVideoId == nil)
    }

    @Test("Identity deadline ignores a re-injected native marker")
    func identityDeadlineIgnoresReinjectedNativeMarker() async throws {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], duration: 220, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        let nativeOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        let deadlineOccurrence = MusicPlaybackOccurrence.web(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeOccurrence.nativeGeneration
        )
        var validationCount = 0

        await self.playerService.handleTrackEnded(
            observedVideoId: nil,
            playbackOccurrence: deadlineOccurrence,
            identityResolutionTimedOut: true,
            shouldContinue: {
                validationCount += 1
                if validationCount == 2 {
                    self.playerService.injectedWebQueueVideoId = "v2"
                }
                return true
            }
        )

        #expect(validationCount >= 2)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
    }

    @Test("Identity deadline rejects an occurrence carrying media identity")
    func identityDeadlineRejectsIdentityBearingOccurrence() async throws {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        let nativeOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        let contradictoryOccurrence = MusicPlaybackOccurrence.web(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeOccurrence.nativeGeneration,
            videoId: "v2"
        )

        await self.playerService.handleTrackEnded(
            observedVideoId: nil,
            playbackOccurrence: contradictoryOccurrence,
            identityResolutionTimedOut: true
        )

        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.injectedWebQueueVideoId == "v2")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
    }

    @Test("Identity deadline resolves an existing native handoff")
    func identityDeadlineFallsBackPendingNativeHandoff() async throws {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        let nativeOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        let deadlineOccurrence = MusicPlaybackOccurrence.web(
            documentGeneration: 7,
            mediaGeneration: 1,
            nativeGeneration: nativeOccurrence.nativeGeneration
        )

        await self.playerService.handleTrackEnded(
            observedVideoId: nil,
            playbackOccurrence: deadlineOccurrence,
            identityResolutionTimedOut: true
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.state == .loading)
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

    @Test("Native queue advance fallback preserves a later Pause")
    func nativeQueueAdvanceFallbackPreservesLaterPause() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        let sourceOccurrence = self.playerService.currentMusicPlaybackOccurrence
        let targetEntryID = self.playerService.queueEntryIDs[1]
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        let generation = self.playerService.pendingNativeQueueAdvanceGeneration

        await self.playerService.pause()
        let pauseIntent = self.playerService.currentMusicPlaybackIntent
        await self.playerService.handleNativeQueueAdvanceTimeout(generation: generation)

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.activePlaybackQueueEntryID == targetEntryID)
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentMusicPlaybackOccurrence?.videoId == "v2")
        #expect(self.playerService.currentMusicPlaybackOccurrence != sourceOccurrence)
        #expect(self.playerService.acceptsMusicPlaybackIntent(pauseIntent))
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.isExplicitPauseIntentActive)
        #expect(!self.playerService.shouldResumeAfterInterruption)
    }

    @Test("Previous cancels a pending native handoff before restarting the source")
    func previousCancelsPendingNativeHandoff() async {
        let singleton = SingletonPlayerWebView.shared
        singleton.tearDown()
        _ = singleton.getWebView(
            webKitManager: WebKitManager.makeTestInstance(),
            playerService: self.playerService
        )
        defer { singleton.tearDown() }
        var navigationRequests: [String] = []
        self.playerService.onMusicPlaybackNavigationRequested = { videoId, _ in
            navigationRequests.append(videoId)
        }

        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        navigationRequests.removeAll()
        singleton.currentVideoId = "v1"
        self.playerService.state = .playing
        self.playerService.progress = 100
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        let generation = self.playerService.pendingNativeQueueAdvanceGeneration
        let navigationGeneration = self.playerService.playbackNavigationGeneration

        await self.playerService.previous()
        await self.playerService.handleNativeQueueAdvanceTimeout(generation: generation)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingPlayVideoId == "v1")
        #expect(self.playerService.playbackNavigationGeneration > navigationGeneration)
        #expect(navigationRequests == ["v1"])
        #expect(self.playerService.progress == 0)
    }

    @Test("Previous skips a missing handoff source and navigates to the prior entry")
    func previousSkipsMissingHandoffSource() async {
        let entries = [
            QueueEntry(
                id: UUID(),
                song: Song(id: "1", title: "Prior", artists: [], duration: 180, videoId: "v1")
            ),
            QueueEntry(
                id: UUID(),
                song: Song(id: "2", title: "Removed Source", artists: [], duration: 190, videoId: "v2")
            ),
            QueueEntry(
                id: UUID(),
                song: Song(id: "3", title: "Target", artists: [], duration: 200, videoId: "v3")
            ),
        ]
        self.playerService.setQueue(entries: entries)
        self.playerService.currentIndex = 1
        await self.playerService.loadQueueSongForNavigation(at: 1)
        self.playerService.state = .playing
        self.playerService.progress = 100
        self.playerService.beginPendingNativeQueueAdvance(to: 2)

        self.playerService.setQueue(entries: [entries[0], entries[2]])
        self.playerService.clearPendingNativeQueueAdvance()
        let generation = self.playerService.pendingNativeQueueAdvanceGeneration
        self.playerService.pendingNativeQueueAdvance = PendingNativeQueueAdvance(
            sourceEntryID: entries[1].id,
            sourceVideoId: "v2",
            targetEntryID: entries[2].id,
            targetVideoId: "v3",
            generation: generation,
            fallbackDeadline: ContinuousClock.now.advanced(by: .seconds(18))
        )
        #expect(self.playerService.activePlaybackQueueEntryID == nil)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.currentIndex == 1)

        await self.playerService.previous()

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingPlayVideoId == "v1")
        #expect(self.playerService.activePlaybackQueueEntryID == entries[0].id)
        #expect(self.playerService.progress == 0)
    }

    @Test("Previous re-anchors a paused native handoff source without resuming")
    func previousReanchorsPausedNativeHandoffWithoutResuming() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 100
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        await self.playerService.pause()
        #expect(self.playerService.isExplicitPauseIntentActive)

        await self.playerService.previous()

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingPlayVideoId == "v1")
        #expect(self.playerService.progress == 0)
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.isExplicitPauseIntentActive)
        #expect(!self.playerService.shouldResumeAfterInterruption)
    }

    @Test("Superseded source re-anchor remains handled after clearing the handoff")
    func supersededSourceReanchorDoesNotFallThrough() async {
        let singleton = SingletonPlayerWebView.shared
        singleton.tearDown()
        _ = singleton.getWebView(
            webKitManager: WebKitManager.makeTestInstance(),
            playerService: self.playerService
        )
        defer { singleton.tearDown() }
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        singleton.currentVideoId = "v1"
        self.playerService.state = .playing
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        let reanchorIntent = self.playerService.currentMusicPlaybackIntent
        var newerIntent: MusicPlaybackIntent?
        self.playerService.onMusicPlaybackNavigationRequested = { _, _ in
            newerIntent = self.playerService.beginMusicPlaybackIntent()
        }

        let handled = await self.playerService.reanchorPendingNativeQueueAdvanceSource(
            intent: reanchorIntent,
            startsPaused: false,
            reason: "test superseded re-anchor"
        )

        #expect(handled)
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(newerIntent != nil)
        #expect(self.playerService.currentMusicPlaybackIntent == newerIntent)
        #expect(!self.playerService.acceptsMusicPlaybackIntent(reanchorIntent))
    }

    @Test("Backward seek cancels a pending native handoff")
    func backwardSeekCancelsPendingNativeHandoff() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 100
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        let generation = self.playerService.pendingNativeQueueAdvanceGeneration
        let navigationGeneration = self.playerService.playbackNavigationGeneration
        self.playerService.state = .paused
        self.playerService.shouldResumeAfterInterruption = true
        self.playerService.isExplicitPauseIntentActive = false

        await self.playerService.seek(to: 20)
        await self.playerService.handleNativeQueueAdvanceTimeout(generation: generation)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingPlayVideoId == "v1")
        #expect(self.playerService.playbackNavigationGeneration > navigationGeneration)
        #expect(self.playerService.progress == 20)
        #expect(self.playerService.pendingRestoredSeek == 20)
        #expect(!self.playerService.isExplicitPauseIntentActive)
        #expect(self.playerService.shouldResumeAfterInterruption)
    }

    @Test("Source re-anchor preserves authoritative duration over stale song metadata")
    func sourceReanchorPreservesAuthoritativeDuration() async {
        let songs = [
            Song(id: "1", title: "Source", artists: [], duration: 300, videoId: "v1"),
            Song(id: "2", title: "Target", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 100
        self.playerService.duration = 180
        self.playerService.beginPendingNativeQueueAdvance(to: 1)

        await self.playerService.seek(to: 150)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.currentTrack?.duration == 300)
        #expect(self.playerService.duration == 180)
        #expect(self.playerService.progress == 150)
        #expect(self.playerService.pendingRestoredSeek == 150)
        #expect(self.playerService.isRestoringExplicitTransportSeek)
    }

    @Test("Subsequent seek updates the pending source re-anchor clock")
    func subsequentSeekUpdatesPendingSourceReanchorClock() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 100
        self.playerService.beginPendingNativeQueueAdvance(to: 1)

        await self.playerService.seek(to: 20)
        #expect(self.playerService.isRestoringPlaybackSession)
        #expect(self.playerService.pendingRestoredSeek == 20)

        await self.playerService.seek(to: 35)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.progress == 35)
        #expect(self.playerService.currentTimeMs == 35000)
        #expect(self.playerService.pendingRestoredSeek == 35)
        #expect(self.playerService.shouldAutoResumeAfterRestoredLoad)
        #expect(self.playerService.shouldResumeAfterInterruption)
        #expect(!self.playerService.isExplicitPauseIntentActive)
    }

    @Test("Initial seek-to-end during pending handoff advances the queue")
    func initialSeekToEndDuringPendingHandoffAdvancesQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 100
        let sourceOccurrence = self.playerService.currentMusicPlaybackOccurrence
        #expect(self.playerService.claimTerminalMusicPlaybackOccurrence(sourceOccurrence))
        self.playerService.beginPendingNativeQueueAdvance(to: 1)

        await self.playerService.seek(to: 180)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingRestoredSeek == nil)
    }

    @Test("Seek-to-end during source re-anchor advances the queue")
    func seekToEndDuringSourceReanchorAdvancesQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 100
        self.playerService.beginPendingNativeQueueAdvance(to: 1)

        await self.playerService.seek(to: 20)
        #expect(self.playerService.isRestoringExplicitTransportSeek)

        await self.playerService.seek(to: 180)

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingRestoredSeek == nil)
        #expect(!self.playerService.isRestoringExplicitTransportSeek)
    }

    @Test("Missing handoff source falls back synchronously before Resume")
    func missingHandoffSourceFallsBackBeforeResume() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.beginPendingNativeQueueAdvance(to: 1)

        self.playerService.removeFromQueue(at: 0)
        await self.playerService.resume()
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingPlayVideoId == "v2")
    }

    @Test("Missing handoff source fallback preserves an explicit seek clock")
    func missingHandoffSourceFallbackPreservesSeekClock() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 100
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        self.playerService.removeFromQueue(at: 0)

        await self.playerService.seek(to: 20)
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.progress == 20)
        #expect(self.playerService.pendingRestoredSeek == 20)
        #expect(self.playerService.isRestoringExplicitTransportSeek)
    }

    @Test("Missing source fallback normalizes a terminal seek to the fallback track")
    func missingSourceFallbackNormalizesTerminalSeek() async {
        let songs = [
            Song(id: "1", title: "Source", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Short Target", artists: [], duration: 120, videoId: "v2"),
            Song(id: "3", title: "Successor", artists: [], duration: 200, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 100
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        self.playerService.removeFromQueue(at: 0)

        await self.playerService.seek(to: 165)
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingPlayVideoId == "v2")
        #expect(self.playerService.duration == 0)
        #expect(self.playerService.pendingRestoredSeek == 165)
        #expect(self.playerService.shouldFinishRestoredSeekAtEnd)

        self.playerService.updatePlaybackState(
            isPlaying: false,
            progress: 0,
            duration: 120,
            observedVideoId: "v2"
        )
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v3")
        #expect(self.playerService.pendingPlayVideoId == "v3")
        #expect(self.playerService.pendingRestoredSeek == nil)
    }

    @Test("Paused terminal advance to a duplicate video occurrence remains paused")
    func pausedTerminalAdvanceToDuplicateVideoRemainsPaused() async {
        let singleton = SingletonPlayerWebView.shared
        let previousVideoId = singleton.currentVideoId
        singleton.currentVideoId = "duplicate"
        defer { singleton.currentVideoId = previousVideoId }
        let songs = [
            Song(id: "1", title: "First", artists: [], duration: 180, videoId: "duplicate"),
            Song(id: "2", title: "Second", artists: [], duration: 180, videoId: "duplicate"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        await self.playerService.pause()

        await self.playerService.seek(to: 180)

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentQueueEntryID == self.playerService.queueEntryIDs[1])
        #expect(self.playerService.currentTrack?.id == "2")
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.isExplicitPauseIntentActive)
        #expect(!self.playerService.shouldResumeAfterInterruption)
    }

    @Test("Resume during an active native handoff keeps waiting for the target")
    func resumeDuringActiveNativeHandoffPreservesHandoff() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        let handoffGeneration = self.playerService.pendingNativeQueueAdvanceGeneration
        let navigationGeneration = self.playerService.playbackNavigationGeneration
        let playbackOccurrence = self.playerService.currentMusicPlaybackOccurrence

        await self.playerService.resume()

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")
        #expect(self.playerService.pendingNativeQueueAdvanceGeneration == handoffGeneration)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.playbackNavigationGeneration == navigationGeneration)
        #expect(self.playerService.currentMusicPlaybackOccurrence == playbackOccurrence)
    }

    @Test("Resume restarts paused handoff media without re-anchoring the source")
    func resumeRestartsPausedHandoffMediaWithoutReanchoring() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        let handoffGeneration = self.playerService.pendingNativeQueueAdvanceGeneration
        let navigationGeneration = self.playerService.playbackNavigationGeneration
        let playbackOccurrence = self.playerService.currentMusicPlaybackOccurrence
        self.playerService.state = .paused
        self.playerService.shouldResumeAfterInterruption = false
        self.playerService.isAwaitingPlaybackConfirmation = false
        self.playerService.isExplicitPauseIntentActive = false

        await self.playerService.resume()

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")
        #expect(self.playerService.pendingNativeQueueAdvanceGeneration == handoffGeneration)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.playbackNavigationGeneration == navigationGeneration)
        #expect(self.playerService.currentMusicPlaybackOccurrence == playbackOccurrence)
        #expect(self.playerService.state == .loading)
        #expect(self.playerService.shouldResumeAfterInterruption)
        #expect(self.playerService.isAwaitingPlaybackConfirmation)
        #expect(!self.playerService.isExplicitPauseIntentActive)
    }

    @Test("Terminal seek during a paused native handoff preserves pause intent")
    func terminalSeekDuringPausedNativeHandoffPreservesPauseIntent() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.injectedWebQueueVideoId = "v2"
        await self.playerService.handleTrackEnded(observedVideoId: "v1")
        await self.playerService.pause()
        #expect(self.playerService.isExplicitPauseIntentActive)

        await self.playerService.seek(to: 180)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.isExplicitPauseIntentActive)
        #expect(!self.playerService.shouldResumeAfterInterruption)
    }

    @Test("Deferred terminal restoration advances while preserving pause intent")
    func deferredTerminalRestorationPreservesPauseIntent() async {
        let songs = [
            Song(id: "1", title: "Source", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Short Target", artists: [], duration: 120, videoId: "v2"),
            Song(id: "3", title: "Successor", artists: [], duration: 200, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.progress = 100
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        await self.playerService.pause()
        self.playerService.removeFromQueue(at: 0)

        await self.playerService.seek(to: 165)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingRestoredSeek == 165)
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.isExplicitPauseIntentActive)

        self.playerService.updatePlaybackState(
            isPlaying: false,
            progress: 0,
            duration: 120,
            observedVideoId: "v2"
        )
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v3")
        #expect(self.playerService.pendingPlayVideoId == "v3")
        #expect(self.playerService.pendingRestoredSeek == nil)
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.isExplicitPauseIntentActive)
        #expect(!self.playerService.shouldResumeAfterInterruption)
    }

    @Test("Resume cancels a paused pending native handoff")
    func resumeCancelsPausedPendingNativeHandoff() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        let generation = self.playerService.pendingNativeQueueAdvanceGeneration
        await self.playerService.pause()
        let navigationGeneration = self.playerService.playbackNavigationGeneration

        await self.playerService.resume()
        await self.playerService.handleNativeQueueAdvanceTimeout(generation: generation)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
        #expect(self.playerService.pendingPlayVideoId == "v1")
        #expect(self.playerService.playbackNavigationGeneration > navigationGeneration)
    }

    @Test("Repeat-mode change immediately invalidates a pending wraparound handoff")
    func repeatModeChangeInvalidatesPendingWraparoundHandoff() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.state = .playing
        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .all)
        self.playerService.beginPendingNativeQueueAdvance(to: 0)
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v1")

        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
    }

    @Test("Stale WebContent recovery intent leaves the handoff for the current owner")
    func staleContentProcessRecoveryIntentLeavesPendingHandoff() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        let staleIntent = self.playerService.currentMusicPlaybackIntent
        _ = self.playerService.beginMusicPlaybackIntent()

        let handled = await self.playerService
            .recoverPendingNativeQueueAdvanceAfterContentProcessTermination(intent: staleIntent)

        #expect(!handled)
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
    }

    @Test("WebContent recovery resolves a pending native handoff to its target")
    func contentProcessRecoveryResolvesPendingNativeHandoff() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        let intent = self.playerService.currentMusicPlaybackIntent

        let handled = await self.playerService
            .recoverPendingNativeQueueAdvanceAfterContentProcessTermination(intent: intent)

        #expect(handled)
        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingPlayVideoId == "v2")
    }

    @Test("Native handoff timeout waits until an advertisement finishes")
    func nativeHandoffTimeoutDefersDuringAdvertisement() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        let generation = self.playerService.pendingNativeQueueAdvanceGeneration
        let fallbackDeadline = self.playerService.pendingNativeQueueAdvance?.fallbackDeadline
        self.playerService.isShowingAd = true

        await self.playerService.handleNativeQueueAdvanceTimeout(generation: generation)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == "v2")
        #expect(self.playerService.pendingNativeQueueAdvance?.fallbackDeadline == fallbackDeadline)
        #expect(self.playerService.currentIndex == 0)

        self.playerService.isShowingAd = false
        await self.playerService.handleNativeQueueAdvanceTimeout(generation: generation)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
    }

    @Test("Native handoff timeout expires during a persistent advertisement")
    func nativeHandoffTimeoutExpiresDuringPersistentAdvertisement() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        let generation = self.playerService.pendingNativeQueueAdvanceGeneration
        let pending = self.playerService.pendingNativeQueueAdvance
        #expect(pending != nil)
        guard let pending else { return }
        self.playerService.pendingNativeQueueAdvance = PendingNativeQueueAdvance(
            sourceEntryID: pending.sourceEntryID,
            sourceVideoId: pending.sourceVideoId,
            targetEntryID: pending.targetEntryID,
            targetVideoId: pending.targetVideoId,
            generation: pending.generation,
            fallbackDeadline: ContinuousClock.now
        )
        self.playerService.isShowingAd = true

        await self.playerService.handleNativeQueueAdvanceTimeout(generation: generation)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
    }

    @Test("Invalid native handoff bypasses advertisement grace")
    func invalidNativeHandoffBypassesAdvertisementGrace() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        let generation = self.playerService.pendingNativeQueueAdvanceGeneration
        self.playerService.advanceRepeatMode()
        self.playerService.advanceRepeatMode()
        self.playerService.isShowingAd = true

        await self.playerService.handleNativeQueueAdvanceTimeout(generation: generation)

        #expect(self.playerService.pendingNativeQueueAdvanceVideoId == nil)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
    }

    @Test("Native maintenance resynchronizes the newly materialized successor")
    func nativeMaintenanceResynchronizesMaterializedSuccessor() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        let successor = Song(id: "3", title: "Song 3", artists: [], duration: 220, videoId: "v3")
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(
            songs: [successor],
            continuationToken: nil
        )
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService[keyPath: \.mixContinuationToken] = "maintenance-continuation"
        self.playerService.beginPendingNativeQueueAdvance(to: 1)

        _ = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(videoId: "v2")
        await Self.waitUntilNativeQueueMaintenanceStarts(mockClient: mockClient)
        let injectionGenerationBeforeCompletion = self.playerService.webQueueInjectionGeneration
        let maintenanceTask = self.playerService.nativeQueueMaintenanceTask

        await continuationGate.open()
        await maintenanceTask?.value

        #expect(self.playerService.queue.map(\.videoId) == ["v1", "v2", "v3"])
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.webQueueInjectionGeneration > injectionGenerationBeforeCompletion)
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

    @Test("Invalidating a mix continuation releases coalesced fetch callers")
    func invalidatingMixContinuationReleasesCoalescedFetchCallers() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let current = Song(
            id: "current",
            title: "Current",
            artists: [],
            duration: 180,
            videoId: "current-video"
        )
        mockClient.mixQueueContinuationGate = continuationGate
        mockClient.mixQueueContinuationResult = RadioQueueResult(
            songs: [],
            continuationToken: nil
        )
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue([current], startingAt: 0)
        self.playerService[keyPath: \.mixContinuationToken] = "retryable-continuation"

        let activeFetch = Task { @MainActor in
            await self.playerService.fetchMoreMixSongsIfNeeded()
        }
        await Self.waitUntilNativeQueueMaintenanceStarts(mockClient: mockClient)

        var coalescedFetchCompleted = false
        let coalescedFetch = Task { @MainActor in
            await self.playerService.fetchMoreMixSongsIfNeeded()
            coalescedFetchCompleted = true
        }
        await Self.waitUntilMixContinuationWaiterIsRegistered(playerService: self.playerService)

        self.playerService.invalidateMixContinuationRequest()
        self.playerService.mixContinuationToken = nil

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while !coalescedFetchCompleted, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(coalescedFetchCompleted)
        #expect(self.playerService.mixContinuationFetchWaiters.isEmpty)
        #expect(mockClient.getMixQueueContinuationCallCount == 1)

        await continuationGate.open()
        await activeFetch.value
        await coalescedFetch.value
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
        let previousWebVideoId = SingletonPlayerWebView.shared.currentVideoId
        defer { SingletonPlayerWebView.shared.currentVideoId = previousWebVideoId }
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService[keyPath: \.mixContinuationToken] = "test-continuation"
        self.playerService.beginPendingNativeQueueAdvance(to: 1)

        let confirmed = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(videoId: "v2")
        #expect(confirmed)
        await Self.waitUntilNativeQueueMaintenanceStarts(mockClient: mockClient)
        let cancelledMaintenance = self.playerService.nativeQueueMaintenanceTask

        await self.playerService.clearQueueEntirely()
        await continuationGate.open()
        await cancelledMaintenance?.value

        #expect(self.playerService.queue.isEmpty)
        #expect(!self.playerService.queue.contains { $0.videoId == "stale-video" })
        #expect(self.playerService.nativeQueueMaintenanceTask == nil)
    }

    @Test("A materialized successor advances before native maintenance completes")
    func materializedSuccessorDoesNotWaitForNativeMaintenance() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 1, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], duration: 220, videoId: "v3"),
        ]
        mockClient.mixQueueContinuationGate = continuationGate
        let previousWebVideoId = SingletonPlayerWebView.shared.currentVideoId
        defer { SingletonPlayerWebView.shared.currentVideoId = previousWebVideoId }
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService[keyPath: \.mixContinuationToken] = "test-continuation"
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        _ = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(videoId: "v2")
        await Self.waitUntilNativeQueueMaintenanceStarts(mockClient: mockClient)
        #expect(mockClient.getMixQueueContinuationCallCount == 1)
        #expect(self.playerService.nativeQueueMaintenanceTask != nil)

        let endedTask = Task { @MainActor in
            await self.playerService.handleTrackEnded(observedVideoId: "v2")
        }
        await Self.waitUntilCurrentIndex(2, playerService: self.playerService)

        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.currentTrack?.videoId == "v3")

        await continuationGate.open()
        await endedTask.value
    }

    @Test("A successor inserted while waiting cancels the maintenance wait")
    func insertedSuccessorUnblocksTrackEndMaintenanceWait() async {
        let mockClient = MockYTMusicClient()
        let continuationGate = AsyncGate()
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 1, videoId: "v2"),
        ]
        let successor = Song(id: "3", title: "Song 3", artists: [], duration: 220, videoId: "v3")
        mockClient.mixQueueContinuationGate = continuationGate
        let previousWebVideoId = SingletonPlayerWebView.shared.currentVideoId
        defer { SingletonPlayerWebView.shared.currentVideoId = previousWebVideoId }
        self.playerService.setYTMusicClient(mockClient)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService[keyPath: \.mixContinuationToken] = "test-continuation"
        self.playerService.beginPendingNativeQueueAdvance(to: 1)
        _ = await self.playerService.reconcilePendingNativeQueueAdvanceObservation(videoId: "v2")
        await Self.waitUntilNativeQueueMaintenanceStarts(mockClient: mockClient)
        #expect(mockClient.getMixQueueContinuationCallCount == 1)

        let endedTask = Task { @MainActor in
            await self.playerService.handleTrackEnded(observedVideoId: "v2")
        }
        let maintenanceGeneration = self.playerService.nativeQueueMaintenanceGeneration
        await Self.waitUntilNativeQueueMaintenanceWaiterIsRegistered(
            generation: maintenanceGeneration,
            playerService: self.playerService
        )
        #expect(self.playerService.nativeQueueMaintenanceWaiters[maintenanceGeneration]?.count == 1)

        self.playerService.appendToQueue([successor])
        await Self.waitUntilCurrentIndex(2, playerService: self.playerService)

        #expect(self.playerService.currentTrack?.videoId == "v3")
        await continuationGate.open()
        await endedTask.value
    }

    @Test("Maintenance-owned successor insertion wakes track end before maintenance completes")
    func maintenanceSuccessorInsertionWakesTrackEndImmediately() async {
        let mutationGate = AsyncGate()
        let completionGate = AsyncGate()
        let current = Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1")
        let successor = Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2")
        let previousWebVideoId = SingletonPlayerWebView.shared.currentVideoId
        defer { SingletonPlayerWebView.shared.currentVideoId = previousWebVideoId }
        await self.playerService.playQueue([current], startingAt: 0)
        self.playerService.nativeQueueMaintenanceGeneration &+= 1
        let maintenanceGeneration = self.playerService.nativeQueueMaintenanceGeneration
        var maintenanceCompleted = false
        let maintenanceTask = Task { @MainActor in
            await mutationGate.wait()
            await NativeQueueMaintenanceContext.$isApplyingQueueMutation.withValue(true) {
                self.playerService.setQueue([current, successor])
                await completionGate.wait()
            }
            maintenanceCompleted = true
        }
        self.playerService.nativeQueueMaintenanceTask = maintenanceTask

        let endedTask = Task { @MainActor in
            await self.playerService.handleTrackEnded(observedVideoId: "v1")
        }
        await Self.waitUntilNativeQueueMaintenanceWaiterIsRegistered(
            generation: maintenanceGeneration,
            playerService: self.playerService
        )
        #expect(self.playerService.nativeQueueMaintenanceWaiters[maintenanceGeneration]?.count == 1)

        await mutationGate.open()
        await Self.waitUntilCurrentIndex(1, playerService: self.playerService)

        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(!maintenanceCompleted)

        await completionGate.open()
        await maintenanceTask.value
        self.playerService.clearNativeQueueMaintenance()
        await endedTask.value
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

    private static func waitUntilCurrentIndex(_ index: Int, playerService: PlayerService) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline {
            if playerService.currentIndex == index {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func waitUntilNativeQueueMaintenanceWaiterIsRegistered(
        generation: Int,
        playerService: PlayerService
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline {
            if playerService.nativeQueueMaintenanceWaiters[generation]?.count == 1 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
