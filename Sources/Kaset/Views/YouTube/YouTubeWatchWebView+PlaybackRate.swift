import Foundation

extension YouTubeWatchWebView {
    /// Clamps a rate to the 0.25×–2× range supported by YouTube, falling back to 1× for non-finite values.
    nonisolated static func clampedPlaybackRate(_ rate: Double) -> Double {
        rate.isFinite ? min(max(rate, 0.25), 2) : 1
    }

    /// Builds the script that stores the target rate and applies it through `movie_player`
    /// and every media element, re-applying it on `loadedmetadata`, `play`, `playing` and `ratechange`.
    nonisolated static func playbackRateScript(rate: Double) -> String {
        let clamped = Self.clampedPlaybackRate(rate)
        return """
        (function() {
            'use strict';
            window.__kasetTargetPlaybackRate = \(clamped);

            function resolvedRate() {
                const rate = window.__kasetTargetPlaybackRate;
                return typeof rate === 'number' && Number.isFinite(rate) ? rate : 1;
            }

            function applyRate(media) {
                if (!media || typeof media.playbackRate !== 'number') { return; }
                const rate = resolvedRate();
                try {
                    if (Math.abs(media.playbackRate - rate) > 0.001) { media.playbackRate = rate; }
                } catch (e) {}
            }

            if (typeof window.__kasetApplyPlaybackRateToAllMedia !== 'function') {
                window.__kasetApplyPlaybackRateToAllMedia = function() {
                    const rate = resolvedRate();
                    const player = document.getElementById('movie_player');
                    if (player && typeof player.setPlaybackRate === 'function') {
                        try {
                            if (typeof player.getPlaybackRate !== 'function'
                                || Math.abs(Number(player.getPlaybackRate()) - rate) > 0.001) {
                                player.setPlaybackRate(rate);
                            }
                        } catch (e) {}
                    }
                    if (typeof document.querySelectorAll === 'function') {
                        document.querySelectorAll('video, audio').forEach(applyRate);
                    }
                };

                if (typeof document.addEventListener === 'function') {
                    ['loadedmetadata', 'play', 'playing', 'ratechange'].forEach(function(name) {
                        document.addEventListener(name, function(event) {
                            applyRate(event.target);
                        }, true);
                    });
                }
            }

            window.__kasetApplyPlaybackRateToAllMedia();
        })();
        """
    }

    /// Applies the playback rate to the currently loaded watch page.
    func setPlaybackRate(_ rate: Double) {
        self.webView?.evaluateJavaScript(Self.playbackRateScript(rate: rate), completionHandler: nil)
    }
}
