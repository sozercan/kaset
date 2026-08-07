import Foundation

@MainActor
extension PlayerService {
    // MARK: - Queue Undo / Redo

    /// Whether queue undo is available.
    var canUndoQueue: Bool {
        !self.queueUndoHistory.isEmpty
    }

    /// Whether queue redo is available.
    var canRedoQueue: Bool {
        !self.queueRedoHistory.isEmpty
    }

    /// Clears queue undo/redo history at account/privacy boundaries.
    func clearQueueUndoRedoHistory() {
        self.queueUndoHistory.removeAll()
        self.queueRedoHistory.removeAll()
    }

    /// Records current queue state for undo (call before mutating queue). Clears redo. Keeps up to 10 states.
    func recordQueueStateForUndo() {
        self.recordQueueStateForUndo(self.makeQueueStateSnapshot())
    }

    func makeQueueStateSnapshot() -> QueueState {
        QueueState(
            entries: self.queueEntries.map(Self.queueHistoryEntryWithoutAccountMetadata),
            currentIndex: self.currentIndex,
            shouldResumePlayback: self.shouldResumeAfterInterruption
                && !self.isExplicitPauseIntentActive,
            wasPlaybackEnded: self.state == .ended,
            shuffleMode: self.shuffleMode,
            mixContinuation: self.mixContinuationToken,
            mixContinuationRequiresAuth: self.mixContinuationRequiresAuth,
            queueOrderBeforeShuffle: self.queueOrderBeforeShuffle?.map(Self.queueHistoryEntryWithoutAccountMetadata),
            playbackOwner: self.currentQueueHistoryPlaybackOwner
        )
    }

    func recordQueueStateForUndo(_ state: QueueState) {
        self.queueUndoHistory.append(state)
        if self.queueUndoHistory.count > Self.queueUndoMaxCount {
            self.queueUndoHistory.removeFirst()
        }
        self.queueRedoHistory.removeAll()
        self.logger.debug("Recorded queue state for undo, undo count: \(self.queueUndoHistory.count)")
    }

    /// Restores the previous queue state and aligns playback to its exact current entry.
    func undoQueue() async {
        let intent = self.beginMusicPlaybackIntent()
        await self.undoQueue(intent: intent)
    }

    func undoQueue(intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent),
              let state = self.queueUndoHistory.popLast()
        else { return }
        let redoState = self.makeQueueStateSnapshot()
        self.cancelDeferredQueueWork()
        self.prepareForNewPlaybackContext()
        let restoreQueueGeneration = self.reserveQueueMutation()
        self.queueRedoHistory.append(redoState)
        self.clearForwardSkipNavigationStack()
        await self.restoreQueueState(
            state,
            intent: intent,
            queueGeneration: restoreQueueGeneration
        )
        guard self.acceptsQueueMutation(restoreQueueGeneration) else { return }
        self.logger.info("Undid queue to \(state.entries.count) songs at index \(self.currentIndex)")
    }

    /// Restores the next queue state after an undo and aligns playback to its exact current entry.
    func redoQueue() async {
        let intent = self.beginMusicPlaybackIntent()
        await self.redoQueue(intent: intent)
    }

    func redoQueue(intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent),
              let state = self.queueRedoHistory.popLast()
        else { return }
        let undoState = self.makeQueueStateSnapshot()
        self.cancelDeferredQueueWork()
        self.prepareForNewPlaybackContext()
        let restoreQueueGeneration = self.reserveQueueMutation()
        self.queueUndoHistory.append(undoState)
        self.clearForwardSkipNavigationStack()
        await self.restoreQueueState(
            state,
            intent: intent,
            queueGeneration: restoreQueueGeneration
        )
        guard self.acceptsQueueMutation(restoreQueueGeneration) else { return }
        self.logger.info("Redid queue to \(state.entries.count) songs at index \(self.currentIndex)")
    }

    private func restoreQueueState(
        _ state: QueueState,
        intent: MusicPlaybackIntent,
        queueGeneration: Int
    ) async {
        let downgradesSmartShuffle = state.shuffleMode == .smart
            && !self.smartShuffleFeatureEnabled()
        let playbackOwnerEntryID: UUID? = if case let .queueEntry(entryID, _, _) = state.playbackOwner {
            entryID
        } else {
            nil
        }
        let restoredEntries = downgradesSmartShuffle
            ? Self.stripSuggested(from: state.entries, keepingCurrentID: playbackOwnerEntryID)
            : state.entries
        self.setQueue(entries: restoredEntries)
        self.currentIndex = min(state.currentIndex, max(0, restoredEntries.count - 1))
        self[keyPath: \.mixContinuationToken] = state.mixContinuation
        self.mixContinuationRequiresAuth = state.mixContinuationRequiresAuth
        self.shuffleMode = downgradesSmartShuffle ? .on : state.shuffleMode
        self.queueOrderBeforeShuffle = if downgradesSmartShuffle {
            state.queueOrderBeforeShuffle.map {
                Self.stripSuggested(from: $0, keepingCurrentID: playbackOwnerEntryID)
            }
        } else {
            state.queueOrderBeforeShuffle
        }
        self.persistShuffleMode()

        if state.wasPlaybackEnded, self.restoreEndedQueueState(state) {
            await self.refreshRestoredQueueHistoryMetadata(intent: intent)
            self.completeQueueStateRestore(queueGeneration: queueGeneration)
            return
        }

        if case let .detached(song, episode, progress, duration) = state.playbackOwner {
            self.activePlaybackQueueEntryID = nil
            let restoreClock = episode?.isLive == true
                ? nil
                : MusicPlaybackRestoreClock(
                    progress: progress,
                    duration: duration
                )
            await self.play(
                song: song,
                webLoadStrategy: .standard,
                episode: episode,
                queueEntryID: nil,
                startsPaused: !state.shouldResumePlayback,
                restoreClock: restoreClock,
                intent: intent
            )
            self.completeQueueStateRestore(queueGeneration: queueGeneration)
            return
        }

        guard case let .queueEntry(ownerEntryID, progress, duration) = state.playbackOwner,
              let ownerIndex = self.queueEntries.firstIndex(where: { $0.id == ownerEntryID }),
              let entry = self.queueEntries[safe: ownerIndex]
        else {
            await self.stop(intent: intent, preservesQueueContext: true)
            self.completeQueueStateRestore(queueGeneration: queueGeneration)
            return
        }
        self.currentIndex = ownerIndex
        await self.play(
            song: entry.song,
            webLoadStrategy: .standard,
            queueEntryID: entry.id,
            startsPaused: !state.shouldResumePlayback,
            restoreClock: MusicPlaybackRestoreClock(
                progress: progress,
                duration: duration
            ),
            intent: intent
        )
        self.completeQueueStateRestore(queueGeneration: queueGeneration)
    }

    private func refreshRestoredQueueHistoryMetadata(intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent), let currentTrack = self.currentTrack else { return }
        await self.fetchSongMetadata(videoId: currentTrack.videoId)
    }

    private func completeQueueStateRestore(queueGeneration: Int) {
        guard self.acceptsQueueMutation(queueGeneration) else { return }
        self.saveQueueForPersistence()
        if self.shuffleMode == .smart {
            self.scheduleSmartShuffleFillForCurrentQueue()
        }
    }

    private func restoreEndedQueueState(_ state: QueueState) -> Bool {
        let song: Song
        let episode: ArtistEpisode?
        let queueEntryID: UUID?
        let progress: TimeInterval
        let duration: TimeInterval

        switch state.playbackOwner {
        case let .detached(detachedSong, detachedEpisode, savedProgress, savedDuration):
            song = detachedSong
            episode = detachedEpisode
            queueEntryID = nil
            progress = savedProgress
            duration = savedDuration
        case let .queueEntry(entryID, savedProgress, savedDuration):
            guard let ownerIndex = self.queueEntries.firstIndex(where: { $0.id == entryID }),
                  let entry = self.queueEntries[safe: ownerIndex]
            else { return false }
            self.currentIndex = ownerIndex
            song = entry.song
            episode = nil
            queueEntryID = entry.id
            progress = savedProgress
            duration = savedDuration
        case .none:
            return false
        }

        self.clearRestoredPlaybackSessionState()
        self.activePlaybackQueueEntryID = queueEntryID
        self.currentTrack = song
        self.currentTrackHasVideo = song.musicVideoType?.hasVideoContent ?? song.hasVideo ?? false
        self.applyInitialTrackStatus(from: song)
        self.currentEpisode = episode
        self.pendingPlayVideoId = song.videoId
        self.progress = progress
        self.currentTimeMs = Int(progress * 1000)
        self.duration = max(duration, song.duration ?? 0)
        self.recordDurationObservation(videoId: song.videoId, duration: self.duration)
        self.songNearingEnd = false
        self.isKasetInitiatedPlayback = false
        self.resetAdPlaybackState()
        let occurrence = self.beginNativeMusicPlaybackOccurrence(videoId: song.videoId)
        _ = self.claimTerminalMusicPlaybackOccurrence(occurrence)
        self.shouldSuppressAutoplayAfterQueueEnd = queueEntryID != nil
            && !self.canAdvanceNativeQueueAfterTrackEnd
        self.markPlaybackEnded()
        SingletonPlayerWebView.shared.pause()
        return true
    }

    private static func queueHistoryEntryWithoutAccountMetadata(_ entry: QueueEntry) -> QueueEntry {
        QueueEntry(
            id: entry.id,
            song: songWithoutAccountMetadata(entry.song),
            source: entry.source
        )
    }

    private var currentQueueHistoryPlaybackOwner: QueueState.PlaybackOwner {
        guard let currentTrack = self.currentTrack else { return .none }
        if let entryID = self.queueEntryIDOwningCurrentPlayback {
            return .queueEntry(
                id: entryID,
                progress: self.progress,
                duration: self.duration
            )
        }
        return .detached(
            song: Self.songWithoutAccountMetadata(currentTrack),
            episode: self.currentEpisode,
            progress: self.progress,
            duration: self.duration
        )
    }
}
