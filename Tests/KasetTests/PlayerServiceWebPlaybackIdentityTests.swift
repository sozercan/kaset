import Foundation
import Testing
@testable import Kaset

// MARK: - PlaybackMediaGenerationCase

struct PlaybackMediaGenerationCase {
    let queueEntryChanged: Bool
    let epoch: Double
    let lastEpoch: Double?
    let generation: Int
    let lastGeneration: Int?
    let expected: Bool
}

// MARK: - PlaybackEndedOccurrenceCase

struct PlaybackEndedOccurrenceCase {
    let epoch: Double
    let lastEpoch: Double?
    let generation: Int
    let lastGeneration: Int?
    let expected: Bool
}

extension PlayerServiceWebQueueSyncTests {
    // MARK: - Web Playback Identity Reconciliation

    @Test(
        "Stale media state after manual Next is rejected before queue recovery",
        arguments: [true, false]
    )
    func staleMediaStateAfterManualNextDoesNotScheduleRecovery(
        establishAcceptedBaseline: Bool
    ) async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing

        let coordinator = SingletonPlayerWebView.Coordinator(playerService: self.playerService)
        let singletonPlayer = SingletonPlayerWebView.shared
        let previousCoordinator = singletonPlayer.coordinator
        singletonPlayer.coordinator = coordinator
        defer {
            self.playerService.clearQueueNavigationRecovery()
            if singletonPlayer.coordinator === coordinator {
                singletonPlayer.coordinator = previousCoordinator
            }
        }

        let staleSourceState: [String: Any] = [
            "isPlaying": true,
            "progress": NSNumber(value: 61.1),
            "duration": NSNumber(value: 180),
            "title": "Song 1",
            "artist": "",
            "thumbnailUrl": "",
            "trackChanged": false,
            "likeStatus": "INDIFFERENT",
            "hasVideo": false,
            "mediaGeneration": 2,
            "observerEpoch": NSNumber(value: 10),
        ]

        if establishAcceptedBaseline {
            // Exercise the common path after the outgoing occurrence has been accepted.
            await coordinator.handleStateUpdate(
                body: staleSourceState,
                observedVideoId: "v1",
                mediaVideoId: "v1",
                observationReceivedAt: ContinuousClock.now,
                messageGeneration: 0
            )
        }

        await self.playerService.next()
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.queueNavigationRecoveryVideoId == nil)
        let navigationGeneration = self.playerService.playbackNavigationGeneration

        // Model a stale frame received during the grace period but processed
        // later because it sat behind the serialized Next operation.
        let navigationStartedAt = ContinuousClock.now - .seconds(2)
        self.playerService.protectedQueueNavigationStartedAt = navigationStartedAt
        let staleObservationReceivedAt = navigationStartedAt + .milliseconds(100)

        // The outgoing video can emit one final paused update after Next. Its
        // unchanged media generation proves that it belongs to the prior queue
        // occurrence, so it must not reach metadata reconciliation/recovery.
        await coordinator.handleStateUpdate(
            body: staleSourceState,
            observedVideoId: "v1",
            mediaVideoId: "v1",
            observationReceivedAt: staleObservationReceivedAt,
            messageGeneration: 0
        )

        #expect(self.playerService.queueNavigationRecoveryVideoId == nil)
        #expect(self.playerService.queueNavigationRecoveryLoadTask == nil)
        #expect(self.playerService.playbackNavigationGeneration == navigationGeneration)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")

        // The first outgoing frame gets a short navigation grace regardless of
        // whether a baseline exists. A persistent mismatch must still reach the
        // existing recovery path after that grace instead of being ignored forever.
        await coordinator.handleStateUpdate(
            body: staleSourceState,
            observedVideoId: "v1",
            mediaVideoId: "v1",
            observationReceivedAt: navigationStartedAt + .seconds(2),
            messageGeneration: 0
        )

        #expect(self.playerService.queueNavigationRecoveryVideoId == "v2")
        #expect(self.playerService.queueNavigationRecoveryLoadTask != nil)
    }

    @Test("Mismatched Web video ID reconciles when bridge trackChanged is false")
    func mismatchedWebVideoIDReconcilesWithoutTrackChangedFlag() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        await self.playerService.next()

        let confirmedTargetShouldApply = self.playerService.reconcileWebPlaybackMetadata(
            title: "Song 2",
            artist: "",
            thumbnailUrl: "",
            observedVideoId: "v2",
            mediaVideoId: "v2",
            bridgeTrackChanged: true
        )
        #expect(confirmedTargetShouldApply)

        let staleEarlierSongShouldApply = self.playerService.reconcileWebPlaybackMetadata(
            title: "Song 1",
            artist: "",
            thumbnailUrl: "",
            observedVideoId: "v1",
            mediaVideoId: "v1",
            bridgeTrackChanged: false
        )

        #expect(!staleEarlierSongShouldApply)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.pendingPlayVideoId == "v2")
    }

    @Test("Logical next metadata cannot advance the queue before media identity changes")
    func logicalNextMetadataWaitsForMediaIdentity() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing

        let shouldApply = self.playerService.reconcileWebPlaybackMetadata(
            title: "Song 2",
            artist: "",
            thumbnailUrl: "",
            observedVideoId: "v2",
            mediaVideoId: "v1",
            bridgeTrackChanged: true
        )

        #expect(shouldApply)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
    }

    @Test("Logical-only next metadata cannot advance the queue before media identity exists")
    func logicalOnlyNextMetadataWaitsForMediaIdentity() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing

        let shouldApply = self.playerService.reconcileWebPlaybackMetadata(
            title: "Song 2",
            artist: "",
            thumbnailUrl: "",
            observedVideoId: "v2",
            mediaVideoId: nil,
            bridgeTrackChanged: true
        )

        #expect(shouldApply)
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "v1")
    }

    @Test("Media identity realigns the queue while logical metadata still lags")
    func mediaIdentityRealignsBeforeLogicalMetadata() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.isKasetInitiatedPlayback = false

        let shouldApply = self.playerService.reconcileWebPlaybackMetadata(
            title: "Song 1",
            artist: "",
            thumbnailUrl: "",
            observedVideoId: "v1",
            mediaVideoId: "v2",
            bridgeTrackChanged: false
        )

        #expect(shouldApply)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.currentTrack?.title == "Song 2")
    }

    @Test("Missing logical identity preserves media-bound queue metadata")
    func missingLogicalIdentityPreservesMediaTargetMetadata() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], duration: 180, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], duration: 200, videoId: "v2"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.isKasetInitiatedPlayback = false

        let shouldApply = self.playerService.reconcileWebPlaybackMetadata(
            title: "Stale Song 1",
            artist: "Stale Artist",
            thumbnailUrl: "",
            observedVideoId: nil,
            mediaVideoId: "v2",
            bridgeTrackChanged: true
        )

        #expect(shouldApply)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
        #expect(self.playerService.currentTrack?.title == "Song 2")
    }

    @Test("Coherent text metadata is applied after an earlier logical lead")
    func coherentMetadataCatchesUpAfterLogicalLead() async {
        let artist = Artist(id: "artist", name: "Old Artist")
        let song = Song(id: "1", title: "Old Title", artists: [artist], duration: 180, videoId: "v1")
        await self.playerService.playQueue([song], startingAt: 0)
        self.playerService.state = .playing
        self.playerService.isKasetInitiatedPlayback = false

        _ = self.playerService.reconcileWebPlaybackMetadata(
            title: "New Title",
            artist: "New Artist",
            thumbnailUrl: "",
            observedVideoId: "logical-lead",
            mediaVideoId: "v1",
            bridgeTrackChanged: true
        )
        let shouldApply = self.playerService.reconcileWebPlaybackMetadata(
            title: "New Title",
            artist: "New Artist",
            thumbnailUrl: "",
            observedVideoId: "v1",
            mediaVideoId: "v1",
            bridgeTrackChanged: false
        )

        #expect(shouldApply)
        #expect(self.playerService.currentTrack?.title == "New Title")
        #expect(self.playerService.currentTrack?.artistsDisplay == "New Artist")
    }

    @Test("Admissible next Web video realigns queue when bridge trackChanged is false")
    func nextWebVideoRealignsWithoutTrackChangedFlag() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing

        let currentSongShouldApply = self.playerService.reconcileWebPlaybackMetadata(
            title: "Song 1",
            artist: "",
            thumbnailUrl: "",
            observedVideoId: "v1",
            mediaVideoId: "v1",
            bridgeTrackChanged: true
        )
        #expect(currentSongShouldApply)

        let nextSongShouldApply = self.playerService.reconcileWebPlaybackMetadata(
            title: "Song 2",
            artist: "",
            thumbnailUrl: "",
            observedVideoId: "v2",
            mediaVideoId: "v2",
            bridgeTrackChanged: false
        )

        #expect(nextSongShouldApply)
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "v2")
    }

    @Test("Playback state from an earlier Web video cannot overwrite the queue target")
    func earlierWebVideoPlaybackStateDoesNotOverwriteQueueTarget() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        await self.playerService.next()

        self.playerService.updatePlaybackState(
            isPlaying: false,
            progress: 179,
            duration: 180,
            observedVideoId: "v1"
        )

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.progress == 0)
        #expect(self.playerService.duration == 200)
        #expect(!self.playerService.songNearingEnd)

        let identitylessLogicalObservationShouldContinue = self.playerService.reconcileWebPlaybackMetadata(
            title: "",
            artist: "",
            thumbnailUrl: "",
            observedVideoId: nil,
            bridgeTrackChanged: false
        )
        #expect(identitylessLogicalObservationShouldContinue)
        #expect(self.playerService.observedPlaybackMatchesCurrentTarget(videoId: "v2"))

        self.playerService.updatePlaybackState(
            isPlaying: false,
            progress: 179,
            duration: 180,
            observedVideoId: nil
        )

        #expect(self.playerService.progress == 0)
        #expect(self.playerService.duration == 200)
        #expect(!self.playerService.songNearingEnd)

        self.playerService.updatePlaybackState(
            isPlaying: true,
            progress: 1,
            duration: 200,
            observedVideoId: "v2"
        )

        #expect(self.playerService.state == .playing)
        #expect(self.playerService.progress == 1)
        #expect(self.playerService.duration == 200)
    }

    @Test(
        "Accepted Web video transition detection distinguishes initial confirmation from a real change",
        arguments: [
            (observed: "v2", lastAccepted: String?.none, expectedBefore: Optional("v2"), expected: false),
            (observed: "v2", lastAccepted: String?.none, expectedBefore: Optional("v1"), expected: true),
            (observed: "v2", lastAccepted: Optional("v1"), expectedBefore: Optional("v2"), expected: true),
            (observed: "v2", lastAccepted: Optional("v2"), expectedBefore: Optional("v2"), expected: false),
        ]
    )
    func acceptedWebVideoTransitionDetection(
        observed: String,
        lastAccepted: String?,
        expectedBefore: String?,
        expected: Bool
    ) {
        #expect(WebPlaybackIdentityTransition.isConfirmed(
            observedVideoId: observed,
            lastAcceptedObservedVideoId: lastAccepted,
            expectedVideoIdBeforeReconciliation: expectedBefore
        ) == expected)
    }

    @Test(
        "Playback media generation must advance when the queue entry changes",
        arguments: [
            PlaybackMediaGenerationCase(queueEntryChanged: false, epoch: 10, lastEpoch: 10, generation: 4, lastGeneration: 4, expected: true),
            PlaybackMediaGenerationCase(queueEntryChanged: true, epoch: 11, lastEpoch: 10, generation: 4, lastGeneration: 4, expected: true),
            PlaybackMediaGenerationCase(queueEntryChanged: true, epoch: 10, lastEpoch: 10, generation: 4, lastGeneration: 4, expected: false),
            PlaybackMediaGenerationCase(queueEntryChanged: true, epoch: 10, lastEpoch: 10, generation: 5, lastGeneration: 4, expected: true),
            PlaybackMediaGenerationCase(queueEntryChanged: false, epoch: 9, lastEpoch: 10, generation: 5, lastGeneration: 4, expected: false),
            PlaybackMediaGenerationCase(queueEntryChanged: false, epoch: 10, lastEpoch: 10, generation: 3, lastGeneration: 4, expected: false),
        ]
    )
    func playbackMediaGenerationGate(testCase: PlaybackMediaGenerationCase) {
        #expect(WebPlaybackIdentityTransition.shouldAcceptMediaState(
            queueEntryChanged: testCase.queueEntryChanged,
            observerEpoch: testCase.epoch,
            lastAcceptedObserverEpoch: testCase.lastEpoch,
            mediaGeneration: testCase.generation,
            lastAcceptedMediaGeneration: testCase.lastGeneration
        ) == testCase.expected)
    }

    @Test(
        "Ended occurrences are consumed once per observer epoch and media generation",
        arguments: [
            PlaybackEndedOccurrenceCase(epoch: 10, lastEpoch: nil, generation: 4, lastGeneration: nil, expected: true),
            PlaybackEndedOccurrenceCase(epoch: 10, lastEpoch: 10, generation: 4, lastGeneration: 4, expected: false),
            PlaybackEndedOccurrenceCase(epoch: 10, lastEpoch: 10, generation: 3, lastGeneration: 4, expected: false),
            PlaybackEndedOccurrenceCase(epoch: 10, lastEpoch: 10, generation: 5, lastGeneration: 4, expected: true),
            PlaybackEndedOccurrenceCase(epoch: 11, lastEpoch: 10, generation: 0, lastGeneration: 4, expected: true),
            PlaybackEndedOccurrenceCase(epoch: 9, lastEpoch: 10, generation: 8, lastGeneration: 4, expected: false),
        ]
    )
    func endedOccurrenceGate(testCase: PlaybackEndedOccurrenceCase) {
        #expect(WebPlaybackIdentityTransition.shouldAcceptEndedOccurrence(
            observerEpoch: testCase.epoch,
            lastHandledObserverEpoch: testCase.lastEpoch,
            mediaGeneration: testCase.generation,
            lastHandledMediaGeneration: testCase.lastGeneration
        ) == testCase.expected)
    }

    @Test(
        "Deferred restore handles only fully identityless observations",
        arguments: [
            (isDeferred: true, logical: String?.none, media: String?.none, expected: true),
            (isDeferred: false, logical: String?.none, media: String?.none, expected: false),
            (isDeferred: true, logical: Optional("v1"), media: String?.none, expected: false),
            (isDeferred: true, logical: String?.none, media: Optional("v1"), expected: false),
        ]
    )
    func deferredIdentitylessObservationGate(
        isDeferred: Bool,
        logical: String?,
        media: String?,
        expected: Bool
    ) {
        #expect(WebPlaybackIdentityTransition.shouldHandleDeferredIdentitylessObservation(
            isDeferred: isDeferred,
            observedVideoId: logical,
            mediaVideoId: media
        ) == expected)
    }

    @Test("Accepted nil queue-entry baseline detects a later queued entry")
    func nilQueueEntryBaselineDetectsQueuedEntry() {
        let entryID = UUID()

        #expect(!WebPlaybackIdentityTransition.didQueueEntryChange(
            hasBaseline: false,
            lastAcceptedQueueEntryID: nil,
            currentQueueEntryID: entryID
        ))
        #expect(WebPlaybackIdentityTransition.didQueueEntryChange(
            hasBaseline: true,
            lastAcceptedQueueEntryID: nil,
            currentQueueEntryID: entryID
        ))
        #expect(!WebPlaybackIdentityTransition.didQueueEntryChange(
            hasBaseline: true,
            lastAcceptedQueueEntryID: entryID,
            currentQueueEntryID: entryID
        ))
    }
}
