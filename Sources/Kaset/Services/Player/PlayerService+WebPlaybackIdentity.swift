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
        bridgeTrackChanged: Bool
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
                videoId: authoritativeVideoId
            )
        }

        guard let authoritativeVideoId else { return true }
        return self.observedPlaybackMatchesCurrentTarget(videoId: authoritativeVideoId)
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
            ?? self.queue[safe: self.currentIndex]?.videoId
            ?? self.currentTrack?.videoId
            ?? self.pendingPlayVideoId
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
        self.pendingNativeQueueAdvance = PendingNativeQueueAdvance(
            sourceEntryID: self.currentQueueEntryID,
            sourceVideoId: sourceVideoId,
            targetEntryID: targetEntry.id,
            targetVideoId: targetEntry.song.videoId,
            generation: generation
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
    func reconcilePendingNativeQueueAdvanceObservation(videoId: String?) async -> Bool {
        guard let pending = self.pendingNativeQueueAdvance else { return true }
        guard let videoId = self.normalizedWebPlaybackVideoId(videoId) else { return false }

        if videoId == pending.sourceVideoId {
            // The outgoing element can emit a final pause/time update after `ended`.
            return false
        }

        if videoId == pending.targetVideoId,
           await self.confirmPendingNativeQueueAdvance(videoId: videoId)
        {
            return true
        }

        await self.fallbackPendingNativeQueueAdvance(
            generation: pending.generation,
            reason: "observed unexpected native video \(videoId)"
        )
        return false
    }

    func handleNativeQueueAdvanceTimeout(generation: Int) async {
        await self.fallbackPendingNativeQueueAdvance(
            generation: generation,
            reason: "timed out waiting for expected native media"
        )
    }

    func clearPendingNativeQueueAdvance() {
        self.pendingNativeQueueAdvanceGeneration &+= 1
        self.pendingNativeQueueAdvance = nil
        self.clearNativeQueueMaintenance()
    }

    @discardableResult
    private func confirmPendingNativeQueueAdvance(videoId: String) async -> Bool {
        guard let pending = self.pendingNativeQueueAdvance,
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

    func fallbackInvalidatedNativeQueueAdvance(
        generation: Int,
        reason: String
    ) async {
        guard let pending = self.pendingNativeQueueAdvance,
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
        reason: String
    ) async {
        guard let pending = self.pendingNativeQueueAdvance,
              pending.generation == generation
        else {
            return
        }

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

        self.logger.warning(
            "Native queue advance to \(pending.targetVideoId) failed; loading current expected target \(targetSong.videoId): \(reason)"
        )
        self.pushForwardSkipStackIfLeavingIndex(for: targetIndex)
        // The tracked WebView ID still describes the pre-handoff source, while
        // the actual media may already be an unexpected target. Force navigation
        // when IDs happen to match instead of restarting the wrong media in place.
        await self.loadQueueSongForNavigation(
            at: targetIndex,
            webLoadStrategy: .forceFullPageWhenSameVideoId
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

    private func normalizedWebPlaybackVideoId(_ videoId: String?) -> String? {
        guard let videoId, !videoId.isEmpty else { return nil }
        return videoId
    }
}
