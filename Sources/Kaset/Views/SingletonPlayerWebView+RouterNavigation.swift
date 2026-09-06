import Foundation

extension SingletonPlayerWebView {
    // swiftlint:disable function_body_length
    /// Retries an AirPlay handoff that leaves the requested player unstarted.
    /// The retry stays inside the current document so WebKit can reuse its receiver.
    nonisolated static func routerNavigationScript(videoId: String, generation: Int) -> String {
        let videoIdLiteral = Self.javaScriptStringLiteral(videoId)
        return """
        (function() {
            const previousRetry = window.__kasetAirPlayNavigationRetry;
            previousRetry?.cancel();
            const app = document.querySelector('ytmusic-app');
            if (!app || typeof app.resolveCommand !== 'function') return false;

            const videoId = \(videoIdLiteral);
            const video = document.querySelector('video');
            const player = document.querySelector('ytmusic-player');
            const api = player && player.playerApi || document.getElementById('movie_player');
            const playbackGeneration = window.__kasetNativePlaybackGeneration;
            let observationTimer = null;
            let unstartedAt = null;
            let confirmedFailureAt = null;
            let didRetry = false;
            const retry = { generation: \(generation), cancel: cancelRetry };
            \(PlaybackAdDetectionScript.detection)

            function stopObservingPlayer() {
                if (observationTimer !== null) clearTimeout(observationTimer);
                observationTimer = null;
                if (api && typeof api.removeEventListener === 'function') {
                    api.removeEventListener('onStateChange', handleStateChange);
                    api.removeEventListener('onError', handlePlayerError);
                }
            }

            function cancelRetry() {
                stopObservingPlayer();
                window.removeEventListener('pagehide', cancelRetry);
                if (window.__kasetAirPlayNavigationRetry === retry) {
                    window.__kasetAirPlayNavigationRetry = null;
                }
            }

            function isCurrentRequest() {
                return window.__kasetAirPlayNavigationRetry === retry
                    && window.__kasetNativePlaybackGeneration === playbackGeneration;
            }

            function targetIsUnstarted() {
                if (video !== document.querySelector('video') || video.readyState !== 0) return false;
                if (isAdShowing()) return false;
                try {
                    const data = api.getVideoData();
                    return !!data && (data.video_id || data.videoId) === videoId
                        && api.getPlayerState() === -1;
                } catch (_) {
                    return false;
                }
            }

            function handleStateChange(event) {
                const state = typeof event === 'number' ? event : event && event.data;
                if (state !== -1) {
                    unstartedAt = null;
                    confirmedFailureAt = null;
                    return;
                }
                observeTarget();
            }

            function handlePlayerError(event) {
                const code = typeof event === 'number' ? event : event && event.data;
                if (code !== 150 || !isCurrentRequest() || didRetry || !targetIsUnstarted()) return;
                // In the failing AirPlay handoff, error 5 precedes 150. Let
                // YouTube's final error handlers settle before the one retry.
                if (confirmedFailureAt === null) confirmedFailureAt = performance.now();
                observeTarget();
            }

            function observeTarget() {
                if (!isCurrentRequest()) {
                    cancelRetry();
                    return;
                }
                if (didRetry) return;
                if (observationTimer !== null) clearTimeout(observationTimer);
                observationTimer = null;
                let nextObservationDelay = 250;

                if (targetIsUnstarted()) {
                    const now = performance.now();
                    if (unstartedAt === null) unstartedAt = now;
                    const retryAt = Math.min(unstartedAt + 1000,
                        confirmedFailureAt === null ? Infinity : confirmedFailureAt + 250);
                    if (now >= retryAt) {
                        didRetry = true;
                        stopObservingPlayer();
                        // Keep ownership until media confirmation so a rapid skip
                        // can inherit the handoff while the wireless flag is false.
                        try {
                            app.resolveCommand({ watchEndpoint: { videoId: videoId } });
                        } catch (_) {
                            cancelRetry();
                        }
                        return;
                    }
                    nextObservationDelay = Math.min(nextObservationDelay, retryAt - now);
                } else {
                    unstartedAt = null;
                    confirmedFailureAt = null;
                }

                // YouTube can update track identity and media readiness after its
                // state callback. Observe the pending target until confirmation,
                // allowing normal loading a full second unless it reports failure.
                observationTimer = setTimeout(observeTarget, nextObservationDelay);
            }

            if (video && (video.webkitCurrentPlaybackTargetIsWireless || previousRetry)
                && api && typeof api.getVideoData === 'function'
                && typeof api.getPlayerState === 'function'
                && typeof api.addEventListener === 'function'
                && typeof api.removeEventListener === 'function') {
                window.__kasetAirPlayNavigationRetry = retry;
                api.addEventListener('onStateChange', handleStateChange);
                api.addEventListener('onError', handlePlayerError);
                window.addEventListener('pagehide', cancelRetry, { once: true });
                observationTimer = setTimeout(observeTarget, 250);
            }

            try {
                app.resolveCommand({ watchEndpoint: { videoId: videoId } });
                return true;
            } catch (_) {
                cancelRetry();
                return false;
            }
        })();
        """
    }

    // swiftlint:enable function_body_length

    nonisolated static func routerNavigationRetryCancellationScript(generation: Int) -> String {
        """
        (function() {
            const retry = window.__kasetAirPlayNavigationRetry;
            if (retry && retry.generation === \(generation)) retry.cancel();
        })();
        """
    }
}
