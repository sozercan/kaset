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

        let fadeEnabled = SettingsManager.shared.audioFadingEnabled

        if fadeEnabled {
            let script = """
                (function() {
                    const video = document.querySelector('video');
                    if (!video) return 'no-video';
                    if (video.paused) {
                        return 'is-paused';
                    } else {
                        return 'is-playing';
                    }
                })();
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                if let status = result as? String {
                    if status == "is-paused" {
                        self.play()
                    } else {
                        self.pause()
                    }
                } else {
                    self.play()
                }
            }
        } else {
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

    /// Resume playback with smooth in-browser audio volume fade in.
    func play() {
        guard let webView else { return }
        let script = """
            if (window.__kasetAudio) {
                window.__kasetAudio.resume(350);
            } else {
                \(Self.playCommandScript)
            }
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
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

    /// Pause with smooth in-browser audio volume fade out.
    func pause() {
        guard let webView else { return }
        let script = """
            if (window.__kasetAudio) {
                window.__kasetAudio.pause(350);
            } else {
                (function() {
                    window.__kasetAutoplayPending = false;
                    window.__kasetPlaybackSuppressed = true;
                    const video = document.querySelector('video');
                    if (video) video.pause();
                })();
            }
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Skip to next track with smooth transition.
    func next() {
        guard let webView else { return }
        let script = """
            (function() {
                const action = () => {
                    const nextBtn = document.querySelector('.next-button.ytmusic-player-bar');
                    if (nextBtn) nextBtn.click();
                };
                if (window.__kasetAudio) {
                    window.__kasetAudio.skipWithFade(150, action);
                } else {
                    action();
                }
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Go to previous track with smooth transition.
    func previous() {
        guard let webView else { return }
        let script = """
            (function() {
                const action = () => {
                    const prevBtn = document.querySelector('.previous-button.ytmusic-player-bar');
                    if (prevBtn) prevBtn.click();
                };
                if (window.__kasetAudio) {
                    window.__kasetAudio.skipWithFade(150, action);
                } else {
                    action();
                }
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Seek to a specific time in seconds, optionally with a fast fade.
    func seek(to time: Double, withFade: Bool = false) {
        guard let webView else { return }

        let script = """
            (function() {
                const action = () => {
                    const video = document.querySelector('video');
                    if (video) { video.currentTime = \(time); }
                };
                if (window.__kasetAudio && \(withFade ? "true" : "false")) {
                    // Smooth 300ms fade down/up for seamless track restart
                    window.__kasetAudio.seekWithFade(300, action);
                    return 'fading-seek';
                } else {
                    action();
                    return 'seeked';
                }
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
        let script = """
            if (window.__kasetAudio) {
                window.__kasetAudio.setTargetVolume(\(clampedVolume));
            } else {
                window.__kasetTargetVolume = \(clampedVolume);
            }
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
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
