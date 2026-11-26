import WebKit

extension SingletonPlayerWebView {
    func setAutoplayBlocked(_ blocked: Bool) {
        guard let webView else { return }
        let script = """
            (function() {
                window.__kasetBlockAutoplay = \(blocked ? "true" : "false");
                if (window.__kasetAutoplayBlockTimer) {
                    clearInterval(window.__kasetAutoplayBlockTimer);
                    window.__kasetAutoplayBlockTimer = null;
                }
                if (!window.__kasetBlockAutoplay) return 'autoplay-allowed';
                window.__kasetAutoplayPending = false;
                \(WebPlaybackAudioOutput.stopScript)
                var ticks = 0;
                const timer = setInterval(function() {
                    if (!window.__kasetBlockAutoplay) {
                        clearInterval(timer);
                        if (window.__kasetAutoplayBlockTimer === timer) window.__kasetAutoplayBlockTimer = null;
                        return;
                    }
                    const video = document.querySelector('video');
                    if (video && !video.paused) {
                        try { video.pause(); } catch (_) {}
                    }
                    ticks += 1;
                    if (ticks >= 20) {
                        clearInterval(timer);
                        if (window.__kasetAutoplayBlockTimer === timer) window.__kasetAutoplayBlockTimer = null;
                    }
                }, 150);
                window.__kasetAutoplayBlockTimer = timer;
                return 'autoplay-blocked';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    struct PlaybackSnapshot {
        let progress: TimeInterval
        let duration: TimeInterval
        let videoId: String?
    }

    nonisolated static let playbackSnapshotScript = """
        (function() {
            const video = document.querySelector('video');
            if (!video || video.readyState < 1 || !video.__kasetBoundVideoId
                || !(video.__kasetMediaGeneration > 0)) return null;
            const source = video.currentSrc || video.src || '';
            if (!source || source !== video.__kasetBoundMediaSource) return null;
            return {
                progress: Number.isFinite(video.currentTime) ? video.currentTime : 0,
                duration: Number.isFinite(video.duration) ? video.duration : 0,
                videoId: video.__kasetBoundVideoId
            };
        })();
    """

    func currentPlaybackSnapshot() async -> PlaybackSnapshot? {
        guard let webView else { return nil }

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(Self.playbackSnapshotScript) { result, error in
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
            \(playerBarLookupFunctionJS)
            const playBtn = __kasetPlayerBarElement('playPause');
            if (playBtn) {
                const video = document.querySelector('video');
                const wantsPlay = !video || video.paused;
                window.__kasetAutoplayPending = wantsPlay;
                window.__kasetPlaybackSuppressed = !wantsPlay;
                if (wantsPlay) {
                    window.__kasetBlockAutoplay = false;
                    \(WebPlaybackAudioOutput.prepareScript)
                    window.__kasetAutoplayAttempts = 0;
                    window.__kasetAutoplayRetryScheduled = false;
                    if (video && typeof window.__kasetAttemptAutoplayRecovery === 'function') {
                        return window.__kasetAttemptAutoplayRecovery(video, playBtn);
                    }
                } else {
                    \(WebPlaybackAudioOutput.stopScript)
                }
                playBtn.click();
                return 'clicked';
            }
            const video = document.querySelector('video');
            if (video) {
                if (video.paused) {
                    window.__kasetAutoplayPending = true;
                    window.__kasetPlaybackSuppressed = false;
                    window.__kasetBlockAutoplay = false;
                    \(WebPlaybackAudioOutput.prepareScript)
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
                    \(WebPlaybackAudioOutput.stopScript)
                    video.pause();
                    return 'paused';
                }
            }
            return 'no-element';
        })();
        """
    }

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
            window.__kasetBlockAutoplay = false;
            window.__kasetResumeAdOnly = false;
            window.__kasetAutoplayAttempts = 0;
            window.__kasetAutoplayRetryScheduled = false;
            const video = document.querySelector('video');
            if (video && video.paused) {
                \(WebPlaybackAudioOutput.prepareScript)
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

    func resumeReadyAdvertisementIfPresent() {
        guard let webView else { return }
        let generation = self.documentGeneration.currentGeneration
        guard self.documentGeneration.accepts(generation: generation) else { return }
        webView.evaluateJavaScript("""
            (function() {
                if (window.__kasetDocumentGeneration !== \(generation)) return 'stale';
                window.__kasetBlockAutoplay = false;
                if (window.__kasetAutoplayBlockTimer) {
                    clearInterval(window.__kasetAutoplayBlockTimer);
                    window.__kasetAutoplayBlockTimer = null;
                }
                \(PlaybackAdDetectionScript.detection)
                const isAd = isAdShowing();
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

    func pause() {
        guard let webView else { return }

        let script = """
            (function() {
            window.__kasetAutoplayPending = false;
            window.__kasetPlaybackSuppressed = true;
            \(WebPlaybackAudioOutput.stopScript)
                const video = document.querySelector('video');
                if (video && !video.paused) { video.pause(); return 'paused'; }
                return 'already-paused';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func next() {
        guard let webView else { return }

        let script = """
            (function() {
                \(Self.playerBarLookupFunctionJS)
                const nextBtn = __kasetPlayerBarElement('next');
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

    func previous() {
        guard let webView else { return }

        let script = """
            (function() {
                \(Self.playerBarLookupFunctionJS)
                const prevBtn = __kasetPlayerBarElement('previous');
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

    nonisolated static func seekAndPauseScript(to time: Double) -> String {
        let safeTime = time.isFinite ? max(time, 0) : 0
        return """
            (function() {
                \(WebPlaybackAudioOutput.stopScript)
                const video = document.querySelector('video');
                if (!video) { return 'no-video'; }
                video.pause();
                video.currentTime = \(safeTime);
                video.pause();
                return 'seeked-paused';
            })();
        """
    }

    func seekAndPause(to time: Double) {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.seekAndPauseScript(to: time), completionHandler: nil)
    }

    func restartInPlaceFromBeginning() {
        guard let webView else { return }
        if let nativeGeneration = self.coordinator?.playerService.currentMusicPlaybackOccurrence?.nativeGeneration {
            self.setNativePlaybackGeneration(nativeGeneration)
        }
        let documentGeneration = self.documentGeneration.currentGeneration
        guard self.documentGeneration.accepts(generation: documentGeneration) else { return }
        let script = """
            (function() {
                if (window.__kasetDocumentGeneration !== \(documentGeneration)) return 'stale';
                window.__kasetBlockAutoplay = false;
                if (window.__kasetAutoplayBlockTimer) {
                    clearInterval(window.__kasetAutoplayBlockTimer);
                    window.__kasetAutoplayBlockTimer = null;
                }
                window.__kasetAutoplayPending = true;
                window.__kasetPlaybackSuppressed = false;
                window.__kasetResumeAdOnly = false;
                window.__kasetAutoplayAttempts = 0;
                window.__kasetAutoplayRetryScheduled = false;
                const video = document.querySelector('video');
                if (!video) return 'no-video';
                video.currentTime = 0;
                if (typeof window.__kasetAdvanceMediaGeneration === 'function') {
                    window.__kasetAdvanceMediaGeneration();
                }
                if (typeof window.__kasetAttemptAutoplayRecovery === 'function') {
                    window.__kasetAttemptAutoplayRecovery(video, null);
                } else {
                    video.play();
                }
                return 'restarted';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func setVolume(_ volume: Double) {
        guard let webView else { return }
        let clampedVolume = max(0, min(1, volume))

        let script = """
            (function() {
                window.__kasetTargetVolume = \(clampedVolume);
                const video = document.querySelector('video');
                let result = [];

                if (video) {
                    window.__kasetIsSettingVolume = true;
                    video.volume = \(clampedVolume);
                    result.push('video.volume=' + video.volume);
                    setTimeout(() => { window.__kasetIsSettingVolume = false; }, 50);
                } else {
                    result.push('no-video');
                }

                const player = document.querySelector('ytmusic-player');
                if (player && player.playerApi) {
                    const ytVolume = Math.round(\(clampedVolume) * 100);
                    player.playerApi.setVolume(ytVolume);
                    result.push('ytapi.setVolume=' + ytVolume);
                }

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

    func showAirPlayPicker(at screenPoint: CGPoint? = nil) {
        guard let webView else {
            DiagnosticsLogger.airplay.warning("showAirPlayPicker called but webView is nil")
            return
        }

        AirPlayPickerAnchor.preparePicker(in: webView, at: screenPoint)

        let script = """
            (function() {
                const video = document.querySelector('video');
                if (!video) return 'no-video';
                if (typeof video.webkitShowPlaybackTargetPicker !== 'function') return 'unsupported';

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
