import Foundation

// MARK: - Web Playback Identity

@MainActor
extension PlayerService {
    private static let nativeQueueAdvanceTimeout: Duration = .seconds(3)

    /// Reconciles WebView metadata before playback state is applied.
    ///
    /// The page's `trackChanged` flag is advisory: YouTube can update its internal
    /// video ID before the observer's title/artist state catches up, then report the
    /// mismatched video with `trackChanged == false` on later ticks. Video identity
    /// remains authoritative, so any mismatch must still pass through queue-drift
    /// reconciliation.
    ///
    /// - Returns: Whether progress/play state from this observation belongs to the
    ///   current Kaset queue target after reconciliation.
    func reconcileWebPlaybackMetadata(
        title: String,
        artist: String,
        thumbnailUrl: String,
        observedVideoId: String?,
        mediaVideoId: String? = nil,
        bridgeTrackChanged: Bool,
        playbackOccurrence: MusicPlaybackOccurrence? = nil
    ) -> Bool {
        let normalizedLogicalVideoId = self.normalizedWebPlaybackVideoId(observedVideoId)
        let normalizedMediaVideoId = self.normalizedWebPlaybackVideoId(mediaVideoId)
        let identitiesCoherent = normalizedLogicalVideoId != nil
            && normalizedLogicalVideoId == normalizedMediaVideoId
        let authoritativeVideoId = normalizedMediaVideoId
        let expectedVideoId = self.expectedPlaybackVideoId
        let videoIdMismatch = authoritativeVideoId.map { $0 != expectedVideoId } ?? false
        let hasObservedMetadata = authoritativeVideoId != nil || !title.isEmpty
        let thumbnailMetadataChanged = !thumbnailUrl.isEmpty
            && thumbnailUrl != self.currentTrack?.thumbnailURL?.absoluteString
        let textualMetadataChanged = !title.isEmpty
            && (title != self.currentTrack?.title
                || !artist.isEmpty && artist != self.currentTrack?.artistsDisplay
                || thumbnailMetadataChanged)

        // Media identity is authoritative for queue alignment. Textual metadata is
        // applied only when the player-bar identity agrees with that media.
        let shouldReconcileMetadata = identitiesCoherent
            && (bridgeTrackChanged
                || videoIdMismatch
                || textualMetadataChanged)
        if hasObservedMetadata, videoIdMismatch || shouldReconcileMetadata {
            self.updateTrackMetadata(
                title: identitiesCoherent ? title : "",
                artist: identitiesCoherent ? artist : "",
                thumbnailUrl: identitiesCoherent ? thumbnailUrl : "",
                videoId: authoritativeVideoId,
                playbackOccurrence: playbackOccurrence,
                allowsObservedArtistForMatchingVideo: identitiesCoherent
            )
        }

        guard let authoritativeVideoId else { return true }
        return self.observedPlaybackMatchesCurrentTarget(videoId: authoritativeVideoId)
    }

    // swiftlint:disable:next function_parameter_count
    func reconcileWebPlaybackMetadata(
        title: String,
        artist: String,
        thumbnailUrl: String,
        observedVideoId: String?,
        playbackVideoId: String?,
        bridgeTrackChanged: Bool,
        playbackOccurrence: MusicPlaybackOccurrence? = nil
    ) -> Bool {
        self.reconcileWebPlaybackMetadata(
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            observedVideoId: observedVideoId,
            mediaVideoId: playbackVideoId,
            bridgeTrackChanged: bridgeTrackChanged,
            playbackOccurrence: playbackOccurrence
        )
    }

    func observedPlaybackWouldChangeQueueEntry(videoId observedVideoId: String?) -> Bool {
        guard self.activePlaybackOwnsCurrentQueueEntry,
              let observedVideoId = self.normalizedWebPlaybackVideoId(observedVideoId),
              self.queue[safe: self.currentIndex]?.videoId != observedVideoId
        else { return false }
        if self.songNearingEnd {
            return true
        }
        let matchingIndices = self.queueEntries.indices.filter { index in
            self.queueEntries[index].song.videoId == observedVideoId
        }
        return matchingIndices.count == 1 && matchingIndices[0] != self.currentIndex
    }

    /// Whether an identity-bearing WebView playback observation belongs to
    /// Kaset's current queue target. Once a target identity is known, transient
    /// identityless ticks are rejected because they may belong to the outgoing video.
    func observedPlaybackMatchesCurrentTarget(videoId observedVideoId: String?) -> Bool {
        guard let expectedVideoId = self.expectedPlaybackVideoId else { return true }
        guard let observedVideoId = self.normalizedWebPlaybackVideoId(observedVideoId) else { return false }
        return observedVideoId == expectedVideoId
    }

    var expectedPlaybackVideoId: String? {
        self.pendingNativeQueueAdvanceVideoId
            ?? (self.activePlaybackOwnsCurrentQueueEntry ? self.queue[safe: self.currentIndex]?.videoId : nil)
            ?? self.currentTrack?.videoId
            ?? self.pendingPlayVideoId
    }

    var hasAvailablePendingNativeQueueAdvanceSource: Bool {
        guard let pending = self.pendingNativeQueueAdvance,
              let sourceEntryID = pending.sourceEntryID,
              let sourceIndex = self.queueEntryIDs.firstIndex(of: sourceEntryID)
        else { return false }
        return self.queue[safe: sourceIndex]?.videoId == pending.sourceVideoId
    }

    var isPendingNativeQueueAdvanceValid: Bool {
        guard let pending = self.pendingNativeQueueAdvance,
              let sourceEntryID = pending.sourceEntryID,
              let sourceIndex = self.queueEntryIDs.firstIndex(of: sourceEntryID),
              sourceIndex == self.currentIndex,
              self.queue[safe: sourceIndex]?.videoId == pending.sourceVideoId,
              let expectedTargetIndex = self.expectedQueueIndexAfterCurrentTrack(),
              self.queueEntryIDs[safe: expectedTargetIndex] == pending.targetEntryID,
              self.queue[safe: expectedTargetIndex]?.videoId == pending.targetVideoId
        else {
            return false
        }
        return true
    }

    /// Starts a bounded native handoff without changing the visible queue pointer.
    /// The pointer moves only after the media-bound observer reports the expected target.
    func beginPendingNativeQueueAdvance(to index: Int) {
        guard let targetEntry = self.queueEntries[safe: index],
              let sourceVideoId = self.queue[safe: self.currentIndex]?.videoId
        else {
            return
        }

        self.clearPendingNativeQueueAdvance()
        let generation = self.pendingNativeQueueAdvanceGeneration
        let fallbackStartedAt = ContinuousClock.now
        self.pendingNativeQueueAdvance = PendingNativeQueueAdvance(
            sourceEntryID: self.currentQueueEntryID,
            sourceVideoId: sourceVideoId,
            targetEntryID: targetEntry.id,
            targetVideoId: targetEntry.song.videoId,
            generation: generation,
            fallbackDeadline: SingletonPlayerWebView.transitionFallbackDeadline(
                now: fallbackStartedAt,
                initialFallbackDelay: Self.nativeQueueAdvanceTimeout
            )
        )
        self.state = .loading
        self.songNearingEnd = false
        self.isKasetInitiatedPlayback = false

        Task {
            try? await Task.sleep(for: Self.nativeQueueAdvanceTimeout)
            await self.handleNativeQueueAdvanceTimeout(generation: generation)
        }
    }

    /// Reconciles an authoritative media-bound observation during a native handoff.
    /// - Returns: Whether the caller should continue applying this observation.
    func reconcilePendingNativeQueueAdvanceObservation(
        videoId: String?,
        shouldContinue: @escaping @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard shouldContinue() else { return false }
        guard let pending = self.pendingNativeQueueAdvance else { return true }
        guard let videoId = self.normalizedWebPlaybackVideoId(videoId) else { return false }

        if videoId == pending.sourceVideoId {
            // The outgoing element can emit a final pause/time update after `ended`.
            return false
        }

        if videoId == pending.targetVideoId {
            guard shouldContinue(), self.confirmPendingNativeQueueAdvance(videoId: videoId) else {
                return false
            }
            return true
        }

        guard shouldContinue() else { return false }
        await self.fallbackPendingNativeQueueAdvance(
            generation: pending.generation,
            reason: "observed unexpected native video \(videoId)"
        )
        return false
    }

    func handleNativeQueueAdvanceTimeout(generation: Int) async {
        guard let pending = self.pendingNativeQueueAdvance,
              pending.generation == generation
        else { return }
        guard self.isPendingNativeQueueAdvanceValid else {
            await self.fallbackPendingNativeQueueAdvance(
                generation: generation,
                reason: "pending native queue relationship became invalid"
            )
            return
        }
        let now = ContinuousClock.now
        if let retryDelay = SingletonPlayerWebView.transitionFallbackRetryDelay(
            isShowingAd: self.isShowingAd,
            now: now,
            deadline: pending.fallbackDeadline
        ) {
            Task {
                try? await Task.sleep(for: retryDelay)
                await self.handleNativeQueueAdvanceTimeout(generation: generation)
            }
            return
        }
        await self.fallbackPendingNativeQueueAdvance(
            generation: generation,
            reason: "timed out waiting for expected native media"
        )
    }

    @discardableResult
    func reanchorPendingNativeQueueAdvanceSource(
        intent: MusicPlaybackIntent,
        startsPaused: Bool,
        restoreClock: MusicPlaybackRestoreClock? = nil,
        reason: String
    ) async -> Bool {
        guard self.acceptsMusicPlaybackIntent(intent),
              let pending = self.pendingNativeQueueAdvance
        else { return false }
        let sourceIndex = pending.sourceEntryID.flatMap { self.queueEntryIDs.firstIndex(of: $0) }
        guard let sourceIndex,
              self.queue[safe: sourceIndex]?.videoId == pending.sourceVideoId
        else {
            await self.fallbackPendingNativeQueueAdvance(
                generation: pending.generation,
                reason: "source unavailable during explicit \(reason)",
                intent: intent,
                startsPaused: startsPaused,
                restoreClock: restoreClock
            )
            return true
        }
        self.logger.info("Re-anchoring pending native queue advance source for explicit transport: \(reason)")
        self.clearPendingNativeQueueAdvance()
        self.clearWebQueueInjectionState()
        await self.loadQueueSongForNavigation(
            at: sourceIndex,
            webLoadStrategy: .forceFullPageWhenSameVideoId,
            startsPaused: startsPaused,
            restoreClock: restoreClock,
            intent: intent,
            fetchesMetadata: false
        )
        // Once this operation clears the pending handoff, callers must not fall
        // through and apply a superseded transport action to newer playback state.
        return true
    }

    func resolvePendingNativeQueueAdvanceForResume(intent: MusicPlaybackIntent) async -> Bool {
        guard self.pendingNativeQueueAdvance != nil else { return false }
        if self.isExplicitPauseIntentActive {
            return await self.reanchorPendingNativeQueueAdvanceSource(
                intent: intent,
                startsPaused: false,
                reason: "resume"
            )
        }

        switch self.state {
        case .loading, .playing, .buffering:
            self.logger.debug("Ignoring idempotent resume while native queue handoff awaits target media")
            return true
        case .idle, .paused, .ended, .error:
            self.logger.debug("Resuming paused media while native queue handoff remains pending")
        }

        self.isStoppingPlayback = false
        self.shouldResumeAfterInterruption = true
        self.isAwaitingPlaybackConfirmation = true
        self.isExplicitPauseIntentActive = false
        self.state = .loading
        SingletonPlayerWebView.shared.setAutoplayBlocked(false)
        SingletonPlayerWebView.shared.play()
        return true
    }

    func resolvePendingNativeQueueAdvanceForExplicitTerminal(
        intent: MusicPlaybackIntent,
        reason: String
    ) async {
        guard self.acceptsMusicPlaybackIntent(intent),
              let pending = self.pendingNativeQueueAdvance
        else { return }
        await self.fallbackPendingNativeQueueAdvance(
            generation: pending.generation,
            reason: reason,
            intent: intent,
            startsPaused: self.isExplicitPauseIntentActive
        )
    }

    func cancelPendingNativeQueueAdvanceForExplicitPriorNavigation(reason: String) {
        guard self.pendingNativeQueueAdvance != nil else { return }
        self.logger.info("Cancelling pending native queue advance for explicit prior navigation: \(reason)")
        self.clearPendingNativeQueueAdvance()
        self.clearWebQueueInjectionState()
    }

    func clearPendingNativeQueueAdvance() {
        self.pendingNativeQueueAdvanceGeneration &+= 1
        self.pendingNativeQueueAdvance = nil
        self.clearNativeQueueMaintenance()
    }

    @discardableResult
    private func confirmPendingNativeQueueAdvance(videoId: String) -> Bool {
        guard !Task.isCancelled,
              let pending = self.pendingNativeQueueAdvance,
              pending.targetVideoId == videoId,
              self.isPendingNativeQueueAdvanceValid,
              let targetIndex = self.expectedQueueIndexAfterCurrentTrack()
        else {
            return false
        }

        self.clearPendingNativeQueueAdvance()
        self.pushForwardSkipStackIfLeavingIndex(for: targetIndex)
        self.advanceQueueStateForNativeNavigation(to: targetIndex)
        SingletonPlayerWebView.shared.currentVideoId = videoId
        self.logger.info("Confirmed native queue advance to \(videoId)")

        self.scheduleNativeQueueMaintenance()
        return true
    }

    func revalidatePendingNativeQueueAdvanceAfterRepeatModeChange() {
        guard let pending = self.pendingNativeQueueAdvance,
              !self.isPendingNativeQueueAdvanceValid
        else { return }
        Task { @MainActor [weak self] in
            await self?.fallbackInvalidatedNativeQueueAdvance(
                generation: pending.generation,
                reason: "repeat mode changed"
            )
        }
    }

    func recoverPendingNativeQueueAdvanceAfterContentProcessTermination(
        intent: MusicPlaybackIntent
    ) async -> Bool {
        guard self.acceptsMusicPlaybackIntent(intent),
              let pending = self.pendingNativeQueueAdvance
        else { return false }
        await self.fallbackPendingNativeQueueAdvance(
            generation: pending.generation,
            reason: "WebContent process terminated",
            intent: intent,
            startsPaused: self.isExplicitPauseIntentActive
        )
        return true
    }

    func fallbackInvalidatedNativeQueueAdvance(
        generation: Int,
        reason: String
    ) async {
        guard !Task.isCancelled,
              let pending = self.pendingNativeQueueAdvance,
              pending.generation == generation,
              !self.isPendingNativeQueueAdvanceValid
        else {
            return
        }

        await self.fallbackPendingNativeQueueAdvance(
            generation: generation,
            reason: reason
        )
    }

    private func fallbackPendingNativeQueueAdvance(
        generation: Int,
        reason: String,
        intent suppliedIntent: MusicPlaybackIntent? = nil,
        startsPaused suppliedStartsPaused: Bool? = nil,
        restoreClock: MusicPlaybackRestoreClock? = nil
    ) async {
        guard let pending = self.pendingNativeQueueAdvance,
              pending.generation == generation
        else {
            return
        }

        let fallbackIntent = suppliedIntent ?? self.currentMusicPlaybackIntent
        let startsPaused = suppliedStartsPaused ?? self.isExplicitPauseIntentActive
        let sourceIndex = pending.sourceEntryID.flatMap { self.queueEntryIDs.firstIndex(of: $0) }
        let targetIndex: Int?
        if let sourceIndex {
            // When the source still exists, a nil expected successor means the
            // queue now ends here. Do not turn that into a replay of the source.
            self.currentIndex = sourceIndex
            targetIndex = self.expectedQueueIndexAfterCurrentTrack()
        } else {
            // Queue mutation helpers realign `currentIndex` after removing the source;
            // that post-edit position is now authoritative.
            targetIndex = self.queue.indices.contains(self.currentIndex)
                ? self.currentIndex
                : self.queue.indices.first
        }
        self.clearPendingNativeQueueAdvance()

        guard let targetIndex,
              let targetSong = self.queue[safe: targetIndex]
        else {
            self.logger.warning("Native queue advance fallback has no remaining target: \(reason)")
            self.shouldSuppressAutoplayAfterQueueEnd = true
            self.markPlaybackEnded()
            await self.pause()
            return
        }

        let normalizedRestoreClock = restoreClock.map { clock in
            MusicPlaybackRestoreClock(
                progress: max(clock.progress, 0),
                duration: 0,
                allowsSongDurationFallback: false,
                isExplicitTransportSeek: clock.isExplicitTransportSeek
            )
        }

        self.logger.warning(
            "Native queue advance to \(pending.targetVideoId) failed; loading current expected target \(targetSong.videoId): \(reason)"
        )
        self.pushForwardSkipStackIfLeavingIndex(for: targetIndex)
        // The tracked WebView ID still describes the pre-handoff source, while
        // the actual media may already be an unexpected target. Force navigation
        // when IDs happen to match instead of restarting the wrong media in place.
        await self.loadQueueSongForNavigation(
            at: targetIndex,
            webLoadStrategy: .forceFullPageWhenSameVideoId,
            startsPaused: startsPaused,
            restoreClock: normalizedRestoreClock,
            intent: fallbackIntent
        )
    }

    func awaitNativeQueueMaintenanceIfNeeded(generation: Int) async {
        guard generation == self.nativeQueueMaintenanceGeneration,
              self.nativeQueueMaintenanceTask != nil
        else {
            return
        }
        await withCheckedContinuation { continuation in
            guard generation == self.nativeQueueMaintenanceGeneration,
                  self.nativeQueueMaintenanceTask != nil
            else {
                continuation.resume()
                return
            }
            self.nativeQueueMaintenanceWaiters[generation, default: []].append(continuation)
        }
    }

    private func scheduleNativeQueueMaintenance() {
        let previousGeneration = self.nativeQueueMaintenanceGeneration
        self.nativeQueueMaintenanceGeneration &+= 1
        let generation = self.nativeQueueMaintenanceGeneration
        self.nativeQueueMaintenanceTask?.cancel()
        self.resumeNativeQueueMaintenanceWaiters(generation: previousGeneration)
        self.nativeQueueMaintenanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishNativeQueueMaintenance(generation: generation) }
            await NativeQueueMaintenanceContext.$isApplyingQueueMutation.withValue(true) {
                await self.fetchMoreMixSongsIfNeeded {
                    !Task.isCancelled && self.nativeQueueMaintenanceGeneration == generation
                }
                guard !Task.isCancelled,
                      self.nativeQueueMaintenanceGeneration == generation
                else { return }
                await self.fillSmartShuffleWindow()
                guard !Task.isCancelled,
                      self.nativeQueueMaintenanceGeneration == generation
                else { return }
                self.saveQueueForPersistence(syncWebQueue: false)
            }
            guard !Task.isCancelled,
                  self.nativeQueueMaintenanceGeneration == generation
            else { return }
            self.syncWebQueue()
        }
    }

    func clearNativeQueueMaintenance() {
        let previousGeneration = self.nativeQueueMaintenanceGeneration
        self.nativeQueueMaintenanceGeneration &+= 1
        self.nativeQueueMaintenanceTask?.cancel()
        self.nativeQueueMaintenanceTask = nil
        self.resumeNativeQueueMaintenanceWaiters(generation: previousGeneration)
    }

    private func finishNativeQueueMaintenance(generation: Int) {
        if self.nativeQueueMaintenanceGeneration == generation {
            self.nativeQueueMaintenanceTask = nil
        }
        self.resumeNativeQueueMaintenanceWaiters(generation: generation)
    }

    private func resumeNativeQueueMaintenanceWaiters(generation: Int) {
        let waiters = self.nativeQueueMaintenanceWaiters.removeValue(forKey: generation) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func resumeNativeQueueMaintenanceWaitersIfSuccessorMaterialized() {
        guard self.expectedQueueIndexAfterCurrentTrack() != nil else { return }
        self.resumeNativeQueueMaintenanceWaiters(generation: self.nativeQueueMaintenanceGeneration)
    }

    private func normalizedWebPlaybackVideoId(_ videoId: String?) -> String? {
        guard let videoId, !videoId.isEmpty else { return nil }
        return videoId
    }
}

extension WebPlaybackIdentityTransition {
    static func shouldHandleDeferredIdentitylessObservation(
        isDeferred: Bool,
        observedVideoId: String?,
        playbackVideoId: String?
    ) -> Bool {
        self.shouldHandleDeferredIdentitylessObservation(
            isDeferred: isDeferred,
            observedVideoId: observedVideoId,
            mediaVideoId: playbackVideoId
        )
    }
}
