import WebKit

// MARK: - SingletonPlayerWebView Playback Controls Extension

extension SingletonPlayerWebView {
    struct PlaybackSnapshot {
        let progress: TimeInterval
        let duration: TimeInterval
        let videoId: String?
    }

    /// Reads playback time from the live WebView video element.
    func currentPlaybackSnapshot() async -> PlaybackSnapshot? {
        guard let webView else { return nil }

        let script = """
            (function() {
                function currentPlayerData() {
                    const ytmusicPlayer = document.querySelector('ytmusic-player');
                    if (ytmusicPlayer && ytmusicPlayer.playerApi
                        && typeof ytmusicPlayer.playerApi.getVideoData === 'function') {
                        const data = ytmusicPlayer.playerApi.getVideoData();
                        if (data && typeof data === 'object') return data;
                    }

                    const moviePlayer = document.getElementById('movie_player');
                    if (moviePlayer && typeof moviePlayer.getVideoData === 'function') {
                        const data = moviePlayer.getVideoData();
                        if (data && typeof data === 'object') return data;
                    }

                    return null;
                }

                function currentVideoId() {
                    const playerData = currentPlayerData();
                    if (playerData) {
                        const playerVideoId = playerData.video_id || playerData.videoId || '';
                        if (playerVideoId) return playerVideoId;
                    }

                    try {
                        const url = new URL(window.location.href);
                        return url.searchParams.get('v') || '';
                    } catch (e) {
                        return '';
                    }
                }

                const video = document.querySelector('video');
                if (!video) return null;
                return {
                    progress: Number.isFinite(video.currentTime) ? video.currentTime : 0,
                    duration: Number.isFinite(video.duration) ? video.duration : 0,
                    videoId: currentVideoId()
                };
            })();
        """

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    self.logger.error("currentPlaybackSnapshot error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }

                guard let dictionary = result as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }

                let progress = Self.timeInterval(from: dictionary["progress"])
                let duration = Self.timeInterval(from: dictionary["duration"])
                let videoId = (dictionary["videoId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                continuation.resume(returning: PlaybackSnapshot(
                    progress: progress,
                    duration: duration,
                    videoId: videoId
                ))
            }
        }
    }

    private static func timeInterval(from value: Any?) -> TimeInterval {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let double as Double:
            double
        case let string as String:
            Double(string) ?? 0
        default:
            0
        }
    }

    nonisolated static var playPauseCommandScript: String {
        """
        (function() {
            const playBtn = document.querySelector('.play-pause-button.ytmusic-player-bar');
            if (playBtn) {
                const video = document.querySelector('video');
                const wantsPlay = !video || video.paused;
                window.__kasetAutoplayPending = wantsPlay;
                window.__kasetPlaybackSuppressed = !wantsPlay;
                if (wantsPlay) {
                    window.__kasetAutoplayAttempts = 0;
                    window.__kasetAutoplayRetryScheduled = false;
                    if (video && typeof window.__kasetAttemptAutoplayRecovery === 'function') {
                        return window.__kasetAttemptAutoplayRecovery(video, playBtn);
                    }
                }
                playBtn.click();
                return 'clicked';
            }
            const video = document.querySelector('video');
            if (video) {
                if (video.paused) {
                    window.__kasetAutoplayPending = true;
                    window.__kasetPlaybackSuppressed = false;
                    window.__kasetAutoplayAttempts = 0;
                    window.__kasetAutoplayRetryScheduled = false;
                    if (typeof window.__kasetAttemptAutoplayRecovery === 'function') {
                        return window.__kasetAttemptAutoplayRecovery(video, null);
                    }
                    video.play();
                    return 'played';
                } else {
                    window.__kasetAutoplayPending = false;
                    window.__kasetPlaybackSuppressed = true;
                    video.pause();
                    return 'paused';
                }
            }
            return 'no-element';
        })();
        """
    }

    /// Toggle play/pause.
    func playPause() {
        guard let webView else { return }
        let generation = self.documentGeneration.currentGeneration
        guard self.documentGeneration.accepts(generation: generation) else { return }

        let script = """
            if (window.__kasetDocumentGeneration === \(generation)) {
                \(Self.playPauseCommandScript)
            }
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.logger.error("playPause error: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static var playCommandScript: String {
        """
        (function() {
            window.__kasetAutoplayPending = true;
            window.__kasetPlaybackSuppressed = false;
            window.__kasetResumeAdOnly = false;
            window.__kasetAutoplayAttempts = 0;
            window.__kasetAutoplayRetryScheduled = false;
            const video = document.querySelector('video');
            if (video && video.paused) {
                if (typeof window.__kasetAttemptAutoplayRecovery === 'function') {
                    return window.__kasetAttemptAutoplayRecovery(video, null);
                }
                video.play();
                return 'played';
            }
            return video ? 'already-playing' : 'pending-media';
        })();
        """
    }

    /// Play (resume).
    func play() {
        guard let webView else { return }
        let generation = self.documentGeneration.currentGeneration
        guard self.documentGeneration.accepts(generation: generation) else { return }
        webView.evaluateJavaScript("""
            if (window.__kasetDocumentGeneration === \(generation)) {
                \(Self.playCommandScript)
            }
        """, completionHandler: nil)
    }

    /// During restored playback, a paused preroll ad must advance before the
    /// content seek can be reconciled. Never unsuppress ordinary content here.
    func resumeReadyAdvertisementIfPresent() {
        guard let webView else { return }
        let generation = self.documentGeneration.currentGeneration
        guard self.documentGeneration.accepts(generation: generation) else { return }
        webView.evaluateJavaScript("""
            (function() {
                if (window.__kasetDocumentGeneration !== \(generation)) return 'stale';
                const player = document.getElementById('movie_player');
                const isAd = !!(player && player.classList.contains('ad-showing'));
                const video = document.querySelector('video');
                if (!isAd || !video || !video.currentSrc || video.readyState < 1) return 'not-ready-ad';
                window.__kasetPlaybackSuppressed = false;
                window.__kasetAutoplayPending = true;
                window.__kasetResumeAdOnly = true;
                if (video.paused) {
                    if (typeof window.__kasetAttemptAutoplayRecovery === 'function') {
                        window.__kasetAttemptAutoplayRecovery(video, null);
                    } else {
                        video.play();
                    }
                }
                return 'playing-ad';
            })();
        """, completionHandler: nil)
    }

    /// Pause.
    func pause() {
        guard let webView else { return }

        let script = """
            (function() {
            window.__kasetAutoplayPending = false;
            window.__kasetPlaybackSuppressed = true;
                const video = document.querySelector('video');
                if (video && !video.paused) { video.pause(); return 'paused'; }
                return 'already-paused';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Skip to next track.
    func next() {
        guard let webView else { return }

        let script = """
            (function() {
                const nextBtn = document.querySelector('.next-button.ytmusic-player-bar');
                if (nextBtn) { nextBtn.click(); return 'clicked'; }
                return 'no-button';
            })();
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.logger.error("next error: \(error.localizedDescription)")
            }
        }
    }

    /// Go to previous track.
    func previous() {
        guard let webView else { return }

        let script = """
            (function() {
                const prevBtn = document.querySelector('.previous-button.ytmusic-player-bar');
                if (prevBtn) { prevBtn.click(); return 'clicked'; }
                return 'no-button';
            })();
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.logger.error("previous error: \(error.localizedDescription)")
            }
        }
    }

    /// Seek to a specific time in seconds.
    func seek(to time: Double) {
        guard let webView else { return }

        let script = """
            (function() {
                const video = document.querySelector('video');
                if (video) { video.currentTime = \(time); return 'seeked'; }
                return 'no-video';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Pure script for atomically pausing and seeking the underlying video.
    nonisolated static func seekAndPauseScript(to time: Double) -> String {
        let safeTime = time.isFinite ? max(time, 0) : 0
        return """
            (function() {
                const video = document.querySelector('video');
                if (!video) { return 'no-video'; }
                video.pause();
                video.currentTime = \(safeTime);
                video.pause();
                return 'seeked-paused';
            })();
        """
    }

    /// Atomically pause and seek the underlying video.
    func seekAndPause(to time: Double) {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.seekAndPauseScript(to: time), completionHandler: nil)
    }

    /// Seeks to the start and resumes playback without a full page load (repeat-one, same-URL recovery).
    func restartInPlaceFromBeginning() {
        if let generation = self.coordinator?.playerService.currentMusicPlaybackOccurrence?.nativeGeneration {
            self.setNativePlaybackGeneration(generation)
        }
        self.seek(to: 0)
        self.play()
    }

    /// Set volume (0.0 - 1.0).
    func setVolume(_ volume: Double) {
        guard let webView else { return }
        let clampedVolume = max(0, min(1, volume))

        // Update target volume and set video volume directly
        // Also try to set YouTube's internal player volume via their API
        let script = """
            (function() {
                window.__kasetTargetVolume = \(clampedVolume);
                const video = document.querySelector('video');
                let result = [];

                if (video) {
                    // Set flag to prevent volumechange listener from reverting
                    window.__kasetIsSettingVolume = true;
                    video.volume = \(clampedVolume);
                    result.push('video.volume=' + video.volume);
                    setTimeout(() => { window.__kasetIsSettingVolume = false; }, 50);
                } else {
                    result.push('no-video');
                }

                // Also try YouTube Music's internal player API
                const player = document.querySelector('ytmusic-player');
                if (player && player.playerApi) {
                    const ytVolume = Math.round(\(clampedVolume) * 100);
                    player.playerApi.setVolume(ytVolume);
                    result.push('ytapi.setVolume=' + ytVolume);
                }

                // Try movie_player API as fallback
                const moviePlayer = document.getElementById('movie_player');
                if (moviePlayer && moviePlayer.setVolume) {
                    const ytVolume = Math.round(\(clampedVolume) * 100);
                    moviePlayer.setVolume(ytVolume);
                    result.push('movie_player.setVolume=' + ytVolume);
                }

                return result.join(', ');
            })();
        """
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                self.logger.error("setVolume error: \(error.localizedDescription)")
            }
        }
    }

    /// Show the native AirPlay picker for the WebView's video element.
    func showAirPlayPicker() {
        guard let webView else {
            DiagnosticsLogger.airplay.warning("showAirPlayPicker called but webView is nil")
            return
        }

        let script = """
            (function() {
                const video = document.querySelector('video');
                if (!video) return 'no-video';
                if (typeof video.webkitShowPlaybackTargetPicker !== 'function') return 'unsupported';

                window.__kasetAirPlayRequested = true;
                video.webkitShowPlaybackTargetPicker();
                return 'picker-shown';
            })();
        """
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                DiagnosticsLogger.airplay.error("showAirPlayPicker error: \(error.localizedDescription)")
            } else if let status = result as? String {
                switch status {
                case "no-video":
                    DiagnosticsLogger.airplay.warning("showAirPlayPicker: no video element available")
                case "unsupported":
                    DiagnosticsLogger.airplay.warning("showAirPlayPicker: webkitShowPlaybackTargetPicker not supported")
                default:
                    DiagnosticsLogger.airplay.debug("showAirPlayPicker: \(status)")
                }
            }
        }
    }
}
