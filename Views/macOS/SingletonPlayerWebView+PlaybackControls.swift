import WebKit

// MARK: - SingletonPlayerWebView Playback Controls Extension

extension SingletonPlayerWebView {
    /// Toggle play/pause.
    func playPause() {
        guard let webView else { return }
        self.logger.debug("playPause() called")

        let script = """
            (function() {
                const playBtn = document.querySelector('.play-pause-button.ytmusic-player-bar');
                if (playBtn) { playBtn.click(); return 'clicked'; }
                const video = document.querySelector('video');
                if (video) {
                    if (video.paused) { video.play(); return 'played'; }
                    else { video.pause(); return 'paused'; }
                }
                return 'no-element';
            })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error {
                self?.logger.error("playPause error: \(error.localizedDescription)")
            } else {
                self?.logger.debug("playPause result: \(String(describing: result))")
            }
        }
    }

    /// Play (resume).
    func play() {
        guard let webView else { return }
        self.logger.debug("play() called")

        let script = """
            (function() {
                const video = document.querySelector('video');
                if (video && video.paused) { video.play(); return 'played'; }
                return 'already-playing';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Pause.
    func pause() {
        guard let webView else { return }
        self.logger.debug("pause() called")

        let script = """
            (function() {
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
        self.logger.debug("next() called")

        let script = """
            (function() {
                const nextBtn = document.querySelector('.next-button.ytmusic-player-bar');
                if (nextBtn) { nextBtn.click(); return 'clicked'; }
                return 'no-button';
            })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error {
                self?.logger.error("next error: \(error.localizedDescription)")
            } else {
                self?.logger.debug("next result: \(String(describing: result))")
            }
        }
    }

    /// Go to previous track.
    func previous() {
        guard let webView else { return }
        self.logger.debug("previous() called")

        let script = """
            (function() {
                const prevBtn = document.querySelector('.previous-button.ytmusic-player-bar');
                if (prevBtn) { prevBtn.click(); return 'clicked'; }
                return 'no-button';
            })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error {
                self?.logger.error("previous error: \(error.localizedDescription)")
            } else {
                self?.logger.debug("previous result: \(String(describing: result))")
            }
        }
    }

    /// Seek to a specific time in seconds.
    func seek(to time: Double) {
        guard let webView else { return }
        self.logger.debug("seek(to: \(time)) called")

        let script = """
            (function() {
                const video = document.querySelector('video');
                if (video) { video.currentTime = \(time); return 'seeked'; }
                return 'no-video';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Set volume (0.0 - 1.0).
    func setVolume(_ volume: Double) {
        guard let webView else { return }
        let clampedVolume = max(0, min(1, volume))
        self.logger.debug("setVolume(\(clampedVolume)) called")

        // Update both the target volume (for enforcement) and the actual video volume
        let script = """
            (function() {
                // Update the target volume for enforcement
                window.__kasetTargetVolume = \(clampedVolume);
                const video = document.querySelector('video');
                if (video) {
                    video.volume = \(clampedVolume);
                    return 'set';
                }
                return 'no-video';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
