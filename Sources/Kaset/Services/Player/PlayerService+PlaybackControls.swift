// swiftlint:disable file_length

import Foundation

@MainActor
extension PlayerService {
    func isCurrentTrack(_ song: Song) -> Bool {
        self.currentTrack?.videoId == song.videoId
    }

    var shouldAutoloadPendingVideo: Bool {
        !self.isPendingRestoredLoadDeferred && self.pendingNativeQueueAdvanceVideoId == nil
    }

    func toggleQueueDisplayMode() {
        if self.queueDisplayMode == .popup {
            self.queueDisplayMode = .sidepanel
        } else {
            self.queueDisplayMode = .popup
        }
        UserDefaults.standard.set(self.queueDisplayMode.rawValue, forKey: Self.queueDisplayModeKey)
        self.logger.info("Queue display mode: \(self.queueDisplayMode.displayName)")
    }

    func openMiniPlayer(mode: MiniPlayerMode = .auxiliary) {
        self.miniPlayerMode = mode
        self.isMiniPlayerVisible = true
        self.shouldRestoreMainWindowWhenMiniPlayerCloses = mode == .switchFromMainWindow
        self.miniPlayerMainWindowRestoreRequest = false
        self.logger.debug("Mini player opened in mode: \(String(describing: mode))")
    }

    @discardableResult
    func toggleMiniPlayer(mode: MiniPlayerMode = .auxiliary) -> Bool {
        if self.isMiniPlayerVisible, self.miniPlayerMode == mode {
            return self.closeMiniPlayer()
        }

        self.openMiniPlayer(mode: mode)
        return false
    }

    @discardableResult
    func closeMiniPlayer() -> Bool {
        self.closeMiniPlayer(restoringMainWindow: self.shouldRestoreMainWindowWhenMiniPlayerCloses)
    }

    @discardableResult
    func closeMiniPlayer(restoringMainWindow shouldRestore: Bool) -> Bool {
        self.isMiniPlayerVisible = false
        self.isMiniPlayerMiniaturized = false
        self.miniPlayerMode = .auxiliary
        self.shouldRestoreMainWindowWhenMiniPlayerCloses = false
        self.miniPlayerMainWindowRestoreRequest = shouldRestore
        self.logger.debug("Mini player closed, should restore main window: \(shouldRestore)")
        return shouldRestore
    }

    func consumeMiniPlayerMainWindowRestoreRequest() -> Bool {
        let shouldRestore = self.miniPlayerMainWindowRestoreRequest
        self.miniPlayerMainWindowRestoreRequest = false
        return shouldRestore
    }

    func toggleMiniPlayerPanel() {
        self.miniPlayerPanel = switch self.miniPlayerPanel {
        case .compact:
            .expanded
        case .expanded:
            .compact
        case .lyrics:
            .expanded
        }
    }

    func play(videoId: String) async {
        self.playbackContextGeneration &+= 1
        self.invalidatePendingPlaybackSelectionRequests()
        let intent = self.beginMusicPlaybackIntent()
        await self.play(videoId: videoId, intent: intent)
    }

    func play(videoId: String, intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.beginPlaybackNavigation()
        self.clearQueueNavigationRecovery()
        self.clearWebQueueInjectionState()
        self.clearPendingNativeQueueAdvance()
        self.logger.debug("play() called with videoId: \(videoId)")
        let acceptsPlaybackRequest = SingletonPlayerWebView.shared.acceptsPlaybackRequest(
            videoId: videoId,
            strategy: .standard
        )
        guard acceptsPlaybackRequest else {
            self.beginNativeMusicPlaybackOccurrence(
                videoId: videoId,
                synchronizeCurrentDocument: true
            )
            self.clearRestoredPlaybackSessionState()
            self.pendingPlayVideoId = videoId
            self.activePlaybackQueueEntryID = nil
            self.currentEpisode = nil
            if self.currentTrack?.videoId != videoId {
                self.resetTrackStatus()
                self.currentTrack = Song.placeholder(videoId: videoId)
            }
            self.logger.debug("Video \(videoId) already loaded; resuming existing playback")
            await self.resume(intent: intent)
            guard self.acceptsMusicPlaybackIntent(intent) else { return }
            if self.currentTrack?.feedbackTokens == nil {
                await self.fetchSongMetadata(videoId: videoId, queueOwner: .none)
            }
            return
        }
        self.beginNativeMusicPlaybackOccurrence(videoId: videoId)
        self.activePlaybackQueueEntryID = nil
        self.isStoppingPlayback = false
        self.logger.info("Playing video: \(videoId)")
        self.clearRestoredPlaybackSessionState()
        self.currentEpisode = nil
        self.state = .loading
        self.shouldResumeAfterInterruption = true
        self.isAwaitingPlaybackConfirmation = true
        self.isExplicitPauseIntentActive = false
        self.resetAdPlaybackState()
        self.progress = 0
        self.currentTimeMs = 0
        self.duration = 0
        self.songNearingEnd = false
        self.shouldSuppressAutoplayAfterQueueEnd = false

        self.currentTrack = Song.placeholder(videoId: videoId)

        self.pendingPlayVideoId = videoId

        self.showMiniPlayer = false
        if SingletonPlayerWebView.shared.webView != nil {
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
        }

        await self.fetchSongMetadata(
            videoId: videoId,
            queueOwner: .none
        )
    }

    func play(song: Song) async {
        self.playbackContextGeneration &+= 1
        self.invalidatePendingPlaybackSelectionRequests()
        let intent = self.beginMusicPlaybackIntent()
        await self.play(
            song: song,
            webLoadStrategy: .standard,
            queueEntryID: self.currentQueueEntryID(matching: song),
            intent: intent
        )
    }

    func play(
        song: Song,
        webLoadStrategy: SingletonPlayerWebView.VideoLoadStrategy,
        episode: ArtistEpisode? = nil,
        isQueueNavigationRecovery: Bool = false
    ) async {
        let intent = self.beginMusicPlaybackIntent()
        await self.play(
            song: song,
            webLoadStrategy: webLoadStrategy,
            episode: episode,
            queueEntryID: self.currentQueueEntryID(matching: song),
            isQueueNavigationRecovery: isQueueNavigationRecovery,
            intent: intent
        )
    }

    // swiftlint:disable function_body_length
    func play(
        song: Song,
        webLoadStrategy: SingletonPlayerWebView.VideoLoadStrategy,
        episode: ArtistEpisode? = nil,
        queueEntryID: UUID?,
        startsPaused: Bool = false,
        restoreClock: MusicPlaybackRestoreClock? = nil,
        fetchesMetadata: Bool = true,
        isQueueNavigationRecovery: Bool = false,
        bypassesSamePlaybackFastPath: Bool = false,
        intent: MusicPlaybackIntent
    ) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.routeLossPauseAt = nil
        self.unattributedRemotePauseAt = nil
        self.beginPlaybackNavigation()
        if !isQueueNavigationRecovery {
            self.clearQueueNavigationRecovery()
        }
        self.clearWebQueueInjectionState()
        self.clearPendingNativeQueueAdvance()
        self.logger.info("Playing song: \(song.title)")
        let acceptsPlaybackRequest = SingletonPlayerWebView.shared.acceptsPlaybackRequest(
            videoId: song.videoId,
            strategy: webLoadStrategy
        )
        let hasSameLogicalOwner = if let queueEntryID {
            queueEntryID == self.activePlaybackQueueEntryID
        } else {
            self.activePlaybackQueueEntryID == nil && self.currentTrack?.id == song.id
        }
        let isSameLogicalPlayback = hasSameLogicalOwner
            && self.currentTrack?.videoId == song.videoId
            && self.currentEpisode?.id == episode?.id
        let hasPendingSameLogicalLoad = self.pendingPlayVideoId == song.videoId
            && (self.state == .loading || self.isAwaitingPlaybackConfirmation)
        let shouldBypassSamePlaybackFastPath = bypassesSamePlaybackFastPath
            || webLoadStrategy.requiresSameVideoNavigation
        guard shouldBypassSamePlaybackFastPath
            || !isSameLogicalPlayback
            || (acceptsPlaybackRequest && !hasPendingSameLogicalLoad)
        else {
            if let restoreClock {
                self.logger.debug("Song \(song.videoId) already loaded; restoring playback clock")
                let targetProgress = self.beginPlaybackClockRestoration(
                    restoreClock,
                    songDuration: song.duration,
                    startsPaused: startsPaused
                )
                SingletonPlayerWebView.shared.seekAndPause(to: targetProgress)
                self.saveQueueForPersistence()
                if fetchesMetadata, song.feedbackTokens == nil {
                    await self.fetchSongMetadata(
                        videoId: song.videoId,
                        queueOwner: queueEntryID.map(MusicQueueMetadataOwner.entry) ?? .none
                    )
                }
                return
            }
            if startsPaused {
                self.logger.debug("Song \(song.videoId) already loaded; preserving paused playback")
                self.shouldResumeAfterInterruption = false
                self.isAwaitingPlaybackConfirmation = false
                self.isExplicitPauseIntentActive = true
                self.state = .paused
                SingletonPlayerWebView.shared.pause()
            } else {
                self.logger.debug("Song \(song.videoId) already loaded; resuming existing playback")
                await self.resume(intent: intent)
            }
            return
        }
        let effectiveLoadStrategy: SingletonPlayerWebView.VideoLoadStrategy = acceptsPlaybackRequest
            ? webLoadStrategy
            : SingletonPlayerWebView.freshSameIDPlaybackStrategy(
                isShowingAd: self.isShowingAd
            )
        self.beginNativeMusicPlaybackOccurrence(videoId: song.videoId)
        self.activePlaybackQueueEntryID = queueEntryID
        self.isStoppingPlayback = false
        self.logger.debug("Web load strategy: \(String(describing: effectiveLoadStrategy))")
        self.clearRestoredPlaybackSessionState()
        self.currentEpisode = episode
        self.state = .loading
        self.shouldResumeAfterInterruption = true
        self.isAwaitingPlaybackConfirmation = true
        self.isExplicitPauseIntentActive = false
        self.resetAdPlaybackState()
        self.progress = restoreClock?.progress ?? 0
        self.currentTimeMs = Int((restoreClock?.progress ?? 0) * 1000)
        self.duration = if let restoreClock {
            restoreClock.duration > 0
                ? restoreClock.duration
                : (restoreClock.allowsSongDurationFallback ? song.duration ?? 0 : 0)
        } else {
            song.duration ?? 0
        }
        self.songNearingEnd = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.currentTrack = song
        let restoredTargetProgress = restoreClock.map {
            self.beginPlaybackClockRestoration(
                $0,
                songDuration: song.duration,
                startsPaused: startsPaused
            )
        }
        if startsPaused, restoredTargetProgress == nil {
            self.shouldResumeAfterInterruption = false
            self.isAwaitingPlaybackConfirmation = false
            self.isExplicitPauseIntentActive = true
            self.state = .paused
        }
        self.isKasetInitiatedPlayback = true
        self.applyInitialTrackStatus(from: song)
        self.pendingPlayVideoId = song.videoId
        self.routePlaybackToWeb(
            song: song,
            strategy: effectiveLoadStrategy,
            acceptsPlaybackRequest: acceptsPlaybackRequest,
            restoredTargetProgress: restoredTargetProgress,
            startsPaused: startsPaused
        )

        if queueEntryID != nil || restoreClock != nil {
            self.saveQueueForPersistence()
        }
        if fetchesMetadata, song.feedbackTokens == nil {
            await self.fetchSongMetadata(
                videoId: song.videoId,
                queueOwner: queueEntryID.map(MusicQueueMetadataOwner.entry) ?? .none
            )
        }
    }

    // swiftlint:enable function_body_length

    private func routePlaybackToWeb(
        song: Song,
        strategy: SingletonPlayerWebView.VideoLoadStrategy,
        acceptsPlaybackRequest: Bool,
        restoredTargetProgress: TimeInterval?,
        startsPaused: Bool
    ) {
        self.showMiniPlayer = false
        let restoresLoadedSameVideo = restoredTargetProgress != nil
            && !acceptsPlaybackRequest
            && !self.isShowingAd
            && SingletonPlayerWebView.shared.webView != nil
        if let restoredTargetProgress, restoresLoadedSameVideo {
            if let nativeGeneration = self.currentMusicPlaybackOccurrence?.nativeGeneration {
                SingletonPlayerWebView.shared.setNativePlaybackGeneration(nativeGeneration)
            }
            SingletonPlayerWebView.shared.seekAndPause(to: restoredTargetProgress)
        } else if SingletonPlayerWebView.shared.webView != nil {
            self.onMusicPlaybackNavigationRequested?(
                song.videoId,
                self.shouldAutoplayPlaybackDocument
            )
            SingletonPlayerWebView.shared.loadVideo(
                videoId: song.videoId,
                strategy: strategy
            )
        }

        if startsPaused, restoredTargetProgress == nil {
            SingletonPlayerWebView.shared.pause()
        }
    }

    func applyInitialTrackStatus(from song: Song) {
        self.resetTrackStatus()
        if let tokens = song.feedbackTokens {
            self.currentTrackFeedbackTokens = tokens
            self.currentTrackInLibrary = song.isInLibrary ?? false
        }

        self.currentTrackLikeStatus = self.songLikeStatusManager.status(for: song) ?? .indifferent
    }

    func confirmPlaybackStarted() {
        let shouldHideMiniPlayer = self.showMiniPlayer
        let didStartPlayback = self.state != .playing
        let shouldRecordInteraction = !self.hasUserInteractedThisSession

        guard shouldHideMiniPlayer || didStartPlayback || shouldRecordInteraction else { return }

        self.showMiniPlayer = false
        self.routeLossPauseAt = nil
        self.unattributedRemotePauseAt = nil
        self.state = .playing

        if shouldRecordInteraction {
            self.markUserInteractedThisSession()
        }

        if didStartPlayback {
            self.logger.info("Playback confirmed started")
            self.syncWebQueue()
        }
    }

    func miniPlayerDismissed() {
        self.showMiniPlayer = false
        if self.state == .loading {
            self.state = .idle
        }
    }

    func markPlaybackEnded() {
        self.state = .ended
        self.shouldResumeAfterInterruption = false
        self.isAwaitingPlaybackConfirmation = false
        self.isExplicitPauseIntentActive = true
    }

    func updateVideoAvailability(hasVideo: Bool) {
        if UITestConfig.isUITestMode,
           UITestConfig.environmentValue(for: UITestConfig.mockHasVideoKey) == "true",
           !hasVideo
        {
            return
        }

        guard self.currentTrackHasVideo != hasVideo else { return }

        self.currentTrackHasVideo = hasVideo
        self.logger.debug("Video availability updated: \(hasVideo)")
    }

    func videoWindowDidOpen() {
        self.videoWindowOpenedAt = ContinuousClock.now
        self.logger.debug("videoWindowDidOpen: grace period started")
    }

    func videoWindowDidClose() {
        self.videoWindowOpenedAt = nil
        self.logger.debug("videoWindowDidClose: grace period cleared")
    }

    var isVideoGracePeriodActive: Bool {
        guard let openedAt = self.videoWindowOpenedAt else { return false }
        return ContinuousClock.now - openedAt < .seconds(3)
    }

    func playPause() async {
        let intent = self.beginMusicPlaybackIntent()
        await self.playPause(intent: intent)
    }

    func playPause(intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.logger.debug("Toggle play/pause")

        if self.isRestoringPlaybackSession {
            if self.shouldAutoResumeAfterRestoredLoad {
                await self.pause(intent: intent)
            } else {
                await self.resume(intent: intent)
            }
            return
        }

        if self.isPendingRestoredLoadDeferred || self.pendingRestoredSeek != nil {
            await self.resume(intent: intent)
            return
        }

        if self.pendingPlayVideoId != nil, self.shouldLoadPendingVideoBeforePlayback {
            if self.shouldResumeAfterInterruption {
                await self.pause(intent: intent)
            } else {
                await self.resume(intent: intent)
            }
            return
        }

        self.clearRestoredPlaybackSessionState()

        if self.state == .paused, !self.isAwaitingPlaybackConfirmation {
            await self.resume(intent: intent)
        } else if self.shouldResumeAfterInterruption || self.isAwaitingPlaybackConfirmation {
            await self.pause(intent: intent)
        } else {
            await self.resume(intent: intent)
        }
    }

    func pause() async {
        await self.pause(isAutomaticStop: false)
    }

    func pause(isAutomaticStop: Bool) async {
        let intent = self.beginMusicPlaybackIntent()
        await self.pause(intent: intent, isAutomaticStop: isAutomaticStop)
    }

    func pause(
        intent: MusicPlaybackIntent,
        origin: MusicPauseOrigin = .user,
        isAutomaticStop: Bool = false
    ) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.logger.debug("Pausing playback (origin: \(String(describing: origin)))")
        if !isAutomaticStop {
            self.explicitPauseGeneration &+= 1
        }
        self.clearQueueNavigationRecovery()
        let stopsPlayback = self.isPlaying || self.isAwaitingPlaybackConfirmation
        self.isAwaitingPlaybackConfirmation = false
        switch origin {
        case .user:
            self.shouldResumeAfterInterruption = false
            self.isExplicitPauseIntentActive = true
            self.routeLossPauseAt = nil
            self.unattributedRemotePauseAt = nil
        case let .unattributedRemote(admittedAt):
            self.shouldResumeAfterInterruption = false
            self.isExplicitPauseIntentActive = true
            self.routeLossPauseAt = nil
            self.unattributedRemotePauseAt = stopsPlayback ? admittedAt : nil
        case let .routeLoss(at):
            self.unattributedRemotePauseAt = nil
            if stopsPlayback {
                self.routeLossPauseAt = at
            }
        }

        if self.isPendingRestoredLoadDeferred {
            self.state = .paused
            return
        }

        if self.isRestoringPlaybackSession {
            self.isPendingRestoredLoadDeferred = true
            self.shouldAutoResumeAfterRestoredLoad = false
            self.shouldForcePendingRestoredLoad = true
            self.state = .paused
            if self.pendingPlayVideoId != nil {
                SingletonPlayerWebView.shared.pause()
            } else {
                await self.evaluatePlayerCommand("pause")
            }
            return
        }

        self.clearRestoredPlaybackSessionState()
        if self.state != .ended {
            self.state = .paused
        }
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.pause()
        } else {
            await self.evaluatePlayerCommand("pause")
        }
    }

    func resume() async {
        let intent = self.beginMusicPlaybackIntent()
        await self.resume(intent: intent)
    }

    func reattributeRemotePauseToRouteLoss(claim: (ContinuousClock.Instant) -> Bool) {
        guard let admittedAt = self.unattributedRemotePauseAt,
              !self.isPlaying,
              claim(admittedAt)
        else { return }
        self.unattributedRemotePauseAt = nil
        self.shouldResumeAfterInterruption = true
        self.isExplicitPauseIntentActive = false
        self.routeLossPauseAt = admittedAt
        self.logger.info("Re-attributed a remote pause to the audio route loss that caused it")
    }

    func resumeAfterRouteRestored(drainRemoteCommands: @MainActor () -> Void = {}) async {
        drainRemoteCommands()
        while let pendingRemoteCommands = self.remoteMusicTransportTask {
            await pendingRemoteCommands.value
            drainRemoteCommands()
            guard self.remoteMusicTransportTask != pendingRemoteCommands else { break }
        }
        guard self.routeLossPauseAt.map({ self.hasAudioRouteReturned($0) }) == true,
              !self.isPlaying,
              !self.isExplicitPauseIntentActive,
              self.currentTrack != nil || self.pendingPlayVideoId != nil
        else { return }
        self.logger.info("Audio route restored — resuming playback paused by the route loss")
        await self.resume()
    }

    // swiftlint:disable:next cyclomatic_complexity
    func resume(intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        if await self.resolvePendingNativeQueueAdvanceForResume(intent: intent) {
            return
        }
        self.logger.debug("Resuming playback")
        self.unattributedRemotePauseAt = nil
        self.isStoppingPlayback = false
        self.shouldResumeAfterInterruption = true
        self.isAwaitingPlaybackConfirmation = true
        self.isExplicitPauseIntentActive = false
        if self.currentTrack != nil || self.pendingPlayVideoId != nil,
           self.beginNativeMusicPlaybackReplayIfNeeded() != nil
        {
            self.state = .loading
            self.progress = 0
            self.currentTimeMs = 0
            self.songNearingEnd = false
            self.shouldSuppressAutoplayAfterQueueEnd = false
            self.resetAdPlaybackState()
        }

        SingletonPlayerWebView.shared.setAutoplayBlocked(false)

        if self.isPendingRestoredLoadDeferred {
            if let pendingPlayVideoId = self.pendingPlayVideoId,
               self.shouldLoadPendingVideoBeforePlayback
            {
                let strategy: SingletonPlayerWebView.VideoLoadStrategy = self.shouldForcePendingRestoredLoad ? .forceFullPageWhenSameVideoId : .standard
                self.beginRestoredPlaybackLoad(autoResumeAfterSeek: true)
                self.showMiniPlayer = false
                self.state = .loading
                self.isKasetInitiatedPlayback = true
                if SingletonPlayerWebView.shared.webView != nil {
                    SingletonPlayerWebView.shared.loadVideo(videoId: pendingPlayVideoId, strategy: strategy)
                    self.shouldForcePendingRestoredLoad = false
                }
                return
            }

            if let targetProgress = self.pendingRestoredSeek {
                self.beginRestoredPlaybackLoad(autoResumeAfterSeek: true)
                self.showMiniPlayer = false
                self.state = .loading
                self.isKasetInitiatedPlayback = true
                if SingletonPlayerWebView.shared.webView != nil {
                    SingletonPlayerWebView.shared.seek(to: targetProgress)
                    SingletonPlayerWebView.shared.play()
                } else {
                    await self.evaluatePlayerCommand("seekTo(\(targetProgress), true)")
                    await self.evaluatePlayerCommand("play")
                }
                return
            }

            self.clearRestoredPlaybackSessionState()
            self.showMiniPlayer = false
            self.state = .loading
            self.isKasetInitiatedPlayback = true

            if SingletonPlayerWebView.shared.webView != nil {
                SingletonPlayerWebView.shared.play()
            } else {
                await self.evaluatePlayerCommand("play")
            }
            return
        }

        guard let pendingPlayVideoId = self.pendingPlayVideoId else {
            self.clearRestoredPlaybackSessionState()
            await self.evaluatePlayerCommand("play")
            return
        }

        let shouldLoadPendingVideo = self.shouldLoadPendingVideoBeforePlayback
        if self.isPendingRestoredLoadDeferred {
            self.beginRestoredPlaybackLoad(autoResumeAfterSeek: true)
        } else if self.isRestoringPlaybackSession {
            self.shouldAutoResumeAfterRestoredLoad = true
            self.state = .loading
            if !shouldLoadPendingVideo {
                SingletonPlayerWebView.shared.resumeReadyAdvertisementIfPresent()
                return
            }
        } else {
            self.clearRestoredPlaybackSessionState()
        }

        if shouldLoadPendingVideo {
            self.showMiniPlayer = false
            self.state = .loading
            if SingletonPlayerWebView.shared.webView != nil {
                let strategy: SingletonPlayerWebView.VideoLoadStrategy = self.shouldForcePendingRestoredLoad ? .forceFullPageWhenSameVideoId : .standard
                SingletonPlayerWebView.shared.loadVideo(videoId: pendingPlayVideoId, strategy: strategy)
                self.shouldForcePendingRestoredLoad = false
            }
            return
        }

        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.play()
        } else {
            await self.evaluatePlayerCommand("play")
        }
    }

    func next() async {
        self.invalidatePendingPlaybackSelectionRequests()
        let intent = self.beginMusicPlaybackIntent()
        _ = await self.performNextNavigation(intent: intent)
    }

    func next(
        intent: MusicPlaybackIntent,
        defersNetworkFollowUp: Bool = false
    ) async {
        _ = await self.performNextNavigation(
            intent: intent,
            defersNetworkFollowUp: defersNetworkFollowUp
        )
    }

    func performNextNavigation( // swiftlint:disable:this cyclomatic_complexity
        intent: MusicPlaybackIntent? = nil,
        defersNetworkFollowUp: Bool = false,
        startsPaused: Bool = false
    ) async -> Bool {
        let intent = intent ?? self.currentMusicPlaybackIntent
        guard !Task.isCancelled, self.acceptsMusicPlaybackIntent(intent) else { return false }
        self.logger.debug("Skipping to next track")
        self.clearRestoredPlaybackSessionState()
        SingletonPlayerWebView.shared.setAutoplayBlocked(startsPaused)

        if self.shouldUseNativeQueueForTrackNavigation,
           !self.queueEntries.isEmpty
        {
            var targetIndex: Int?
            if self.currentIndex < self.queue.count - 1 {
                targetIndex = self.currentIndex + 1
            } else if self.repeatMode == .all {
                targetIndex = 0
            } else if self.mixContinuationToken != nil {
                let sourceContext = self.queuePlaybackContext
                let previousCount = self.queue.count
                await self.fetchMoreMixSongsIfNeeded()
                guard !Task.isCancelled,
                      self.acceptsMusicPlaybackIntent(intent),
                      self.queuePlaybackContext == sourceContext
                else {
                    return false
                }
                if self.queue.count > previousCount {
                    targetIndex = self.currentIndex + 1
                }
            }

            guard let targetIndex else { return false }
            self.pushForwardSkipStackIfLeavingIndex(for: targetIndex)
            guard await self.loadQueueSongForNavigation(
                at: targetIndex,
                startsPaused: startsPaused,
                intent: intent,
                fetchesMetadata: !defersNetworkFollowUp
            ) else { return false }
            guard !Task.isCancelled, self.acceptsMusicPlaybackIntent(intent) else { return true }
            if defersNetworkFollowUp {
                self.saveQueueForPersistence(syncWebQueue: false)
                return true
            }
            await self.fetchMoreMixSongsIfNeeded()
            guard !Task.isCancelled, self.acceptsMusicPlaybackIntent(intent) else { return true }
            await self.fillSmartShuffleWindow()
            guard !Task.isCancelled, self.acceptsMusicPlaybackIntent(intent) else { return true }
            self.saveQueueForPersistence(syncWebQueue: false)
            return true
        }

        guard self.currentEpisode == nil else {
            self.logger.debug("Ignoring next for standalone artist episode playback")
            return false
        }

        guard self.queueEntries.isEmpty || self.queueEntryIDOwningCurrentPlayback != nil else {
            self.logger.debug("Ignoring next for detached playback with a non-owning queue")
            return false
        }

        if let currentTrack = self.currentTrack {
            let sourceGeneration = self.playbackContextGeneration
            let sourceVideoId = currentTrack.videoId
            let sourceEntryID = self.currentQueueEntryID
            let radioOutcome = await self.fetchAndApplyRadioQueue(for: sourceVideoId)
            guard !Task.isCancelled,
                  radioOutcome != .superseded,
                  sourceGeneration == self.playbackContextGeneration,
                  self.currentTrack?.videoId == sourceVideoId
            else {
                return false
            }
            let resolvedSourceEntryID = self.queueEntryIDOwningCurrentPlayback ?? sourceEntryID
            if await self.advanceToMaterializedNextQueueSongIfAvailable(
                after: resolvedSourceEntryID,
                currentEntryRepresentsSource: radioOutcome == .applied,
                intent: intent,
                defersNetworkFollowUp: defersNetworkFollowUp,
                startsPaused: startsPaused
            ) {
                guard !Task.isCancelled, self.acceptsMusicPlaybackIntent(intent) else { return true }
                if defersNetworkFollowUp {
                    self.saveQueueForPersistence(syncWebQueue: false)
                    return true
                }
                await self.fetchMoreMixSongsIfNeeded()
                guard !Task.isCancelled, self.acceptsMusicPlaybackIntent(intent) else { return true }
                await self.fillSmartShuffleWindow()
                guard !Task.isCancelled, self.acceptsMusicPlaybackIntent(intent) else { return true }
                self.saveQueueForPersistence(syncWebQueue: false)
                return true
            } else {
                self.logger.debug("Ignoring next without a Kaset queue")
            }
        } else if self.pendingPlayVideoId != nil {
            self.logger.debug("Ignoring next without a Kaset queue")
        }
        return false
    }

    func advanceToMaterializedNextQueueSongIfAvailable(
        after sourceEntryID: UUID?,
        currentEntryRepresentsSource: Bool = false,
        intent suppliedIntent: MusicPlaybackIntent? = nil,
        defersNetworkFollowUp: Bool = false,
        startsPaused: Bool = false
    ) async -> Bool {
        let intent = suppliedIntent ?? self.currentMusicPlaybackIntent
        guard self.acceptsMusicPlaybackIntent(intent), !self.queue.isEmpty else { return false }

        let sourceIndex = sourceEntryID.flatMap { self.queueEntryIDs.firstIndex(of: $0) }
            ?? (currentEntryRepresentsSource && self.queue.indices.contains(self.currentIndex)
                ? self.currentIndex
                : nil)
        let targetIndex: Int? = if let sourceIndex, sourceIndex < self.queue.count - 1 {
            sourceIndex + 1
        } else if sourceIndex != nil, self.repeatMode == .all {
            0
        } else if sourceIndex == nil {
            self.queue.indices.contains(self.currentIndex)
                ? self.currentIndex
                : self.queue.indices.first
        } else {
            nil
        }

        guard let targetIndex else { return false }
        self.pushForwardSkipStackIfLeavingIndex(for: targetIndex)
        return await self.loadQueueSongForNavigation(
            at: targetIndex,
            startsPaused: startsPaused,
            intent: intent,
            fetchesMetadata: !defersNetworkFollowUp
        )
    }

    func previous() async {
        self.invalidatePendingPlaybackSelectionRequests()
        let intent = self.beginMusicPlaybackIntent()
        await self.previous(intent: intent)
    }

    func previous(
        intent: MusicPlaybackIntent,
        defersNetworkFollowUp: Bool = false
    ) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        if self.pendingNativeQueueAdvance != nil {
            let sourceIsAvailable = self.hasAvailablePendingNativeQueueAdvanceSource
            let startsPaused = self.isExplicitPauseIntentActive
            if !sourceIsAvailable {
                self.cancelPendingNativeQueueAdvanceForExplicitPriorNavigation(reason: "previous")
                self.progress = 0
                self.currentTimeMs = 0
                let priorIndex = self.popForwardSkipIndex().flatMap { index in
                    self.queueEntries.indices.contains(index) ? index : nil
                } ?? (self.currentIndex > 0 ? self.currentIndex - 1 : self.currentIndex)
                if self.queueEntries.indices.contains(priorIndex) {
                    _ = await self.loadQueueSongForNavigation(
                        at: priorIndex,
                        startsPaused: startsPaused,
                        intent: intent,
                        fetchesMetadata: !defersNetworkFollowUp
                    )
                    return
                }
            } else {
                let restartsSource = self.progress > 3
                    || (self.currentIndex == 0 && self.peekForwardSkipIndex() == nil)
                if restartsSource,
                   await self.reanchorPendingNativeQueueAdvanceSource(
                       intent: intent,
                       startsPaused: startsPaused,
                       reason: "previous"
                   )
                {
                    return
                }
                self.cancelPendingNativeQueueAdvanceForExplicitPriorNavigation(reason: "previous")
            }
        }
        self.logger.debug("Going to previous track")
        self.clearRestoredPlaybackSessionState()
        SingletonPlayerWebView.shared.setAutoplayBlocked(false)

        if self.shouldUseNativeQueueForTrackNavigation,
           !self.queueEntries.isEmpty
        {
            let queueGeneration = self.queueLoadGeneration
            if self.progress > 3 {
                await self.seek(to: 0, intent: intent)
                return
            }

            if let priorIndex = self.popForwardSkipIndex(), self.queueEntries.indices.contains(priorIndex) {
                _ = await self.loadQueueSongForNavigation(
                    at: priorIndex,
                    intent: intent,
                    fetchesMetadata: !defersNetworkFollowUp
                )
                guard self.isCurrentQueueLoad(queueGeneration) else { return }
                return
            }

            if self.currentIndex > 0 {
                _ = await self.loadQueueSongForNavigation(
                    at: self.currentIndex - 1,
                    intent: intent,
                    fetchesMetadata: !defersNetworkFollowUp
                )
                guard self.isCurrentQueueLoad(queueGeneration) else { return }
            } else {
                await self.seek(to: 0, intent: intent)
            }
            return
        }

        guard self.currentEpisode == nil else {
            self.logger.debug("Ignoring previous for standalone artist episode playback")
            return
        }

        if self.progress > 3 {
            await self.seek(to: 0, intent: intent)
        } else {
            self.logger.debug("Ignoring previous without a Kaset-owned queue")
        }
    }

    @discardableResult
    func loadQueueSongForNavigation(
        at index: Int,
        webLoadStrategy strategyOverride: SingletonPlayerWebView.VideoLoadStrategy? = nil,
        startsPaused: Bool = false,
        restoreClock: MusicPlaybackRestoreClock? = nil,
        intent suppliedIntent: MusicPlaybackIntent? = nil,
        fetchesMetadata: Bool = true
    ) async -> Bool {
        let intent = suppliedIntent ?? self.currentMusicPlaybackIntent
        guard self.acceptsMusicPlaybackIntent(intent),
              let entry = self.queueEntries[safe: index]
        else { return false }
        let song = entry.song
        self.currentIndex = index
        self.progress = restoreClock?.progress ?? 0
        self.currentTimeMs = Int((restoreClock?.progress ?? 0) * 1000)
        self.duration = if let restoreClock {
            restoreClock.duration > 0
                ? restoreClock.duration
                : (restoreClock.allowsSongDurationFallback ? song.duration ?? 0 : 0)
        } else {
            song.duration ?? 0
        }
        self.protectQueueNavigationTarget(song.videoId)
        let strategy = strategyOverride ?? SingletonPlayerWebView.queueNavigationStrategy(
            currentVideoId: SingletonPlayerWebView.shared.currentVideoId,
            targetVideoId: song.videoId,
            startsPaused: startsPaused,
            allowsInPlaceRestart: SingletonPlayerWebView.shared.canRestartInPlace
        )
        await self.play(
            song: song,
            webLoadStrategy: strategy,
            queueEntryID: entry.id,
            startsPaused: startsPaused,
            restoreClock: restoreClock,
            fetchesMetadata: fetchesMetadata,
            bypassesSamePlaybackFastPath: strategy.requiresSameVideoNavigation,
            intent: intent
        )
        guard self.acceptsMusicPlaybackIntent(intent) else { return false }
        self.saveQueueForPersistence()
        return true
    }

    func advanceQueueStateForNativeNavigation(to index: Int) {
        guard let song = self.queue[safe: index] else { return }

        self.beginPlaybackNavigation()
        let trackChanged = self.currentTrack?.videoId != song.videoId
        self.currentIndex = index
        self.activePlaybackQueueEntryID = self.currentQueueEntryID
        self.currentTrack = song
        self.currentEpisode = nil
        self.pendingPlayVideoId = song.videoId
        self.progress = 0
        self.duration = song.duration ?? 0
        self.protectQueueNavigationTarget(song.videoId)
        self.state = .paused
        self.isKasetInitiatedPlayback = false
        self.songNearingEnd = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.currentTrackHasVideo = song.musicVideoType?.hasVideoContent ?? song.hasVideo ?? false

        if trackChanged {
            self.resetTrackStatus()
            if let cachedStatus = self.songLikeStatusManager.status(for: song.videoId) {
                self.currentTrackLikeStatus = cachedStatus
            }
        }

        if let details = song.feedbackTokens {
            self.currentTrackFeedbackTokens = details
            self.currentTrackInLibrary = song.isInLibrary ?? false
            self.currentTrackLikeStatus = song.likeStatus ?? self.currentTrackLikeStatus
        }

        self.saveQueueForPersistence(syncWebQueue: false)
    }

    func seek(to time: TimeInterval) async {
        guard !self.isShowingAd else { return }
        let intent = self.beginMusicPlaybackIntent()
        await self.seek(to: time, intent: intent)
    }

    func seek(to time: TimeInterval, intent: MusicPlaybackIntent) async {
        guard !self.isShowingAd, self.acceptsMusicPlaybackIntent(intent) else { return }
        let clampedTime = self.duration > 0 ? min(max(time, 0), self.duration) : max(time, 0)
        if self.pendingNativeQueueAdvance != nil,
           self.duration > 0,
           clampedTime >= self.duration - Self.seekToEndThreshold
        {
            await self.resolvePendingNativeQueueAdvanceForExplicitTerminal(
                intent: intent,
                reason: "manual seek reached end during native handoff"
            )
            return
        }

        if self.pendingNativeQueueAdvance != nil {
            let startsPaused = self.isExplicitPauseIntentActive
            let restoreClock = MusicPlaybackRestoreClock(
                progress: clampedTime,
                duration: self.duration,
                isExplicitTransportSeek: true
            )
            if await self.reanchorPendingNativeQueueAdvanceSource(
                intent: intent,
                startsPaused: startsPaused,
                restoreClock: restoreClock,
                reason: "backward seek"
            ) {
                return
            }
        }
        self.logger.debug("Seeking to \(clampedTime)")

        if await self.retargetRestoredPlaybackSeekIfNeeded(
            to: clampedTime,
            intent: intent
        ) {
            return
        }

        guard !self.isShowingAd else { return }

        if self.duration > 0, clampedTime >= self.duration - Self.seekToEndThreshold {
            await self.handleManualSeekToEnd(intent: intent)
            return
        }

        self.clearRestoredPlaybackSessionState()
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.seek(to: clampedTime)
            self.progress = clampedTime
        } else {
            await self.evaluatePlayerCommand("seekTo(\(clampedTime), true)")
        }
    }

    func setVolume(_ value: Double) async {
        let clampedValue = self.storeVolumeValue(value)

        if self.pendingPlayVideoId != nil {
            self.applyMusicPlaybackVolume(clampedValue)
        } else {
            await self.evaluatePlayerCommand("setVolume(\(Int(clampedValue * 100)))")
        }
    }

    func setVolumeImmediately(_ value: Double) {
        let clampedValue = self.storeVolumeValue(value)

        let playbackVolume = self.pendingPlayVideoId == nil
            ? Double(Int(clampedValue * 100)) / 100
            : clampedValue
        self.applyMusicPlaybackVolume(playbackVolume)
    }

    private func storeVolumeValue(_ value: Double) -> Double {
        let clampedValue = max(0, min(1, value))
        self.volume = clampedValue
        UserDefaults.standard.set(clampedValue, forKey: Self.volumeKey)
        return clampedValue
    }

    func toggleMute() async {
        if self.isMuted {
            let restoredVolume = self.volumeBeforeMute > 0 ? self.volumeBeforeMute : 1.0
            await self.setVolume(restoredVolume)
            self.logger.info("Unmuted, volume restored to \(restoredVolume)")
        } else {
            self.rememberVolumeBeforeMute(self.volume)
            await self.setVolume(0)
            self.logger.info("Muted")
        }
    }

    func setShuffleMode(_ newMode: ShuffleMode) {
        let oldMode = self.shuffleMode
        guard newMode != oldMode else { return }
        let undoState = self.makeQueueStateSnapshot()
        self.recordQueueStateForUndo(undoState)
        self.shuffleMode = newMode

        if oldMode == .smart {
            self.cancelSmartShuffleFill()
            self.stripSuggestedEntries()
            self.resetSmartShuffleState()
        }

        switch newMode {
        case .off:
            self.restoreQueueOrderBeforeShuffle(recordUndo: false)
        case .on:
            self.materializeShuffleQueueForCurrentTrack(
                recordUndo: false,
                storesOriginalOrder: oldMode == .off
            )
        case .smart:
            self.materializeShuffleQueueForCurrentTrack(
                recordUndo: false,
                storesOriginalOrder: oldMode == .off
            )
            self.scheduleSmartShuffleFillForCurrentQueue()
        }

        self.persistShuffleMode()
        self.logger.info("Shuffle mode: \(self.shuffleMode.rawValue)")
    }

    func cycleShuffleMode() {
        self.beginMusicPlaybackIntent(allowsPriorTerminalEvent: true)
        let smartAvailable = self.smartShuffleFeatureEnabled()
        switch self.shuffleMode {
        case .off: self.setShuffleMode(.on)
        case .on: self.setShuffleMode(smartAvailable ? .smart : .off)
        case .smart: self.setShuffleMode(.off)
        }
    }

    func toggleShuffle() {
        self.beginMusicPlaybackIntent(allowsPriorTerminalEvent: true)
        self.setShuffleMode(self.shuffleEnabled ? .off : .on)
    }

    func persistShuffleMode() {
        guard SettingsManager.shared.rememberPlaybackSettings else { return }
        UserDefaults.standard.set(self.shuffleMode.rawValue, forKey: Self.shuffleModeKey)
        UserDefaults.standard.set(self.shuffleEnabled, forKey: Self.shuffleEnabledKey)
    }

    func cycleRepeatMode() {
        self.advanceRepeatMode()
        self.clearWebQueueInjectionState()
        self.revalidatePendingNativeQueueAdvanceAfterRepeatModeChange()
        self.syncWebQueue()
        self.logger.info("Repeat mode: \(String(describing: self.repeatMode))")
    }

    func showAirPlayPicker(at screenPoint: CGPoint? = nil) {
        SingletonPlayerWebView.shared.showAirPlayPicker(at: screenPoint)
    }

    func updateAirPlayStatus(isConnected: Bool) {
        self.isAirPlayConnected = isConnected
    }

    private func evaluatePlayerCommand(_ command: String) async {
        switch command {
        case "pause", "pauseVideo()":
            SingletonPlayerWebView.shared.pause()
        case "play", "playVideo()":
            SingletonPlayerWebView.shared.play()
        default:
            if command.hasPrefix("seekTo(") {
                let timeStr = command.dropFirst(7).prefix(while: { $0 != "," && $0 != ")" })
                if let time = Double(timeStr) {
                    SingletonPlayerWebView.shared.seek(to: time)
                }
            } else if command.hasPrefix("setVolume(") {
                let volStr = command.dropFirst(10).dropLast()
                if let vol = Int(volStr) {
                    SingletonPlayerWebView.shared.setVolume(Double(vol) / 100.0)
                }
            }
        }
    }
}
