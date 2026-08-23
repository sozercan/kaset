import Foundation
import Testing
@testable import Kaset

extension PlayerServiceQueueTests {
    @Test("Adopting a restored session clears prior queue history")
    func restoredSessionAdoptionClearsQueueHistory() async {
        let first = TestFixtures.makeSong(id: "restore-history-first")
        let second = TestFixtures.makeSong(id: "restore-history-second")
        let restored = TestFixtures.makeSong(id: "restore-history-adopted")
        await self.playerService.playQueue([first], startingAt: 0)
        await self.playerService.playQueue([second], startingAt: 0)
        #expect(self.playerService.canUndoQueue)

        self.playerService.applyRestoredPlaybackSession(
            queue: [restored],
            currentIndex: 0,
            progress: 12,
            duration: 180
        )

        #expect(!self.playerService.canUndoQueue)
        #expect(!self.playerService.canRedoQueue)
        await self.playerService.undoQueue()
        #expect(self.playerService.queue == [restored])
    }

    @Test("A stale footer undo intent cannot replace newer playback")
    func staleUndoIntentCannotReplaceNewerPlayback() async {
        let first = TestFixtures.makeSong(id: "footer-first")
        let second = TestFixtures.makeSong(id: "footer-second")
        let newer = TestFixtures.makeSong(id: "footer-newer")
        await self.playerService.playQueue([first], startingAt: 0)
        await self.playerService.playQueue([second], startingAt: 0)
        let staleUndoIntent = self.playerService.beginMusicPlaybackIntent()
        await self.playerService.playQueue([newer], startingAt: 0)

        await self.playerService.undoQueue(intent: staleUndoIntent)

        #expect(self.playerService.queue == [newer])
        #expect(self.playerService.currentTrack?.videoId == newer.videoId)
    }

    @Test("Undo restores mix continuation ownership")
    func undoRestoresMixContinuation() async {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService[keyPath: \.mixContinuationToken] = "mock-token"
        self.playerService.mixContinuationRequiresAuth = true

        self.playerService.clearQueue()
        #expect(self.playerService.mixContinuationToken == nil)
        await self.playerService.undoQueue()

        #expect(self.playerService.mixContinuationToken == "mock-token")
        #expect(self.playerService.mixContinuationRequiresAuth)
    }

    @Test("Queue history snapshots strip account-scoped song metadata")
    func queueHistorySnapshotsStripAccountMetadata() {
        let queued = Song(
            id: "history-account-queued",
            title: "Queued",
            artists: [],
            videoId: "history-account-queued",
            likeStatus: .like,
            isInLibrary: true,
            feedbackTokens: FeedbackTokens(add: "queued-add", remove: "queued-remove")
        )
        let detached = Song(
            id: "history-account-detached",
            title: "Detached",
            artists: [],
            videoId: "history-account-detached",
            likeStatus: .dislike,
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "detached-add", remove: "detached-remove")
        )
        let queuedEntry = QueueEntry(id: UUID(), song: queued)
        self.playerService.setQueue(entries: [queuedEntry])
        self.playerService.queueOrderBeforeShuffle = [queuedEntry]
        self.playerService.currentTrack = detached
        self.playerService.activePlaybackQueueEntryID = nil

        let snapshot = self.playerService.makeQueueStateSnapshot()

        #expect(snapshot.entries[0].song.likeStatus == nil)
        #expect(snapshot.entries[0].song.isInLibrary == nil)
        #expect(snapshot.entries[0].song.feedbackTokens == nil)
        #expect(snapshot.queueOrderBeforeShuffle?[0].song.likeStatus == nil)
        #expect(snapshot.queueOrderBeforeShuffle?[0].song.isInLibrary == nil)
        #expect(snapshot.queueOrderBeforeShuffle?[0].song.feedbackTokens == nil)
        guard case let .detached(song, _, _, _) = snapshot.playbackOwner else {
            Issue.record("Expected detached playback owner")
            return
        }
        #expect(song.likeStatus == nil)
        #expect(song.isInLibrary == nil)
        #expect(song.feedbackTokens == nil)
    }

    @Test("Undo refreshes account metadata instead of replaying stale action tokens")
    func undoRefreshesAccountMetadata() async {
        let stale = Song(
            id: "history-refresh",
            title: "History Refresh",
            artists: [],
            videoId: "history-refresh",
            likeStatus: .like,
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "old-add", remove: "old-remove")
        )
        let replacement = Song(
            id: "history-refresh-replacement",
            title: "Replacement",
            artists: [],
            videoId: "history-refresh-replacement",
            feedbackTokens: FeedbackTokens(add: "replacement-add", remove: "replacement-remove")
        )
        let authoritativeTokens = FeedbackTokens(add: "new-add", remove: "new-remove")
        self.mockClient.songResponses[stale.videoId] = Song(
            id: stale.id,
            title: stale.title,
            artists: stale.artists,
            videoId: stale.videoId,
            likeStatus: .dislike,
            isInLibrary: true,
            feedbackTokens: authoritativeTokens
        )
        await self.playerService.playQueue([stale], startingAt: 0)
        await self.playerService.playQueue([replacement], startingAt: 0)

        await self.playerService.undoQueue()

        #expect(self.mockClient.getSongVideoIds.contains(stale.videoId))
        #expect(self.playerService.currentTrackLikeStatus == .dislike)
        #expect(self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == authoritativeTokens)
        #expect(self.playerService.queue[0].likeStatus == .dislike)
        #expect(self.playerService.queue[0].isInLibrary == true)
        #expect(self.playerService.queue[0].feedbackTokens == authoritativeTokens)
    }

    @Test("Same-track undo refreshes stripped account metadata")
    func sameTrackUndoRefreshesAccountMetadata() async {
        let stale = Song(
            id: "same-track-history-refresh",
            title: "Same Track History Refresh",
            artists: [],
            duration: 180,
            videoId: "same-track-history-refresh",
            likeStatus: .like,
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "same-old-add", remove: "same-old-remove")
        )
        let appended = TestFixtures.makeSong(id: "same-track-appended")
        let authoritativeTokens = FeedbackTokens(add: "same-new-add", remove: "same-new-remove")
        self.mockClient.songResponses[stale.videoId] = Song(
            id: stale.id,
            title: stale.title,
            artists: stale.artists,
            duration: stale.duration,
            videoId: stale.videoId,
            likeStatus: .dislike,
            isInLibrary: true,
            feedbackTokens: authoritativeTokens
        )
        await self.playerService.playQueue([stale], startingAt: 0)
        let activeEntryID = self.playerService.activePlaybackQueueEntryID
        self.playerService.appendToQueue([appended])

        await self.playerService.undoQueue()

        #expect(self.playerService.activePlaybackQueueEntryID == activeEntryID)
        #expect(self.mockClient.getSongVideoIds.contains(stale.videoId))
        #expect(self.playerService.currentTrackLikeStatus == .dislike)
        #expect(self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == authoritativeTokens)
        #expect(self.playerService.queue[0].feedbackTokens == authoritativeTokens)
    }

    @Test("Ended queue history refreshes account metadata")
    func endedQueueHistoryRefreshesAccountMetadata() async {
        let stale = Song(
            id: "ended-history-refresh",
            title: "Ended History Refresh",
            artists: [],
            duration: 180,
            videoId: "ended-history-refresh",
            likeStatus: .like,
            isInLibrary: false,
            feedbackTokens: FeedbackTokens(add: "ended-old-add", remove: "ended-old-remove")
        )
        let authoritativeTokens = FeedbackTokens(add: "ended-new-add", remove: "ended-new-remove")
        self.mockClient.songResponses[stale.videoId] = Song(
            id: stale.id,
            title: stale.title,
            artists: stale.artists,
            duration: stale.duration,
            videoId: stale.videoId,
            likeStatus: .dislike,
            isInLibrary: true,
            feedbackTokens: authoritativeTokens
        )
        await self.playerService.playQueue([stale], startingAt: 0)
        self.playerService.markPlaybackEnded()

        await self.playerService.stopAndClearQueue()
        await self.playerService.undoQueue()

        #expect(self.playerService.state == .ended)
        #expect(self.mockClient.getSongVideoIds.contains(stale.videoId))
        #expect(self.playerService.currentTrackLikeStatus == .dislike)
        #expect(self.playerService.currentTrackInLibrary)
        #expect(self.playerService.currentTrackFeedbackTokens == authoritativeTokens)
        #expect(self.playerService.queue[0].feedbackTokens == authoritativeTokens)
    }

    @Test("Undo restores the authored order backing a shuffled queue")
    func undoRestoresPreShuffleBackingOrder() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(songs, startingAt: 1)
        let originalEntryIDs = self.playerService.queueEntryIDs
        self.playerService.setShuffleMode(.on)
        #expect(self.playerService.queueOrderBeforeShuffle?.map(\.id) == originalEntryIDs)

        self.playerService.clearQueue()
        #expect(self.playerService.queueOrderBeforeShuffle == nil)
        await self.playerService.undoQueue()

        #expect(self.playerService.queueOrderBeforeShuffle?.map(\.id) == originalEntryIDs)
        self.playerService.setShuffleMode(.off)
        #expect(self.playerService.queueEntryIDs == originalEntryIDs)
    }

    @Test("Redo preserves the authored order backing a shuffled queue")
    func redoPreservesPreShuffleBackingOrder() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(songs, startingAt: 1)
        let authoredState = self.playerService.makeQueueStateSnapshot()
        let originalEntryIDs = self.playerService.queueEntryIDs

        self.playerService.setShuffleMode(.on)
        #expect(self.playerService.queueOrderBeforeShuffle?.map(\.id) == originalEntryIDs)
        self.playerService.clearQueueUndoRedoHistory()
        self.playerService.recordQueueStateForUndo(authoredState)

        await self.playerService.undoQueue()
        #expect(self.playerService.shuffleMode == .off)
        await self.playerService.redoQueue()

        #expect(self.playerService.shuffleMode == .on)
        #expect(self.playerService.queueOrderBeforeShuffle?.map(\.id) == originalEntryIDs)
        self.playerService.setShuffleMode(.off)
        #expect(self.playerService.queueEntryIDs == originalEntryIDs)
    }

    @Test("Queue undo preserves detached playback")
    func undoDoesNotReplaceDetachedPlayback() async {
        let queued = TestFixtures.makeSong(id: "queued")
        let detached = TestFixtures.makeSong(id: "detached")
        let appended = TestFixtures.makeSong(id: "appended")
        await self.playerService.playQueue([queued], startingAt: 0)
        await self.playerService.play(song: detached)
        self.playerService.appendToQueue([appended])

        await self.playerService.undoQueue()

        #expect(self.playerService.queue == [queued])
        #expect(self.playerService.currentTrack?.videoId == detached.videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == nil)
    }

    @Test("Undo and redo preserve detached artist episode identity")
    func undoRedoPreservesDetachedArtistEpisodeIdentity() async {
        let episode = ArtistEpisode(
            videoId: "history-live-episode",
            title: "History Live Episode",
            subtitle: "Live now",
            description: "A standalone live stream",
            isLive: true
        )
        let appended = TestFixtures.makeSong(id: "episode-history-appended")
        await self.playerService.playEpisode(episode)
        self.playerService.state = .playing
        self.playerService.shouldResumeAfterInterruption = true
        self.playerService.progress = 42
        self.playerService.currentTimeMs = 42000
        self.playerService.duration = 0
        self.playerService.appendToQueue([appended])

        await self.playerService.undoQueue()

        #expect(self.playerService.queue.isEmpty)
        #expect(self.playerService.currentEpisode == episode)
        #expect(self.playerService.isCurrentItemLive)
        #expect(self.playerService.currentTrack?.videoId == episode.videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == nil)
        #expect(self.playerService.pendingRestoredSeek == nil)
        #expect(!self.playerService.isRestoringPlaybackSession)
        #expect(self.playerService.shouldResumeAfterInterruption)

        await self.playerService.redoQueue()

        #expect(self.playerService.queue == [appended])
        #expect(self.playerService.currentEpisode == episode)
        #expect(self.playerService.isCurrentItemLive)
        #expect(self.playerService.currentTrack?.videoId == episode.videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == nil)
        #expect(self.playerService.pendingRestoredSeek == nil)
        #expect(!self.playerService.isRestoringPlaybackSession)
        #expect(self.playerService.shouldResumeAfterInterruption)
    }

    @Test("Paused live episode restore suppresses autoplay before navigation")
    func pausedLiveEpisodeRestoreSuppressesAutoplayBeforeNavigation() async {
        let singleton = SingletonPlayerWebView.shared
        singleton.tearDown()
        singleton.currentVideoId = nil
        defer {
            singleton.tearDown()
            singleton.currentVideoId = nil
        }
        let webKitManager = WebKitManager.makeTestInstance()
        _ = singleton.getWebView(
            webKitManager: webKitManager,
            playerService: self.playerService
        )
        singleton.currentVideoId = "currently-loaded-video"
        let episode = ArtistEpisode(
            videoId: "paused-live-history",
            title: "Paused Live History",
            isLive: true
        )
        let representative = Song(
            id: episode.videoId,
            title: episode.title,
            artists: [],
            videoId: episode.videoId,
            feedbackTokens: FeedbackTokens(add: nil, remove: nil)
        )
        let state = QueueState(
            entries: [],
            currentIndex: 0,
            shouldResumePlayback: false,
            playbackOwner: .detached(
                song: representative,
                episode: episode,
                progress: 42,
                duration: 0
            )
        )
        self.playerService.currentTrack = TestFixtures.makeSong(id: "currently-loaded-video")
        self.playerService.pendingPlayVideoId = "currently-loaded-video"
        self.playerService.state = .playing
        self.playerService.clearQueueUndoRedoHistory()
        self.playerService.recordQueueStateForUndo(state)
        var capturedAutoplayIntent: Bool?
        self.playerService.onMusicPlaybackNavigationRequested = { videoID, shouldAutoplay in
            guard videoID == episode.videoId else { return }
            capturedAutoplayIntent = shouldAutoplay
        }

        await self.playerService.undoQueue()

        #expect(capturedAutoplayIntent == false)
        #expect(self.playerService.state == .paused)
        #expect(!self.playerService.shouldResumeAfterInterruption)
        #expect(self.playerService.isExplicitPauseIntentActive)
        #expect(self.playerService.pendingRestoredSeek == nil)
    }

    @Test("Undo restores the detached item captured before queue replacement")
    func undoRestoresCapturedDetachedPlayback() async {
        let queued = TestFixtures.makeSong(id: "queued-before-detached")
        let detached = TestFixtures.makeSong(id: "captured-detached")
        let replacement = TestFixtures.makeSong(id: "replacement-queue")
        await self.playerService.playQueue([queued], startingAt: 0)
        await self.playerService.play(song: detached)
        self.playerService.progress = 24
        await self.playerService.playQueue([replacement], startingAt: 0)

        await self.playerService.undoQueue()

        #expect(self.playerService.queue == [queued])
        #expect(self.playerService.currentTrack?.videoId == detached.videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == nil)
        #expect(self.playerService.progress == 24)
    }

    @Test("Clearing the entire queue removes persisted playback even when paused")
    func clearEntireQueueRemovesPersistence() async {
        let song = TestFixtures.makeSong(id: "clear-persisted")
        defer { self.playerService.clearSavedQueue() }
        await self.playerService.playQueue([song], startingAt: 0)
        await self.playerService.pause()
        SingletonPlayerWebView.shared.currentVideoId = song.videoId

        await self.playerService.clearQueueEntirely()

        #expect(self.playerService.queue.isEmpty)
        #expect(self.playerService.currentTrack == nil)
        #expect(self.playerService.currentEpisode == nil)
        #expect(self.playerService.pendingPlayVideoId == nil)
        #expect(self.playerService.state == .idle)
        #expect(SingletonPlayerWebView.shared.currentVideoId == nil)
        self.playerService.saveQueueForPersistence()
        let restored = PlayerService()
        #expect(!restored.restoreQueueFromPersistence())
    }

    @Test("Undo aligns playback with the restored queue occurrence")
    func undoAlignsPlaybackOccurrence() async {
        let first = TestFixtures.makeSong(id: "undo-first")
        let second = TestFixtures.makeSong(id: "undo-second")
        await self.playerService.playQueue([first], startingAt: 0)
        await self.playerService.playQueue([second], startingAt: 0)

        await self.playerService.undoQueue()

        #expect(self.playerService.queue == [first])
        #expect(self.playerService.currentTrack?.videoId == first.videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == self.playerService.currentQueueEntryID)
        #expect(self.playerService.activePlaybackQueueEntryID == self.playerService.queueEntryIDs.first)
    }

    @Test("Undo restores the queue-owned playback clock")
    func undoRestoresQueuePlaybackClock() async {
        let song = TestFixtures.makeSong(id: "clock")
        await self.playerService.playQueue([song], startingAt: 0)
        self.playerService.progress = 42
        self.playerService.duration = 180

        await self.playerService.clearQueueEntirely()
        await self.playerService.undoQueue()

        #expect(self.playerService.currentTrack?.videoId == song.videoId)
        #expect(self.playerService.progress == 42)
        #expect(self.playerService.duration == 180)
    }

    @Test("Undo routes a retained occurrence through pending-seek reconciliation")
    func undoRestoresPhysicalPlaybackClock() async {
        let first = TestFixtures.makeSong(id: "physical-clock")
        let second = TestFixtures.makeSong(id: "physical-clock-next")
        let firstEntryID = UUID()
        self.playerService.setQueue(entries: [
            QueueEntry(id: firstEntryID, song: first),
            QueueEntry(id: UUID(), song: second),
        ])
        self.playerService.currentIndex = 0
        self.playerService.activePlaybackQueueEntryID = firstEntryID
        self.playerService.currentTrack = first
        self.playerService.pendingPlayVideoId = first.videoId
        self.playerService.state = .playing
        self.playerService.shouldResumeAfterInterruption = true
        self.playerService.progress = 10
        self.playerService.currentTimeMs = 10000
        self.playerService.duration = 180

        self.playerService.clearQueue()
        await self.playerService.undoQueue()

        #expect(self.playerService.progress == 10)
        #expect(self.playerService.currentTimeMs == 10000)
        #expect(self.playerService.pendingRestoredSeek == 10)
        #expect(self.playerService.isRestoringPlaybackSession)
        #expect(self.playerService.shouldAutoResumeAfterRestoredLoad)
    }

    @Test("Undo preserves a paused queue transport intent")
    func undoPreservesPausedTransport() async {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue(songs, startingAt: 0)
        await self.playerService.pause()
        self.playerService.clearQueue()

        await self.playerService.undoQueue()

        #expect(self.playerService.queue == songs)
        #expect(self.playerService.state == .paused)
        #expect(!self.playerService.shouldResumeAfterInterruption)
    }

    @Test("Paused undo stays paused while metadata is still loading")
    func pausedUndoDoesNotAutoplayDuringMetadataFetch() async {
        let firstQueue = TestFixtures.makeSongs(count: 2)
        let replacement = TestFixtures.makeSong(id: "replacement")
        await self.playerService.playQueue(firstQueue, startingAt: 0)
        await self.playerService.pause()
        self.playerService.progress = 42
        self.playerService.duration = 180
        await self.playerService.playQueue([replacement], startingAt: 0)
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        self.mockClient.beforeGetSongReturn = { _ in
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        let undoTask = Task { @MainActor in
            await self.playerService.undoQueue()
        }
        await metadataStarted.wait()

        #expect(self.playerService.state == .paused)
        #expect(!self.playerService.shouldResumeAfterInterruption)
        #expect(self.playerService.currentTrack?.videoId == firstQueue[0].videoId)
        #expect(self.playerService.progress == 42)

        await releaseMetadata.open()
        await undoTask.value
        #expect(self.playerService.state == .paused)
    }

    @Test("Pause during undo metadata preserves structural finalization")
    func pauseDuringUndoMetadataPreservesStructuralFinalization() async {
        self.playerService.smartShuffleFeatureEnabled = { true }
        // Configure Smart Shuffle on this instance instead of the shared SettingsManager
        // singleton: the fill loop reads `smartShuffleConfigProvider`, so mutating the global
        // here would race with the (parallel) Smart Shuffle suite that also touches it.
        self.playerService.smartShuffleConfigProvider = {
            PlayerService.SmartShuffleConfig(suggestEveryN: 1, burst: 1, suggestionsAhead: 1)
        }

        let restored = Song(
            id: "pause-undo-restored",
            title: "Pause Undo Restored",
            artists: [],
            duration: 180,
            videoId: "pause-undo-restored",
            feedbackTokens: FeedbackTokens(add: "old-add", remove: "old-remove")
        )
        let replacement = Song(
            id: "pause-undo-replacement",
            title: "Pause Undo Replacement",
            artists: [],
            duration: 180,
            videoId: "pause-undo-replacement",
            feedbackTokens: FeedbackTokens(add: "replacement-add", remove: "replacement-remove")
        )
        let restoredQueue = [restored] + (1 ... SettingsManager.smartShuffleSuggestEveryNRange.upperBound).map { index in
            TestFixtures.makeSong(id: "pause-undo-filler-\(index)")
        }
        await self.playerService.playQueue(restoredQueue, startingAt: 0)
        self.playerService.shuffleMode = .smart
        let smartState = self.playerService.makeQueueStateSnapshot()
        self.playerService.shuffleMode = .off
        await self.playerService.playQueue([replacement], startingAt: 0)
        self.playerService.clearQueueUndoRedoHistory()
        self.playerService.recordQueueStateForUndo(smartState)
        self.mockClient.songResponses[restored.videoId] = Song(
            id: restored.id,
            title: restored.title,
            artists: restored.artists,
            duration: restored.duration,
            videoId: restored.videoId,
            feedbackTokens: FeedbackTokens(add: "new-add", remove: "new-remove")
        )
        let suggestion = TestFixtures.makeSong(id: "pause-undo-suggestion")
        for song in restoredQueue {
            self.mockClient.radioQueueSongs[song.videoId] = [suggestion]
        }
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        self.mockClient.beforeGetSongReturn = { videoID in
            guard videoID == restored.videoId else { return }
            await metadataStarted.open()
            await releaseMetadata.wait()
        }
        let undoIntent = self.playerService.beginMusicPlaybackIntent()
        let undoTask = Task { @MainActor in
            await self.playerService.undoQueue(intent: undoIntent)
        }
        await metadataStarted.wait()
        let restoreQueueGeneration = self.playerService.reserveQueueMutation()

        await self.playerService.pause()
        #expect(!self.playerService.acceptsMusicPlaybackIntent(undoIntent))
        #expect(self.playerService.acceptsQueueMutation(restoreQueueGeneration))
        await releaseMetadata.open()
        await undoTask.value
        await self.playerService.fillSmartShuffleWindow()

        #expect(self.playerService.shuffleMode == .smart)
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.queue.contains { $0.videoId == "pause-undo-suggestion" })
    }

    @Test("Pause during Previous metadata preserves the committed queue index")
    func pauseDuringPreviousMetadataPersistsCommittedIndex() async {
        let persistenceSuiteName = "com.kaset.tests.previous-persistence.\(UUID().uuidString)"
        guard let persistenceDefaults = UserDefaults(suiteName: persistenceSuiteName) else {
            Issue.record("Unable to create isolated queue persistence defaults")
            return
        }
        persistenceDefaults.removePersistentDomain(forName: persistenceSuiteName)
        self.playerService.queuePersistenceDefaults = persistenceDefaults
        let first = Song(
            id: "previous-persist-first",
            title: "First",
            artists: [],
            videoId: "previous-persist-first",
            feedbackTokens: FeedbackTokens(add: "first-add", remove: "first-remove")
        )
        let second = Song(
            id: "previous-persist-second",
            title: "Loading...",
            artists: [],
            videoId: "previous-persist-second"
        )
        let third = Song(
            id: "previous-persist-third",
            title: "Third",
            artists: [],
            videoId: "previous-persist-third",
            feedbackTokens: FeedbackTokens(add: "third-add", remove: "third-remove")
        )
        defer {
            self.playerService.clearSavedQueue()
            persistenceDefaults.removePersistentDomain(forName: persistenceSuiteName)
        }
        await self.playerService.playQueue([first, second, third], startingAt: 2)
        self.playerService.progress = 0
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        self.mockClient.beforeGetSongReturn = { videoID in
            guard videoID == second.videoId else { return }
            await metadataStarted.open()
            await releaseMetadata.wait()
        }
        self.mockClient.songResponses[second.videoId] = second
        let previousIntent = self.playerService.beginMusicPlaybackIntent()
        let previousTask = Task { @MainActor in
            await self.playerService.previous(intent: previousIntent)
        }
        await metadataStarted.wait()

        await self.playerService.pause()
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )
        await releaseMetadata.open()
        await previousTask.value

        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.state == .paused)
        let restored = PlayerService()
        restored.queuePersistenceDefaults = persistenceDefaults
        #expect(restored.restoreQueueFromPersistence())
        #expect(restored.currentIndex == 1)
        #expect(restored.currentTrack?.videoId == second.videoId)
    }

    @Test("Undoing footer clear restores the pre-stop playback owner and clock")
    func undoStopAndClearRestoresPlaybackSnapshot() async {
        let song = TestFixtures.makeSong(id: "footer-clear")
        await self.playerService.playQueue([song], startingAt: 0)
        let entryID = self.playerService.queueEntryIDs[0]
        await self.playerService.pause()
        self.playerService.progress = 42
        self.playerService.currentTimeMs = 42000
        self.playerService.duration = 180

        await self.playerService.stopAndClearQueue()
        await self.playerService.undoQueue()

        #expect(self.playerService.queue == [song])
        #expect(self.playerService.activePlaybackQueueEntryID == entryID)
        #expect(self.playerService.currentQueueEntryID == entryID)
        #expect(self.playerService.currentTrack?.videoId == song.videoId)
        #expect(self.playerService.progress == 42)
        #expect(self.playerService.currentTimeMs == 42000)
        #expect(self.playerService.duration == 180)
        #expect(self.playerService.state == .paused)
        #expect(!self.playerService.shouldResumeAfterInterruption)
    }

    @Test("Undoing a terminal clear preserves ended playback state")
    func undoEndedStopAndClearRemainsEnded() async throws {
        let song = TestFixtures.makeSong(id: "ended-clear")
        await self.playerService.playQueue([song], startingAt: 0)
        let entryID = self.playerService.queueEntryIDs[0]
        self.playerService.progress = song.duration ?? 180
        self.playerService.currentTimeMs = Int(self.playerService.progress * 1000)
        self.playerService.duration = song.duration ?? 180
        self.playerService.markPlaybackEnded()

        await self.playerService.stopAndClearQueue()
        await self.playerService.undoQueue()

        #expect(self.playerService.state == .ended)
        #expect(self.playerService.activePlaybackQueueEntryID == entryID)
        #expect(self.playerService.currentTrack?.videoId == song.videoId)
        #expect(self.playerService.progress == (song.duration ?? 180))
        #expect(!self.playerService.shouldResumeAfterInterruption)
        #expect(!self.playerService.isAwaitingPlaybackConfirmation)
        #expect(self.playerService.isExplicitPauseIntentActive)
        #expect(self.playerService.shouldSuppressAutoplayAfterQueueEnd)
        let endedOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)

        await self.playerService.resume()
        let replayOccurrence = try #require(self.playerService.currentMusicPlaybackOccurrence)
        #expect(replayOccurrence.nativeGeneration > endedOccurrence.nativeGeneration)
        #expect(self.playerService.progress == 0)
    }

    @Test("Undoing an ended entry refreshes video availability synchronously")
    func undoEndedEntryRefreshesVideoAvailability() async {
        let audioOnly = Song(
            id: "ended-audio-only",
            title: "Audio Only",
            artists: [],
            duration: 180,
            videoId: "ended-audio-only",
            musicVideoType: .atv,
            feedbackTokens: FeedbackTokens(add: nil, remove: nil)
        )
        let video = Song(
            id: "ended-video-capable",
            title: "Video",
            artists: [],
            duration: 180,
            videoId: "ended-video-capable",
            musicVideoType: .omv,
            feedbackTokens: FeedbackTokens(add: nil, remove: nil)
        )
        await self.playerService.playQueue([audioOnly], startingAt: 0)
        self.playerService.markPlaybackEnded()
        await self.playerService.playQueue([video], startingAt: 0)
        self.playerService.currentTrackHasVideo = true
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )

        await self.playerService.undoQueue()

        #expect(self.playerService.currentTrack?.videoId == audioOnly.videoId)
        #expect(self.playerService.state == .ended)
        #expect(!self.playerService.currentTrackHasVideo)
    }

    @Test("Undoing a terminal clear preserves detached artist episode identity")
    func undoEndedArtistEpisodeClearPreservesEpisodeIdentity() async {
        let episode = ArtistEpisode(
            videoId: "ended-history-episode",
            title: "Ended History Episode",
            subtitle: "Replay",
            isLive: false
        )
        await self.playerService.playEpisode(episode)
        self.playerService.markPlaybackEnded()

        await self.playerService.stopAndClearQueue()
        await self.playerService.undoQueue()

        #expect(self.playerService.state == .ended)
        #expect(self.playerService.currentEpisode == episode)
        #expect(self.playerService.currentTrack?.videoId == episode.videoId)
        #expect(self.playerService.activePlaybackQueueEntryID == nil)
    }

    @Test("Undo and redo of a stopped clear remain stopped")
    func stoppedClearHistoryDoesNotStartPlayback() async {
        let song = TestFixtures.makeSong(id: "redo-stop")
        defer { self.playerService.clearSavedQueue() }
        await self.playerService.playQueue([song], startingAt: 0)
        await self.playerService.stop()
        await self.playerService.clearQueueEntirely()

        await self.playerService.undoQueue()
        #expect(self.playerService.queue == [song])
        #expect(self.playerService.currentTrack == nil)
        #expect(self.playerService.state == .idle)
        let restoredUndo = PlayerService()
        #expect(restoredUndo.restoreQueueFromPersistence())
        #expect(restoredUndo.queue.map(\.videoId) == [song.videoId])

        await self.playerService.redoQueue()

        #expect(self.playerService.queue.isEmpty)
        #expect(self.playerService.currentTrack == nil)
        #expect(self.playerService.state == .idle)
        let restoredRedo = PlayerService()
        #expect(!restoredRedo.restoreQueueFromPersistence())
    }
}
