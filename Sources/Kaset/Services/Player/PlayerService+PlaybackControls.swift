import Foundation

@MainActor
extension PlayerService {
    /// Returns true if the given song is the current track.
    func isCurrentTrack(_ song: Song) -> Bool {
        self.currentTrack?.videoId == song.videoId
    }

    /// Whether the persistent player should navigate to the pending video immediately.
    var shouldAutoloadPendingVideo: Bool {
        !self.isPendingRestoredLoadDeferred
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

    /// Plays a track by video ID.
    func play(videoId: String) async {
        self.logger.debug("play() called with videoId: \(videoId)")
        self.logger.info("Playing video: \(videoId)")
        self.clearRestoredPlaybackSessionState()
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

        // If user has already interacted this session, auto-play without popup
        if self.hasUserInteractedThisSession {
            self.logger.info("User has interacted before, auto-playing without popup")
            self.showMiniPlayer = false
            // Load the video directly - WebView session should allow autoplay
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
        } else {
            // First time: show the mini player for user interaction
            self.showMiniPlayer = true
            self.logger.info("Showing mini player for first-time user interaction")
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
        episode: ArtistEpisode? = nil
    ) async {
        self.logger.info("Playing song: \(song.title)")
        self.logger.debug("Web load strategy: \(String(describing: webLoadStrategy))")
        self.clearRestoredPlaybackSessionState()
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

        // If user has already interacted this session, auto-play without popup
        if self.hasUserInteractedThisSession {
            self.logger.info("User has interacted before, auto-playing without popup")
            self.showMiniPlayer = false
            SingletonPlayerWebView.shared.loadVideo(videoId: song.videoId, strategy: webLoadStrategy)
        } else {
            // First time: show the mini player for user interaction
            self.showMiniPlayer = true
            self.logger.info("Showing mini player for first-time user interaction")
        }

        // Fetch full song metadata if we don't have feedbackTokens
        if song.feedbackTokens == nil {
            await self.fetchSongMetadata(videoId: song.videoId)
        }
    }

    /// Called when the mini player confirms playback has started.
    /// This is the only place that should open the session autoplay gate.
    func confirmPlaybackStarted() {
        self.showMiniPlayer = false
        self.state = .playing
        self.markUserInteractedThisSession()
        self.logger.info("Playback confirmed started, user interaction recorded")
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
        let previousValue = self.currentTrackHasVideo
        self.currentTrackHasVideo = hasVideo

        if previousValue != hasVideo {
            self.logger.debug("Video availability updated: \(hasVideo)")
        }
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

        self.clearRestoredPlaybackSessionState()
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.pause()
        } else {
            await self.evaluatePlayerCommand("pause")
        }
    }

    /// Resumes playback.
    func resume() async {
        self.logger.debug("Resuming playback")

        guard let pendingPlayVideoId = self.pendingPlayVideoId else {
            self.clearRestoredPlaybackSessionState()
            await self.evaluatePlayerCommand("play")
            return
        }

        let shouldLoadPendingVideo = self.shouldLoadPendingVideoBeforePlayback
        if self.isPendingRestoredLoadDeferred {
            self.beginRestoredPlaybackLoad(autoResumeAfterSeek: self.hasUserInteractedThisSession)
        } else {
            self.clearRestoredPlaybackSessionState()
        }

        if shouldLoadPendingVideo {
            if self.hasUserInteractedThisSession {
                self.showMiniPlayer = false
                self.state = .loading
                SingletonPlayerWebView.shared.loadVideo(videoId: pendingPlayVideoId)
            } else {
                self.showMiniPlayer = true
                self.logger.info("Showing mini player so the user can resume playback")
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
        self.logger.debug("Skipping to next track")
        self.clearRestoredPlaybackSessionState()

        if !self.queue.isEmpty {
            if self.shuffleEnabled {
                let randomIndex = Int.random(in: 0 ..< self.queue.count)
                self.pushForwardSkipStackIfLeavingIndex(for: randomIndex)
                self.currentIndex = randomIndex
                if let nextSong = self.queue[safe: self.currentIndex] {
                    await self.play(song: nextSong)
                }
                await self.fetchMoreMixSongsIfNeeded()
                self.saveQueueForPersistence()
                return
            }

            if self.currentIndex < self.queue.count - 1 {
                self.pushForwardSkipStackIfLeavingIndex(for: self.currentIndex + 1)
                self.currentIndex += 1
                if let nextSong = self.queue[safe: self.currentIndex] {
                    await self.play(song: nextSong)
                }
                await self.fetchMoreMixSongsIfNeeded()
                self.saveQueueForPersistence()
            } else if self.repeatMode == .all {
                self.pushForwardSkipStackIfLeavingIndex(for: 0)
                self.currentIndex = 0
                if let firstSong = self.queue.first {
                    await self.play(song: firstSong)
                }
                self.saveQueueForPersistence()
            } else if self.mixContinuationToken != nil {
                let previousCount = self.queue.count
                await self.fetchMoreMixSongsIfNeeded()
                if self.queue.count > previousCount {
                    self.pushForwardSkipStackIfLeavingIndex(for: self.currentIndex + 1)
                    self.currentIndex += 1
                    if let nextSong = self.queue[safe: self.currentIndex] {
                        await self.play(song: nextSong)
                    }
                    self.saveQueueForPersistence()
                }
            }
            return
        }

        // Standalone artist episodes are intentionally not in the local queue.
        // Do not let them fall through to YouTube Music's ambient next button.
        guard self.currentEpisode == nil else {
            self.logger.debug("Ignoring next for standalone artist episode playback")
            return
        }

        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.next()
        }
    }

    /// Goes to previous track.
    func previous() async {
        self.logger.debug("Going to previous track")
        self.clearRestoredPlaybackSessionState()

        if !self.queue.isEmpty {
            if self.progress > 3 {
                await self.seek(to: 0)
                return
            }

            if let priorIndex = self.popForwardSkipIndex(), self.queue.indices.contains(priorIndex) {
                self.currentIndex = priorIndex
                if let prevSong = self.queue[safe: priorIndex] {
                    await self.play(song: prevSong)
                }
                self.saveQueueForPersistence()
                return
            }

            if self.currentIndex > 0 {
                self.currentIndex -= 1
                if let prevSong = self.queue[safe: self.currentIndex] {
                    await self.play(song: prevSong)
                }
                self.saveQueueForPersistence()
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
        } else {
            SingletonPlayerWebView.shared.previous()
        }
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

    /// Toggles shuffle mode.
    func toggleShuffle() {
        self.shuffleEnabled.toggle()
        if SettingsManager.shared.rememberPlaybackSettings {
            UserDefaults.standard.set(self.shuffleEnabled, forKey: Self.shuffleEnabledKey)
        }
        let status = self.shuffleEnabled ? "enabled" : "disabled"
        self.logger.info("Shuffle mode: \(status)")
    }

    /// Cycles through repeat modes: off -> all -> one -> off.
    func cycleRepeatMode() {
        self.advanceRepeatMode()
        self.logger.info("Repeat mode: \(String(describing: self.repeatMode))")
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
