import Foundation

@MainActor
extension PlayerService {
    /// Returns true if the given song is the current track.
    func isCurrentTrack(_ song: Song) -> Bool {
        self.currentTrack?.videoId == song.videoId
    }

    /// Whether the persistent player should navigate to the pending video immediately.
    var shouldAutoloadPendingVideo: Bool {
        !self.isPendingRestoredLoadDeferred && self.pendingNativeQueueAdvanceVideoId == nil
    }

    /// Toggles between popup and side panel queue display modes.
    func toggleQueueDisplayMode() {
        if self.queueDisplayMode == .popup {
            self.queueDisplayMode = .sidepanel
        } else {
            self.queueDisplayMode = .popup
        }
        UserDefaults.standard.set(self.queueDisplayMode.rawValue, forKey: Self.queueDisplayModeKey)
        self.logger.info("Queue display mode: \(self.queueDisplayMode.displayName)")
    }

    /// Opens the native mini player.
    func openMiniPlayer(mode: MiniPlayerMode = .auxiliary) {
        self.miniPlayerMode = mode
        self.isMiniPlayerVisible = true
        self.shouldRestoreMainWindowWhenMiniPlayerCloses = mode == .switchFromMainWindow
        self.miniPlayerMainWindowRestoreRequest = false
        self.logger.debug("Mini player opened in mode: \(String(describing: mode))")
    }

    /// Toggles the native mini player for the requested mode.
    @discardableResult
    func toggleMiniPlayer(mode: MiniPlayerMode = .auxiliary) -> Bool {
        if self.isMiniPlayerVisible, self.miniPlayerMode == mode {
            return self.closeMiniPlayer()
        }

        self.openMiniPlayer(mode: mode)
        return false
    }

    /// Closes the native mini player and returns whether the main window should be restored.
    @discardableResult
    func closeMiniPlayer() -> Bool {
        self.closeMiniPlayer(restoringMainWindow: self.shouldRestoreMainWindowWhenMiniPlayerCloses)
    }

    /// Closes the native mini player with explicit control over main window restoration.
    @discardableResult
    func closeMiniPlayer(restoringMainWindow shouldRestore: Bool) -> Bool {
        self.isMiniPlayerVisible = false
        self.miniPlayerMode = .auxiliary
        self.shouldRestoreMainWindowWhenMiniPlayerCloses = false
        self.miniPlayerMainWindowRestoreRequest = shouldRestore
        self.logger.debug("Mini player closed, should restore main window: \(shouldRestore)")
        return shouldRestore
    }

    /// Consumes a pending request to restore the main app window.
    func consumeMiniPlayerMainWindowRestoreRequest() -> Bool {
        let shouldRestore = self.miniPlayerMainWindowRestoreRequest
        self.miniPlayerMainWindowRestoreRequest = false
        return shouldRestore
    }

    /// Switches between compact and expanded mini player layouts.
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

    /// Plays a track by video ID.
    func play(videoId: String) async {
        self.logger.debug("play() called with videoId: \(videoId)")
        self.logger.info("Playing video: \(videoId)")
        self.clearRestoredPlaybackSessionState()
        self.clearQueueNavigationRecovery()
        self.clearWebQueueInjectionState()
        // An explicit Kaset load supersedes (rather than participates in) a
        // native queue advance. The native-only path never calls `play`.
        self.clearPendingNativeQueueAdvance()
        self.currentEpisode = nil
        self.state = .loading
        self.songNearingEnd = false
        self.shouldSuppressAutoplayAfterQueueEnd = false

        // Create a minimal Song object for now
        self.currentTrack = Song(
            id: videoId,
            title: "Loading...",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: videoId
        )

        self.pendingPlayVideoId = videoId

        // Hidden-first playback: keep the persistent WebView anchored at 1×1 and
        // let its observer confirm playback once YouTube actually starts. If the
        // singleton already exists, navigate immediately; otherwise SwiftUI will
        // create it from `pendingPlayVideoId` and autoload in `PersistentPlayerView`.
        self.showMiniPlayer = false
        if SingletonPlayerWebView.shared.webView != nil {
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
        }

        // Fetch full song metadata in the background to get feedbackTokens
        await self.fetchSongMetadata(videoId: videoId)
    }

    /// Plays a song.
    func play(song: Song) async {
        await self.play(song: song, webLoadStrategy: .standard)
    }

    /// Plays a song.
    /// - Parameter webLoadStrategy: Controls duplicate-`videoId` behavior in ``SingletonPlayerWebView/loadVideo(videoId:strategy:)``
    ///   (repeat-one prefers in-place restart; queue drift correction may force a full page load).
    /// - Parameter episode: Artist episode metadata to preserve for standalone episode playback.
    func play(
        song: Song,
        webLoadStrategy: SingletonPlayerWebView.VideoLoadStrategy,
        episode: ArtistEpisode? = nil,
        isQueueNavigationRecovery: Bool = false
    ) async {
        self.logger.info("Playing song: \(song.title)")
        self.logger.debug("Web load strategy: \(String(describing: webLoadStrategy))")
        self.clearRestoredPlaybackSessionState()
        if !isQueueNavigationRecovery {
            self.clearQueueNavigationRecovery()
        }
        self.clearWebQueueInjectionState()
        // An explicit Kaset load supersedes (rather than participates in) a
        // native queue advance. `advanceQueueStateForNativeNavigation` does not
        // call this method while YouTube Music owns the transition.
        self.clearPendingNativeQueueAdvance()
        self.currentEpisode = episode
        // Brief `.loading` until the observer reports playback; in-place restarts may flash loading briefly.
        self.state = .loading
        self.songNearingEnd = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.currentTrack = song

        // Mark that we initiated this playback (to detect and correct YouTube's autoplay override)
        self.isKasetInitiatedPlayback = true

        // Use existing feedbackTokens if the song already has them
        if let tokens = song.feedbackTokens {
            self.currentTrackFeedbackTokens = tokens
            self.currentTrackInLibrary = song.isInLibrary ?? false
            if let likeStatus = song.likeStatus {
                self.currentTrackLikeStatus = likeStatus
            }
        }

        // SongLikeStatusManager cache is the most up-to-date source for like status;
        // use it to correct stale/missing song.likeStatus immediately.
        if let cachedStatus = SongLikeStatusManager.shared.status(for: song.videoId) {
            self.currentTrackLikeStatus = cachedStatus
        }

        self.pendingPlayVideoId = song.videoId

        // Hidden-first playback: keep the persistent WebView anchored at 1×1 and
        // let its observer confirm playback once YouTube actually starts. If the
        // singleton already exists, navigate immediately; otherwise SwiftUI will
        // create it from `pendingPlayVideoId` and autoload in `PersistentPlayerView`.
        self.showMiniPlayer = false
        if SingletonPlayerWebView.shared.webView != nil {
            SingletonPlayerWebView.shared.loadVideo(videoId: song.videoId, strategy: webLoadStrategy)
        }

        // Fetch full song metadata if we don't have feedbackTokens
        if song.feedbackTokens == nil {
            await self.fetchSongMetadata(videoId: song.videoId)
        }
    }

    /// Records that the WebView observer has confirmed playback actually started.
    /// Confirmation is intentionally independent of mini-player visibility.
    func confirmPlaybackStarted() {
        let shouldHideMiniPlayer = self.showMiniPlayer
        let didStartPlayback = self.state != .playing
        let shouldRecordInteraction = !self.hasUserInteractedThisSession

        guard shouldHideMiniPlayer || didStartPlayback || shouldRecordInteraction else { return }

        self.showMiniPlayer = false
        self.state = .playing

        if shouldRecordInteraction {
            self.markUserInteractedThisSession()
        }

        if didStartPlayback {
            self.logger.info("Playback confirmed started")
            self.syncWebQueue()
        }
    }

    /// Called when the mini player is dismissed.
    func miniPlayerDismissed() {
        self.showMiniPlayer = false
        if self.state == .loading {
            self.state = .idle
        }
    }

    func markPlaybackEnded() {
        self.state = .ended
    }

    /// Updates whether the current track has video available.
    /// Note: This only affects the UI (enabling/disabling the video button).
    /// It does NOT auto-close an open video window, since hasVideo detection
    /// can be unreliable when the video element has been extracted by video mode CSS.
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

    /// Called when video window opens to start grace period
    func videoWindowDidOpen() {
        self.videoWindowOpenedAt = ContinuousClock.now
        self.logger.debug("videoWindowDidOpen: grace period started")
    }

    /// Called when video window closes to clear grace period
    func videoWindowDidClose() {
        self.videoWindowOpenedAt = nil
        self.logger.debug("videoWindowDidClose: grace period cleared")
    }

    /// Returns true if video window was recently opened (within grace period)
    /// This is used to ignore spurious trackChanged events during video mode setup
    var isVideoGracePeriodActive: Bool {
        guard let openedAt = self.videoWindowOpenedAt else { return false }
        return ContinuousClock.now - openedAt < .seconds(3)
    }

    /// Toggles play/pause.
    func playPause() async {
        self.logger.debug("Toggle play/pause")

        if self.isPendingRestoredLoadDeferred || self.pendingPlayVideoId != nil && self.shouldLoadPendingVideoBeforePlayback {
            await self.resume()
            return
        }

        self.clearRestoredPlaybackSessionState()

        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.playPause()
        } else if self.isPlaying {
            await self.pause()
        } else {
            await self.resume()
        }
    }

    /// Pauses playback.
    func pause() async {
        self.logger.debug("Pausing playback")

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

    /// Resumes playback.
    func resume() async {
        self.logger.debug("Resuming playback")

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

    /// Skips to next track.
    func next() async {
        _ = await self.performNextNavigation()
    }

    /// Performs Next and reports whether Kaset accepted a concrete playback target.
    /// Track-end callers use the result because a repeat-all restart can intentionally
    /// keep the same queue entry ID and index.
    func performNextNavigation() async -> Bool { // swiftlint:disable:this cyclomatic_complexity
        guard !Task.isCancelled else { return false }
        self.logger.debug("Skipping to next track")
        self.clearRestoredPlaybackSessionState()
        SingletonPlayerWebView.shared.setAutoplayBlocked(false)

        if !self.queue.isEmpty {
            var targetIndex: Int?
            if self.currentIndex < self.queue.count - 1 {
                targetIndex = self.currentIndex + 1
            } else if self.repeatMode == .all {
                targetIndex = 0
            } else if self.mixContinuationToken != nil {
                let previousCount = self.queue.count
                await self.fetchMoreMixSongsIfNeeded()
                guard !Task.isCancelled else { return false }
                if self.queue.count > previousCount {
                    targetIndex = self.currentIndex + 1
                }
            }

            guard let targetIndex else { return false }
            self.pushForwardSkipStackIfLeavingIndex(for: targetIndex)
            guard await self.loadQueueSongForNavigation(at: targetIndex) else { return false }
            guard !Task.isCancelled else { return true }
            await self.fetchMoreMixSongsIfNeeded()
            guard !Task.isCancelled else { return true }
            await self.fillSmartShuffleWindow()
            guard !Task.isCancelled else { return true }
            self.saveQueueForPersistence(syncWebQueue: false)
            return true
        }

        // Standalone artist episodes are intentionally not in the local queue.
        // Do not let them fall through to YouTube Music's ambient next button.
        guard self.currentEpisode == nil else {
            self.logger.debug("Ignoring next for standalone artist episode playback")
            return false
        }

        if let currentTrack = self.currentTrack {
            await self.fetchAndApplyRadioQueue(for: currentTrack.videoId)
            guard !Task.isCancelled else { return false }
            if self.queue.indices.contains(self.currentIndex + 1) {
                self.pushForwardSkipStackIfLeavingIndex(for: self.currentIndex + 1)
                guard await self.loadQueueSongForNavigation(at: self.currentIndex + 1) else { return false }
                guard !Task.isCancelled else { return true }
                await self.fetchMoreMixSongsIfNeeded()
                guard !Task.isCancelled else { return true }
                await self.fillSmartShuffleWindow()
                guard !Task.isCancelled else { return true }
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

    /// Goes to previous track.
    func previous() async {
        self.logger.debug("Going to previous track")
        self.clearRestoredPlaybackSessionState()
        SingletonPlayerWebView.shared.setAutoplayBlocked(false)

        if !self.queue.isEmpty {
            if self.progress > 3 {
                await self.seek(to: 0)
                return
            }

            if let priorIndex = self.popForwardSkipIndex(), self.queue.indices.contains(priorIndex) {
                await self.loadQueueSongForNavigation(at: priorIndex)
                return
            }

            if self.currentIndex > 0 {
                await self.loadQueueSongForNavigation(at: self.currentIndex - 1)
            } else {
                await self.seek(to: 0)
            }
            return
        }

        // Standalone artist episodes are intentionally not in the local queue.
        // Do not restart them or fall through to YouTube Music's ambient previous button.
        guard self.currentEpisode == nil else {
            self.logger.debug("Ignoring previous for standalone artist episode playback")
            return
        }

        if self.progress > 3 {
            await self.seek(to: 0)
        } else if self.pendingPlayVideoId != nil {
            self.logger.debug("Ignoring previous without a Kaset queue")
        }
    }

    /// Navigates to a queue song through Kaset's deterministic load path.
    @discardableResult
    func loadQueueSongForNavigation(
        at index: Int,
        webLoadStrategy strategyOverride: SingletonPlayerWebView.VideoLoadStrategy? = nil
    ) async -> Bool {
        guard let song = self.queue[safe: index] else { return false }
        self.currentIndex = index
        self.progress = 0
        self.duration = song.duration ?? 0
        self.protectQueueNavigationTarget(song.videoId)
        let strategy: SingletonPlayerWebView.VideoLoadStrategy = strategyOverride
            ?? (SingletonPlayerWebView.shared.currentVideoId == song.videoId
                ? .preferInPlaceWhenSameVideoId
                : .standard)
        await self.play(song: song, webLoadStrategy: strategy)
        self.saveQueueForPersistence()
        return true
    }

    /// Commits a media-confirmed native WebView queue transition without forcing a page load.
    func advanceQueueStateForNativeNavigation(to index: Int) {
        guard let song = self.queue[safe: index] else { return }

        let trackChanged = self.currentTrack?.videoId != song.videoId
        self.currentIndex = index
        self.currentTrack = song
        self.currentEpisode = nil
        self.pendingPlayVideoId = song.videoId
        self.progress = 0
        self.duration = song.duration ?? 0
        self.protectQueueNavigationTarget(song.videoId)
        // The confirming media observation may already be paused. Starting from
        // `.paused` lets the same observation promote to `.playing` when needed,
        // while a non-playing observation cannot otherwise escape `.loading`.
        self.state = .paused
        self.isKasetInitiatedPlayback = false
        self.songNearingEnd = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.currentTrackHasVideo = song.musicVideoType?.hasVideoContent ?? song.hasVideo ?? false

        if trackChanged {
            self.resetTrackStatus()
            if let cachedStatus = SongLikeStatusManager.shared.status(for: song.videoId) {
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

    /// Seeks to a specific time.
    func seek(to time: TimeInterval) async {
        let clampedTime = self.duration > 0 ? min(max(time, 0), self.duration) : max(time, 0)
        self.logger.debug("Seeking to \(clampedTime)")

        if self.isPendingRestoredLoadDeferred {
            self.progress = clampedTime
            self.pendingRestoredSeek = clampedTime
            return
        }

        if self.duration > 0, clampedTime >= self.duration - Self.seekToEndThreshold {
            await self.handleManualSeekToEnd()
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

    /// Sets the volume.
    func setVolume(_ value: Double) async {
        let clampedValue = max(0, min(1, value))
        self.volume = clampedValue
        UserDefaults.standard.set(clampedValue, forKey: Self.volumeKey)

        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.setVolume(clampedValue)
        } else {
            await self.evaluatePlayerCommand("setVolume(\(Int(clampedValue * 100)))")
        }
    }

    /// Toggles mute state. Remembers previous volume for unmuting.
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

    /// Applies a new shuffle mode, materializing or restoring the queue as needed.
    func setShuffleMode(_ newMode: ShuffleMode) {
        let oldMode = self.shuffleMode
        guard newMode != oldMode else { return }
        self.shuffleMode = newMode

        // Leaving smart: cancel any in-flight fill (so it can't re-add suggestions after the strip),
        // then strip upcoming suggestions before applying the new ordering.
        if oldMode == .smart {
            self.cancelSmartShuffleFill()
            self.stripSuggestedEntries()
            self.resetSmartShuffleState()
        }

        switch newMode {
        case .off:
            // If the current track is a Smart Shuffle suggestion, `stripSuggestedEntries()` keeps it
            // above and restore appends non-snapshot entries so playback stays anchored to it.
            self.restoreQueueOrderBeforeShuffle(recordUndo: true)
        case .on:
            // From .off: shuffle and snapshot original order.
            // From .smart (suggestions already stripped): reshuffle the originals in place.
            self.materializeShuffleQueueForCurrentTrack(
                recordUndo: true,
                storesOriginalOrder: oldMode == .off
            )
        case .smart:
            // Phase 1 (synchronous): plain shuffle so playback continues instantly.
            // From .on, preserve the existing original-order snapshot so turning shuffle off restores
            // playlist order rather than the already-shuffled order.
            self.materializeShuffleQueueForCurrentTrack(
                recordUndo: true,
                storesOriginalOrder: oldMode == .off
            )
            // Phase 2 (async): fetch radio seeds and fill the suggestion window.
            Task { await self.fillSmartShuffleWindow() }
        }

        self.persistShuffleMode()
        self.logger.info("Shuffle mode: \(self.shuffleMode.rawValue)")
    }

    /// Cycles the player-bar shuffle control: off -> on -> smart -> off.
    /// When Smart Shuffle is disabled in settings, the smart state is skipped (off -> on -> off).
    func cycleShuffleMode() {
        let smartAvailable = SettingsManager.shared.smartShuffleEnabled
        switch self.shuffleMode {
        case .off: self.setShuffleMode(.on)
        case .on: self.setShuffleMode(smartAvailable ? .smart : .off)
        case .smart: self.setShuffleMode(.off)
        }
    }

    /// Binary shuffle toggle, preserved for menu (⌘S), mini player, AppleScript, and AI callers.
    /// Turning shuffle "on" enables plain shuffle; turning "off" also exits smart mode.
    func toggleShuffle() {
        self.setShuffleMode(self.shuffleEnabled ? .off : .on)
    }

    /// Persists the current shuffle mode (and a legacy bool for downgrade compatibility).
    func persistShuffleMode() {
        guard SettingsManager.shared.rememberPlaybackSettings else { return }
        UserDefaults.standard.set(self.shuffleMode.rawValue, forKey: Self.shuffleModeKey)
        UserDefaults.standard.set(self.shuffleEnabled, forKey: Self.shuffleEnabledKey)
    }

    /// Cycles through repeat modes: off -> all -> one -> off.
    func cycleRepeatMode() {
        self.advanceRepeatMode()
        self.logger.info("Repeat mode: \(String(describing: self.repeatMode))")
    }

    /// Clears active playback UI/WebView state when startup resolves to guest mode.
    ///
    /// Unlike explicit sign-out, this preserves only persisted sessions that are
    /// known to have been created in guest mode. Legacy/unknown sessions are
    /// cleared because they may contain account-owned listening metadata.
    func clearPlaybackForGuestStartup() {
        self.logger.info("Clearing active playback state for guest startup")
        guard self.restoredPlaybackSessionOwnerScope == Self.playbackSessionScopeGuest else {
            self.clearSavedQueue()
            self.clearPlaybackForPrivacyBoundary(persistEmptyQueue: true)
            return
        }
        self.logger.info("Preserving restored guest-owned playback session")
    }

    /// Clears guest-owned restored playback when startup resolves to a signed-in
    /// account. Guest Mode itself is not persisted, so a guest-owned restore must
    /// not silently move onto the authenticated playback store.
    func clearGuestPlaybackForAuthenticatedStartup() {
        guard self.restoredPlaybackSessionOwnerScope == Self.playbackSessionScopeGuest else { return }
        self.logger.info("Clearing guest-owned playback state for authenticated startup")
        self.clearSavedQueue()
        self.clearPlaybackForPrivacyBoundary(persistEmptyQueue: true)
    }

    /// Synchronously clears playback, queue, and WebView state at the sign-out privacy boundary.
    func clearPlaybackForSignOut() {
        self.logger.info("Clearing playback state for sign-out")
        self.clearPlaybackForPrivacyBoundary(persistEmptyQueue: true)
    }

    private func clearPlaybackForPrivacyBoundary(persistEmptyQueue: Bool) {
        self.invalidatePendingPlaybackRequests()
        self.clearRestoredPlaybackSessionState()
        SingletonPlayerWebView.shared.tearDown()
        self.state = .idle
        self.songNearingEnd = false
        self.isKasetInitiatedPlayback = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.currentEpisode = nil
        self.currentTrack = nil
        self.pendingPlayVideoId = nil
        self.clearPendingNativeQueueAdvance()
        self.progress = 0
        self.currentLyricsLineIndex = nil
        self.currentLyricsDisplayTimeMs = nil
        self.duration = 0
        self.showMiniPlayer = false
        self.isMiniPlayerVisible = false
        self.showLyrics = false
        self.showQueue = false
        self.showVideo = false
        self.currentTrackHasVideo = false
        self.mixContinuationToken = nil
        self.mixContinuationRequiresAuth = false
        self.queueOrderBeforeShuffle = nil
        self.clearQueueUndoRedoHistory()
        self.currentIndex = 0
        if !persistEmptyQueue {
            self.suppressNextEmptyQueuePersistence = true
        }
        self.setQueue([])
        self.resetTrackStatus()
        if persistEmptyQueue {
            self.saveQueueForPersistence()
        }
    }

    /// Stops playback and clears state.
    func stop() async {
        self.logger.debug("Stopping playback")
        self.clearRestoredPlaybackSessionState()
        await self.evaluatePlayerCommand("pauseVideo()")
        self.state = .idle
        self.songNearingEnd = false
        self.isKasetInitiatedPlayback = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.currentEpisode = nil
        self.currentTrack = nil
        self.clearPendingNativeQueueAdvance()
        self.progress = 0
        self.duration = 0
    }

    /// Show the AirPlay picker for selecting audio output devices.
    func showAirPlayPicker() {
        self.markAirPlayRequested()
        SingletonPlayerWebView.shared.showAirPlayPicker()
    }

    /// Updates the AirPlay connection status from the WebView.
    func updateAirPlayStatus(isConnected: Bool, wasRequested: Bool = false) {
        self.isAirPlayConnected = isConnected
        if wasRequested {
            self.markAirPlayRequested()
        }
    }

    /// Legacy method for evaluating player commands - now delegates to SingletonPlayerWebView.
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
