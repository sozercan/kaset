// swiftlint:disable file_length

import Foundation
import Testing
@testable import Kaset

@Suite("Player service playback intents", .serialized, .tags(.service))
@MainActor
struct PlayerServicePlaybackIntentTests { // swiftlint:disable:this type_body_length
    @Test("A newer reservation invalidates an older unclaimed request")
    func newerReservationWinsBeforePlaybackChanges() {
        let playerService = PlayerService()
        let older = playerService.reserveMusicPlaybackIntent()
        let newer = playerService.reserveMusicPlaybackIntent()

        #expect(playerService.claimMusicPlaybackIntent(older) == nil)
        #expect(playerService.claimMusicPlaybackIntent(newer) != nil)
    }

    @Test("Track-specific validation rejects drift while a generic claim remains valid")
    func reservationSeparatesValidationFromClaiming() {
        let playerService = PlayerService()
        playerService.currentTrack = self.makeSong(id: "first")
        let reservation = playerService.reserveMusicPlaybackIntent()

        playerService.currentTrack = self.makeSong(id: "second")

        #expect(!playerService.acceptsMusicPlaybackReservation(reservation))
        #expect(playerService.claimMusicPlaybackIntent(reservation) != nil)
    }

    @Test("Bridge events use sub-millisecond ordering around the current intent")
    func bridgeEventTimeCannotAdoptNewerIntent() {
        let playerService = PlayerService()
        let intent = playerService.beginMusicPlaybackIntent()
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000.25

        #expect(!playerService.acceptsMusicBridgeEvent(
            intent: intent,
            eventIssuedAtMilliseconds: 1000.20
        ))
        #expect(!playerService.acceptsMusicBridgeEvent(
            intent: intent,
            eventIssuedAtMilliseconds: 1000.25
        ))
        #expect(playerService.acceptsMusicBridgeEvent(
            intent: intent,
            eventIssuedAtMilliseconds: 1000.75
        ))
    }

    @Test("Queue-only reservation survives pause but not queue replacement")
    func queueReservationIgnoresTransportIntent() async {
        let playerService = PlayerService()
        await playerService.playQueue([self.makeSong(id: "initial")], startingAt: 0)
        let queueGeneration = playerService.reserveQueueMutation()

        await playerService.pause()
        #expect(playerService.acceptsQueueMutation(queueGeneration))

        await playerService.playQueue([self.makeSong(id: "replacement")], startingAt: 0)
        #expect(!playerService.acceptsQueueMutation(queueGeneration))
    }

    @Test("Rapid remote commands execute in admission order under one intent")
    func remoteCommandAdmissionOrdersIntents() async {
        let playerService = PlayerService()
        await playerService.playQueue([
            self.makeSong(id: "first"),
            self.makeSong(id: "second"),
            self.makeSong(id: "third"),
        ], startingAt: 0)
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000

        let initialIntent = playerService.currentMusicPlaybackIntent
        #expect(playerService.acceptsMusicRemoteCommand(
            intent: initialIntent,
            commandIssuedAtMilliseconds: 1001
        ))
        playerService.enqueueRemoteMusicTransportCommand(.next, issuedAtMilliseconds: 1001)

        let batchIntent = playerService.currentMusicPlaybackIntent
        #expect(playerService.acceptsMusicRemoteCommand(
            intent: batchIntent,
            commandIssuedAtMilliseconds: 1001
        ))
        playerService.enqueueRemoteMusicTransportCommand(.next, issuedAtMilliseconds: 1001)

        let task = playerService.remoteMusicTransportTask
        await task?.value

        #expect(playerService.currentIndex == 2)
        #expect(playerService.currentTrack?.videoId == "third")
    }

    @Test("Overlapping remote skips preserve every delta in admission order")
    func overlappingRemoteSkipsPreserveEveryDelta() async {
        let (playerService, _) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let song = self.makeSong(id: "remote-skip")
        await playerService.playQueue([song], startingAt: 0)
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000
        playerService.progress = 10
        playerService.duration = 100
        let firstSnapshotStarted = AsyncGate()
        let releaseFirstSnapshot = AsyncGate()
        var snapshotCallCount = 0
        playerService.currentMusicPlaybackSnapshot = {
            snapshotCallCount += 1
            if snapshotCallCount == 1 {
                await firstSnapshotStarted.open()
                await releaseFirstSnapshot.wait()
            }
            return SingletonPlayerWebView.PlaybackSnapshot(
                progress: 10,
                duration: 100,
                videoId: song.videoId
            )
        }
        let admittedAt = ContinuousClock.now

        playerService.enqueueRemoteMusicTransportCommand(
            .relativeSeek(delta: -15, admittedAt: admittedAt),
            issuedAtMilliseconds: 1001
        )
        let batchIntent = playerService.currentMusicPlaybackIntent
        await firstSnapshotStarted.wait()
        playerService.enqueueRemoteMusicTransportCommand(
            .relativeSeek(delta: 15, admittedAt: admittedAt),
            issuedAtMilliseconds: 1002
        )
        #expect(playerService.currentMusicPlaybackIntent == batchIntent)
        let remoteTask = playerService.remoteMusicTransportTask

        await releaseFirstSnapshot.open()
        await remoteTask?.value

        #expect(snapshotCallCount == 2)
        #expect(playerService.progress == 15)
        #expect(playerService.remoteMusicTransportCommands.isEmpty)
        #expect(playerService.remoteMusicTransportIntent == nil)
    }

    @Test("Remote Next commands do not wait for intermediate metadata")
    func remoteNextCommandsDoNotWaitForIntermediateMetadata() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let first = self.makeSong(id: "metadata-first")
        let second = Song(
            id: "metadata-second",
            title: "metadata-second",
            artists: [],
            duration: 180,
            videoId: "metadata-second"
        )
        let third = Song(
            id: "metadata-third",
            title: "metadata-third",
            artists: [],
            duration: 180,
            videoId: "metadata-third"
        )
        mockClient.songResponses[third.videoId] = self.makeSong(id: third.id)
        await playerService.playQueue([first, second, third], startingAt: 0)
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000
        let thirdEntryID = playerService.queueEntryIDs[2]
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        mockClient.beforeGetSongReturn = { _ in
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        playerService.enqueueRemoteMusicTransportCommand(
            .next,
            issuedAtMilliseconds: 1001
        )
        playerService.enqueueRemoteMusicTransportCommand(
            .next,
            issuedAtMilliseconds: 1002
        )
        await metadataStarted.wait()

        #expect(playerService.currentIndex == 2)
        #expect(playerService.activePlaybackQueueEntryID == thirdEntryID)
        #expect(playerService.currentTrack?.videoId == third.videoId)
        #expect(mockClient.getSongVideoIds == [third.videoId])

        let metadataTask = playerService.remoteMusicMetadataFollowUpTask
        await releaseMetadata.open()
        await metadataTask?.value
        #expect(playerService.currentTrack?.videoId == third.videoId)
    }

    @Test("Remote Next commands do not wait for materialized mix prefetch")
    func remoteNextCommandsDoNotWaitForMixPrefetch() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let queue = [
            self.makeSong(id: "prefetch-first"),
            self.makeSong(id: "prefetch-second"),
            self.makeSong(id: "prefetch-third"),
            self.makeSong(id: "prefetch-fourth"),
        ]
        let appended = self.makeSong(id: "prefetch-appended")
        await playerService.playQueue(queue, startingAt: 0)
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000
        let thirdEntryID = playerService.queueEntryIDs[2]
        playerService[keyPath: \.mixContinuationToken] = "mock-token"
        mockClient.mixQueueContinuationResult = RadioQueueResult(
            songs: [appended],
            continuationToken: nil
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.beforeMixQueueContinuationReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        playerService.enqueueRemoteMusicTransportCommand(
            .next,
            issuedAtMilliseconds: 1001
        )
        playerService.enqueueRemoteMusicTransportCommand(
            .next,
            issuedAtMilliseconds: 1002
        )
        await requestStarted.wait()

        #expect(playerService.currentIndex == 2)
        #expect(playerService.activePlaybackQueueEntryID == thirdEntryID)
        #expect(playerService.currentTrack?.videoId == queue[2].videoId)

        let queueTask = playerService.remoteMusicQueueFollowUpTask
        await releaseRequest.open()
        await queueTask?.value

        #expect(playerService.currentTrack?.videoId == queue[2].videoId)
        #expect(playerService.queue.contains { $0.videoId == appended.videoId })
        #expect(mockClient.getMixQueueContinuationCallCount == 1)
    }

    @Test("A newer native seek invalidates pending remote skips")
    func newerNativeSeekInvalidatesPendingRemoteSkips() async {
        let (playerService, _) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let song = self.makeSong(id: "stale-remote-skip")
        await playerService.playQueue([song], startingAt: 0)
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 1000
        playerService.progress = 10
        playerService.duration = 100
        let snapshotStarted = AsyncGate()
        let releaseSnapshot = AsyncGate()
        playerService.currentMusicPlaybackSnapshot = {
            await snapshotStarted.open()
            await releaseSnapshot.wait()
            return SingletonPlayerWebView.PlaybackSnapshot(
                progress: 10,
                duration: 100,
                videoId: song.videoId
            )
        }

        playerService.enqueueRemoteMusicTransportCommand(
            .relativeSeek(delta: 15, admittedAt: ContinuousClock.now),
            issuedAtMilliseconds: 1001
        )
        let batchIntent = playerService.currentMusicPlaybackIntent
        let remoteTask = playerService.remoteMusicTransportTask
        await snapshotStarted.wait()

        await playerService.seek(to: 60)
        #expect(playerService.currentMusicPlaybackIntent != batchIntent)
        await releaseSnapshot.open()
        await remoteTask?.value

        #expect(playerService.progress == 60)
        #expect(playerService.remoteMusicTransportCommands.isEmpty)
        #expect(playerService.remoteMusicTransportIntent == nil)
    }

    @Test("A disappeared queue entry cannot claim a playback reservation")
    func disappearedQueueEntryCannotClaimPlaybackReservation() async {
        let playerService = PlayerService()
        let current = self.makeSong(id: "reservation-current")
        let target = self.makeSong(id: "reservation-target")
        await playerService.playQueue([current, target], startingAt: 0)
        let targetEntryID = playerService.queueEntryIDs[1]
        let reservation = playerService.reserveMusicPlaybackIntent()
        let intent = playerService.currentMusicPlaybackIntent
        playerService.removeFromQueue(entryIDs: [targetEntryID])

        let claimedIntent = playerService.claimMusicPlaybackIntent(
            reservation,
            queueEntryID: targetEntryID
        )

        #expect(claimedIntent == nil)
        #expect(playerService.currentMusicPlaybackIntent == intent)
        #expect(playerService.currentTrack?.videoId == current.videoId)
    }

    @Test("Mock player service preserves production ownership transitions")
    func mockPlayerServiceOwnershipContract() async throws {
        let mock = MockPlayerService()
        let playbackReservation = mock.reserveMusicPlaybackIntent()
        await mock.pause()
        #expect(mock.claimMusicPlaybackIntent(playbackReservation) == nil)

        let queueReservation = mock.reserveMusicPlaybackIntent()
        let intent = try #require(mock.claimMusicPlaybackIntent(queueReservation))
        let queueGeneration = mock.reserveQueueMutation()
        let loadGeneration = await mock.playQueue(
            [self.makeSong(id: "mock-replacement")],
            startingAt: 0,
            deferringSmartShuffleFill: true,
            intent: intent
        )
        #expect(!mock.acceptsQueueMutation(queueGeneration))
        #expect(loadGeneration != nil)
        if let loadGeneration {
            #expect(mock.acceptsQueueMutation(loadGeneration))
        }

        let mixReservation = mock.reserveMusicPlaybackIntent()
        await mock.playWithMix(playlistId: "RDEM-mock", startVideoId: nil)
        #expect(mock.claimMusicPlaybackIntent(mixReservation) == nil)
    }

    @Test("Remote transport backlog is bounded while a command is pending")
    func remoteTransportBacklogIsBounded() {
        let playerService = PlayerService()
        playerService.musicPlaybackIntentIssuedAtMilliseconds = 0
        playerService.enqueueRemoteMusicTransportCommand(.next, issuedAtMilliseconds: 1)
        for offset in 2 ... 200 {
            playerService.enqueueRemoteMusicTransportCommand(
                .next,
                issuedAtMilliseconds: Double(offset)
            )
        }

        let pendingCount = playerService.remoteMusicTransportCommands.count
            - playerService.remoteMusicTransportCommandReadIndex
        #expect(pendingCount <= 64)
        _ = playerService.beginMusicPlaybackIntent()
    }

    @Test("A stale clear intent cannot erase a newer queue")
    func staleClearIntentCannotEraseNewerQueue() async {
        let playerService = PlayerService()
        let staleClearIntent = playerService.beginMusicPlaybackIntent()
        let replacement = self.makeSong(id: "replacement")
        await playerService.playQueue([replacement], startingAt: 0)
        let replacementEntryIDs = playerService.queueEntryIDs

        playerService.clearQueueEntriesAfterStop(intent: staleClearIntent)

        #expect(playerService.queue == [replacement])
        #expect(playerService.queueEntryIDs == replacementEntryIDs)
    }

    @Test("A delayed mix cannot replace a newer direct queue")
    func delayedMixCannotReplaceNewerDirectQueue() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.mixQueueResult = RadioQueueResult(
            songs: [self.makeSong(id: "stale-mix")],
            continuationToken: "stale-mix-token"
        )
        mockClient.beforeMixQueueReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let mixTask = Task { @MainActor in
            await playerService.playWithMix(playlistId: "RDEM-stale", startVideoId: nil)
        }
        await requestStarted.wait()

        let replacementSongs = [
            self.makeSong(id: "replacement-current"),
            self.makeSong(id: "replacement-next"),
        ]
        await playerService.playQueue(replacementSongs, startingAt: 0)
        let replacementEntryIDs = playerService.queueEntryIDs

        await releaseRequest.open()
        await mixTask.value

        #expect(playerService.queue == replacementSongs)
        #expect(playerService.queueEntryIDs == replacementEntryIDs)
        #expect(playerService.currentTrack == replacementSongs[0])
        #expect(playerService.mixContinuationToken == nil)
    }

    @Test("Undo after a delayed mix restores queue edits admitted while pending")
    func delayedMixUndoCapturesCommitTimeQueue() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let original = self.makeSong(id: "mix-history-original")
        let appended = self.makeSong(id: "mix-history-appended")
        let mixSong = self.makeSong(id: "mix-history-result")
        await playerService.playQueue([original], startingAt: 0)
        playerService.clearQueueUndoRedoHistory()
        mockClient.mixQueueResult = RadioQueueResult(
            songs: [mixSong],
            continuationToken: "mix-history-token"
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.beforeMixQueueReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let mixTask = Task { @MainActor in
            await playerService.playWithMix(
                playlistId: "RDEM-history",
                startVideoId: nil
            )
        }
        await requestStarted.wait()
        let pendingIntent = playerService.currentMusicPlaybackIntent
        let queueGeneration = playerService.reserveQueueMutation()
        playerService.appendToQueue([appended])
        let editedEntryIDs = playerService.queueEntryIDs

        #expect(playerService.acceptsMusicPlaybackIntent(pendingIntent))
        #expect(playerService.acceptsQueueMutation(queueGeneration))
        await releaseRequest.open()
        await mixTask.value
        await playerService.undoQueue()

        #expect(playerService.queue.map(\.videoId) == [original.videoId, appended.videoId])
        #expect(playerService.queueEntryIDs == editedEntryIDs)
    }

    @Test("A transport intent cannot orphan a committed mix queue")
    func transportIntentCannotOrphanCommittedMixQueue() async {
        let (playerService, mockClient) = self.makePlayerService()
        let persistenceSuiteName = "com.kaset.tests.mix-persistence.\(UUID().uuidString)"
        guard let persistenceDefaults = UserDefaults(suiteName: persistenceSuiteName) else {
            Issue.record("Unable to create isolated queue persistence defaults")
            return
        }
        persistenceDefaults.removePersistentDomain(forName: persistenceSuiteName)
        playerService.queuePersistenceDefaults = persistenceDefaults
        defer {
            playerService.clearSavedQueue()
            persistenceDefaults.removePersistentDomain(forName: persistenceSuiteName)
            self.resetSingletonPlayer()
        }
        let original = self.makeSong(id: "mix-persist-original")
        let mixSong = Song(
            id: "mix-persist-result",
            title: "Mix Persist Result",
            artists: [],
            duration: 180,
            videoId: "mix-persist-result"
        )
        await playerService.playQueue([original], startingAt: 0)
        mockClient.mixQueueResult = RadioQueueResult(
            songs: [mixSong],
            continuationToken: "mix-persist-token"
        )
        mockClient.songResponses[mixSong.videoId] = mixSong
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        mockClient.beforeGetSongReturn = { videoID in
            guard videoID == mixSong.videoId else { return }
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        let mixTask = Task { @MainActor in
            await playerService.playWithMix(
                playlistId: "RDEM-persist",
                startVideoId: nil
            )
        }
        await metadataStarted.wait()
        await playerService.pause()
        mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        await releaseMetadata.open()
        await mixTask.value

        #expect(playerService.queue.map(\.videoId) == [mixSong.videoId])
        let restored = PlayerService()
        restored.queuePersistenceDefaults = persistenceDefaults
        #expect(restored.restoreQueueFromPersistence())
        #expect(restored.queue.map(\.videoId) == [mixSong.videoId])
    }

    @Test("An empty mix response does not create queue undo history")
    func emptyMixDoesNotCreateUndoHistory() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        playerService.clearQueueUndoRedoHistory()
        mockClient.mixQueueResult = RadioQueueResult(songs: [], continuationToken: nil)

        await playerService.playWithMix(playlistId: "RDEM-empty", startVideoId: nil)

        #expect(!playerService.canUndoQueue)
    }

    @Test("A delayed mix cannot resurrect playback after a fully awaited stop")
    func delayedMixCannotResurrectAfterStop() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.mixQueueResult = RadioQueueResult(
            songs: [self.makeSong(id: "stale-mix")],
            continuationToken: "stale-mix-token"
        )
        mockClient.beforeMixQueueReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let mixTask = Task { @MainActor in
            await playerService.playWithMix(playlistId: "RDEM-stale", startVideoId: nil)
        }
        await requestStarted.wait()

        await playerService.stop()
        #expect(playerService.state == .idle)
        #expect(playerService.currentTrack == nil)
        #expect(playerService.pendingPlayVideoId == nil)

        await releaseRequest.open()
        await mixTask.value

        #expect(playerService.state == .idle)
        #expect(playerService.queue.isEmpty)
        #expect(playerService.currentTrack == nil)
        #expect(playerService.pendingPlayVideoId == nil)
        #expect(playerService.mixContinuationToken == nil)
    }

    @Test("Verified identity switch invalidates idle playback work and queue history")
    func identitySwitchInvalidatesPendingMixAndHistory() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        await playerService.playQueue([self.makeSong(id: "history-a")], startingAt: 0)
        await playerService.playQueue([self.makeSong(id: "history-b")], startingAt: 0)
        #expect(playerService.canUndoQueue)
        await playerService.stop()
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.mixQueueResult = RadioQueueResult(
            songs: [self.makeSong(id: "stale-account-mix")],
            continuationToken: nil
        )
        mockClient.beforeMixQueueReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        let mixTask = Task { @MainActor in
            await playerService.playWithMix(playlistId: "RDEM-account", startVideoId: nil)
        }
        await requestStarted.wait()

        playerService.reloadCurrentTrackForIdentitySwitch()
        await releaseRequest.open()
        await mixTask.value

        #expect(!playerService.canUndoQueue)
        #expect(playerService.queue == [self.makeSong(id: "history-b")])
        #expect(playerService.currentTrack == nil)
        #expect(playerService.mixContinuationToken == nil)
    }

    @Test("Queue shuffle supersedes an older pending mix")
    func shuffleSupersedesPendingMix() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let originalSongs = [
            self.makeSong(id: "one"),
            self.makeSong(id: "two"),
            self.makeSong(id: "three"),
        ]
        await playerService.playQueue(originalSongs, startingAt: 0)
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.mixQueueResult = RadioQueueResult(
            songs: [self.makeSong(id: "stale")],
            continuationToken: nil
        )
        mockClient.beforeMixQueueReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let mixTask = Task { @MainActor in
            await playerService.playWithMix(playlistId: "RDEM-stale", startVideoId: nil)
        }
        await requestStarted.wait()
        playerService.shuffleQueue()
        let shuffledEntryIDs = Set(playerService.queueEntryIDs)
        await releaseRequest.open()
        await mixTask.value

        #expect(Set(playerService.queueEntryIDs) == shuffledEntryIDs)
        #expect(Set(playerService.queue.map(\.videoId)) == Set(originalSongs.map(\.videoId)))
    }

    @Test("Player-bar shuffle cycling supersedes an older pending mix")
    func cycleShuffleSupersedesPendingMix() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let originalSongs = self.makeSong(id: "cycle-one")
        await playerService.playQueue([originalSongs, self.makeSong(id: "cycle-two")], startingAt: 0)
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.mixQueueResult = RadioQueueResult(
            songs: [self.makeSong(id: "cycle-stale")],
            continuationToken: nil
        )
        mockClient.beforeMixQueueReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        let mixTask = Task { @MainActor in
            await playerService.playWithMix(playlistId: "RDEM-cycle", startVideoId: nil)
        }
        await requestStarted.wait()

        playerService.smartShuffleFeatureEnabled = { true }
        playerService.cycleShuffleMode()
        let retainedVideoIDs = Set(playerService.queue.map(\.videoId))
        await releaseRequest.open()
        await mixTask.value

        #expect(Set(playerService.queue.map(\.videoId)) == retainedVideoIDs)
        #expect(!playerService.queue.contains(where: { $0.videoId == "cycle-stale" }))
    }

    @Test("A stale same-video radio result cannot replace a newer queue entry")
    func staleSameVideoRadioCannotReplaceNewerQueueEntry() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        let seed = self.makeSong(id: "shared-song", videoId: "shared-video")
        let staleRadioSong = self.makeSong(id: "stale-radio")
        mockClient.radioQueueSongs[seed.videoId] = [seed, staleRadioSong]
        mockClient.beforeRadioQueueReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let radioTask = Task { @MainActor in
            await playerService.playWithRadio(song: seed)
        }
        await requestStarted.wait()

        let replacementSongs = [
            seed,
            self.makeSong(id: "replacement-next"),
        ]
        await playerService.playQueue(replacementSongs, startingAt: 0)
        let replacementEntryIDs = playerService.queueEntryIDs

        await releaseRequest.open()
        await radioTask.value

        #expect(playerService.queue == replacementSongs)
        #expect(playerService.queueEntryIDs == replacementEntryIDs)
        #expect(playerService.currentQueueEntryID == replacementEntryIDs[0])
        #expect(playerService.currentTrack == seed)
    }

    @Test("Radio expansion preserves the active seed entry identity")
    func radioExpansionPreservesSeedEntryIdentity() async throws {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        let seed = self.makeSong(id: "seed")
        mockClient.radioQueueSongs[seed.videoId] = [
            seed,
            self.makeSong(id: "related"),
        ]
        mockClient.beforeRadioQueueReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let radioTask = Task { @MainActor in
            await playerService.playWithRadio(song: seed)
        }
        await requestStarted.wait()
        let seedEntryID = try #require(playerService.activePlaybackQueueEntryID)
        #expect(playerService.currentQueueEntryID == seedEntryID)

        await releaseRequest.open()
        await radioTask.value

        #expect(playerService.queueEntryIDs.first == seedEntryID)
        #expect(playerService.currentQueueEntryID == seedEntryID)
        #expect(playerService.activePlaybackQueueEntryID == seedEntryID)
    }

    @Test("Pausing does not cancel queue-owned radio expansion")
    func pausePreservesPendingRadioExpansion() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        let seed = self.makeSong(id: "seed")
        let related = self.makeSong(id: "related")
        mockClient.radioQueueSongs[seed.videoId] = [seed, related]
        mockClient.beforeRadioQueueReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let radioTask = Task { @MainActor in
            await playerService.playWithRadio(song: seed)
        }
        await requestStarted.wait()
        await playerService.pause()
        await releaseRequest.open()
        await radioTask.value

        #expect(playerService.queue.map(\.videoId).contains(related.videoId))
        #expect(playerService.state == .paused)
    }

    @Test("Radio expansion preserves queue edits made while the request is pending")
    func radioExpansionMergesPendingQueueEdits() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        let seed = self.makeSong(id: "seed")
        let userAdded = self.makeSong(id: "user-added")
        let related = self.makeSong(id: "related")
        mockClient.radioQueueSongs[seed.videoId] = [seed, related]
        mockClient.beforeRadioQueueReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let radioTask = Task { @MainActor in
            await playerService.playWithRadio(song: seed)
        }
        await requestStarted.wait()
        playerService.toggleShuffle()
        playerService.appendToQueue([userAdded])
        await releaseRequest.open()
        await radioTask.value

        #expect(playerService.queue.map(\.videoId).contains(userAdded.videoId))
        #expect(playerService.queue.map(\.videoId).contains(related.videoId))
        #expect(playerService.activePlaybackQueueEntryID == playerService.currentQueueEntryID)
        #expect(playerService.queueOrderBeforeShuffle?.map(\.song.videoId) == [
            seed.videoId,
            userAdded.videoId,
            related.videoId,
        ])
        playerService.toggleShuffle()
        #expect(playerService.queue.map(\.videoId) == [
            seed.videoId,
            userAdded.videoId,
            related.videoId,
        ])
    }

    @Test("Pending shuffled radio expansion does not resurrect removed entries")
    func radioExpansionPreservesRemovalFromShuffledQueue() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let seed = self.makeSong(id: "radio-seed")
        let removed = self.makeSong(id: "radio-removed")
        let related = self.makeSong(id: "radio-related")
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.radioQueueSongs[seed.videoId] = [related]
        mockClient.beforeRadioQueueReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let radioTask = Task { @MainActor in
            await playerService.playWithRadio(song: seed)
        }
        await requestStarted.wait()
        playerService.appendToQueue([removed])
        playerService.setShuffleMode(.on)
        let removedEntryID = try? #require(
            playerService.queueEntries.first(where: { $0.song.videoId == removed.videoId })?.id
        )
        if let removedEntryID {
            playerService.removeFromQueue(entryIDs: [removedEntryID])
        }
        await releaseRequest.open()
        await radioTask.value

        #expect(!playerService.queue.contains(where: { $0.videoId == removed.videoId }))
        #expect(playerService.queue.contains(where: { $0.videoId == related.videoId }))
    }

    @Test("A stale mix continuation cannot append or restore its token after queue replacement")
    func staleMixContinuationCannotMutateReplacementQueue() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        let initialSongs = [
            self.makeSong(id: "initial-current"),
            self.makeSong(id: "initial-next"),
        ]
        await playerService.playQueue(initialSongs, startingAt: 1)
        playerService[keyPath: \.mixContinuationToken] = "mock-token"
        mockClient.mixQueueContinuationResult = RadioQueueResult(
            songs: [self.makeSong(id: "stale-continuation-song")],
            continuationToken: "REDACTED"
        )
        mockClient.beforeMixQueueContinuationReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let continuationTask = Task { @MainActor in
            await playerService.fetchMoreMixSongsIfNeeded()
        }
        await requestStarted.wait()

        let replacementSongs = [
            self.makeSong(id: "replacement-current"),
            self.makeSong(id: "replacement-next"),
        ]
        await playerService.playQueue(replacementSongs, startingAt: 0)
        let replacementEntryIDs = playerService.queueEntryIDs
        #expect(playerService.mixContinuationToken == nil)

        await releaseRequest.open()
        await continuationTask.value

        #expect(playerService.queue == replacementSongs)
        #expect(playerService.queueEntryIDs == replacementEntryIDs)
        #expect(playerService.mixContinuationToken == nil)
    }

    @Test("Pausing preserves queue-owned mix continuation work")
    func pausePreservesMixContinuation() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        await playerService.playQueue([self.makeSong(id: "current")], startingAt: 0)
        playerService[keyPath: \.mixContinuationToken] = "mock-token"
        mockClient.mixQueueContinuationResult = RadioQueueResult(
            songs: [self.makeSong(id: "later")],
            continuationToken: nil
        )
        mockClient.beforeMixQueueContinuationReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let firstFetch = Task { @MainActor in
            await playerService.fetchMoreMixSongsIfNeeded()
        }
        await requestStarted.wait()
        await playerService.pause()
        await releaseRequest.open()
        await firstFetch.value

        #expect(!playerService.isFetchingMoreMixSongs)
        #expect(playerService.activeMixContinuationRequestID == nil)
        #expect(playerService.queue.map(\.videoId).contains("later"))
        #expect(mockClient.getMixQueueContinuationCallCount == 1)
    }

    @Test("The newest Next waits for an active mix continuation and advances")
    func concurrentNextCoalescesOnMixContinuation() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let current = self.makeSong(id: "current")
        let appended = self.makeSong(id: "appended")
        await playerService.playQueue([current], startingAt: 0)
        playerService[keyPath: \.mixContinuationToken] = "mock-token"
        mockClient.mixQueueContinuationResult = RadioQueueResult(
            songs: [appended],
            continuationToken: nil
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.beforeMixQueueContinuationReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let firstNext = Task { @MainActor in await playerService.next() }
        await requestStarted.wait()
        let secondNext = Task { @MainActor in await playerService.next() }
        await Task.yield()
        await releaseRequest.open()
        await firstNext.value
        await secondNext.value

        #expect(playerService.currentIndex == 1)
        #expect(playerService.currentTrack?.videoId == appended.videoId)
        #expect(mockClient.getMixQueueContinuationCallCount == 1)
    }

    @Test("Ordered remote Next commands advance once per admitted press after continuation")
    func remoteNextBatchAdvancesForEveryCommand() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { self.resetSingletonPlayer() }
        let current = self.makeSong(id: "remote-current")
        let firstAppended = self.makeSong(id: "remote-first")
        let secondAppended = self.makeSong(id: "remote-second")
        await playerService.playQueue([current], startingAt: 0)
        playerService[keyPath: \.mixContinuationToken] = "mock-token"
        mockClient.mixQueueContinuationResult = RadioQueueResult(
            songs: [firstAppended, secondAppended],
            continuationToken: nil
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.beforeMixQueueContinuationReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        playerService.enqueueRemoteMusicTransportCommand(
            .next,
            issuedAtMilliseconds: Date().timeIntervalSince1970 * 1000
        )
        await requestStarted.wait()
        playerService.enqueueRemoteMusicTransportCommand(
            .next,
            issuedAtMilliseconds: Date().timeIntervalSince1970 * 1000
        )
        let remoteTask = playerService.remoteMusicTransportTask
        await releaseRequest.open()
        await remoteTask?.value

        #expect(playerService.currentIndex == 2)
        #expect(playerService.currentTrack?.videoId == secondAppended.videoId)
        #expect(mockClient.getMixQueueContinuationCallCount == 1)
    }

    @Test("Queue-only intents accept an already-admitted terminal callback")
    func priorIntentTerminalCallbackRemainsAccepted() {
        let playerService = PlayerService()
        let admittedIntent = playerService.beginMusicPlaybackIntent(
            issuedAtMilliseconds: 1000
        )
        let queueOnlyIntent = playerService.beginMusicPlaybackIntent(
            issuedAtMilliseconds: 2000,
            allowsPriorTerminalEvent: true
        )

        #expect(playerService.currentMusicPlaybackIntent == queueOnlyIntent)
        #expect(playerService.acceptsMusicTerminalBridgeEvent(
            intent: admittedIntent,
            eventIssuedAtMilliseconds: 1500
        ))
    }

    @Test("Consecutive queue-only intents preserve terminal callback admission")
    func consecutiveQueueOnlyIntentsPreserveTerminalCallbackAdmission() {
        let playerService = PlayerService()
        let admittedIntent = playerService.beginMusicPlaybackIntent(
            issuedAtMilliseconds: 1000
        )
        _ = playerService.beginMusicPlaybackIntent(
            issuedAtMilliseconds: 2000,
            allowsPriorTerminalEvent: true
        )
        _ = playerService.beginMusicPlaybackIntent(
            issuedAtMilliseconds: 3000,
            allowsPriorTerminalEvent: true
        )

        #expect(playerService.acceptsMusicTerminalBridgeEvent(
            intent: admittedIntent,
            eventIssuedAtMilliseconds: 1500
        ))
    }

    @Test("A normal playback intent closes prior terminal callback admission")
    func normalIntentClosesPriorTerminalCallbackAdmission() {
        let playerService = PlayerService()
        let staleIntent = playerService.beginMusicPlaybackIntent(
            issuedAtMilliseconds: 1000
        )
        _ = playerService.beginMusicPlaybackIntent(
            issuedAtMilliseconds: 2000,
            allowsPriorTerminalEvent: true
        )
        _ = playerService.beginMusicPlaybackIntent(
            issuedAtMilliseconds: 3000
        )

        #expect(!playerService.acceptsMusicTerminalBridgeEvent(
            intent: staleIntent,
            eventIssuedAtMilliseconds: 1500
        ))
    }

    private func makePlayerService() -> (PlayerService, MockYTMusicClient) {
        self.resetSingletonPlayer()
        let mockClient = MockYTMusicClient()
        let playerService = PlayerService()
        playerService.setYTMusicClient(mockClient)
        return (playerService, mockClient)
    }

    private func resetSingletonPlayer() {
        SingletonPlayerWebView.shared.tearDown()
        SingletonPlayerWebView.shared.currentVideoId = nil
    }

    private func makeSong(id: String, videoId: String? = nil) -> Song {
        Song(
            id: id,
            title: id,
            artists: [],
            duration: 180,
            videoId: videoId ?? id,
            feedbackTokens: .init(add: nil, remove: nil)
        )
    }
}
