/// Keeps WebKit's audio output open across short music playback transitions.
enum WebPlaybackAudioOutput {
    nonisolated static let script = """
    (() => {
        if (window.__kasetAudioOutput) return;
        let output = null;
        let releaseTimer = null;

        function clearReleaseTimer() {
            if (releaseTimer !== null) clearTimeout(releaseTimer);
            releaseTimer = null;
        }

        function stop() {
            clearReleaseTimer();
            const previous = output;
            output = null;
            if (!previous) return;
            try { previous.source.stop(); } catch (_) {}
            try { previous.source.disconnect(); } catch (_) {}
            try { previous.gain.disconnect(); } catch (_) {}
            try { previous.context.close().catch(() => {}); } catch (_) {}
        }

        function start() {
            const video = document.querySelector('video');
            if (window.__kasetPlaybackSuppressed || window.__kasetBlockAutoplay
                || (video && video.webkitCurrentPlaybackTargetIsWireless)) {
                stop();
                return;
            }
            clearReleaseTimer();
            try {
                if (!output) {
                    const context = new AudioContext();
                    output = { context, source: null, gain: null };
                    const source = context.createOscillator();
                    output.source = source;
                    const gain = context.createGain();
                    output.gain = gain;
                    // No media is routed through this graph. Zero gain keeps the
                    // output active without altering DRM playback or its volume.
                    gain.gain.value = 0;
                    source.connect(gain);
                    gain.connect(context.destination);
                    source.start();
                }
                const pending = output;
                pending.context.resume().catch(() => {
                    if (output === pending) stop();
                });
            } catch (_) {
                stop();
            }
        }

        function releaseAfterTransition() {
            if (!output || releaseTimer !== null) return;
            // A failed load or the end of the queue must not leave silent output
            // running indefinitely. Normal transitions finish well within this.
            releaseTimer = setTimeout(stop, 5000);
        }

        function prepare() {
            start();
            releaseAfterTransition();
        }

        function observe(event, handler) {
            document.addEventListener(event, event => {
                const video = event.target;
                if (video && video.tagName === 'VIDEO'
                    && video === document.querySelector('video')) handler(video);
            }, true);
        }

        observe('play', prepare);
        observe('playing', start);
        observe('loadstart', () => {
            if (window.__kasetAutoplayPending) prepare();
        });
        observe('pause', video => {
            if (!window.__kasetPlaybackSuppressed && !window.__kasetBlockAutoplay
                && (video.ended || window.__kasetAutoplayPending)) {
                releaseAfterTransition();
            } else {
                stop();
            }
        });
        observe('ended', releaseAfterTransition);
        observe('emptied', releaseAfterTransition);
        observe('error', stop);
        observe('webkitcurrentplaybacktargetiswirelesschanged', video => {
            if (video.webkitCurrentPlaybackTargetIsWireless) stop();
            else if (!video.paused) start();
        });
        let currentVideo = document.querySelector('video');
        const mediaObserver = new MutationObserver(() => {
            const video = document.querySelector('video');
            if (video === currentVideo) return;
            currentVideo = video;
            // Detached media no longer sends events through this document.
            // Bound the wait for a replacement that has not started playing.
            if (video && !video.paused && !video.ended && video.readyState >= 3) start();
            else releaseAfterTransition();
        });
        mediaObserver.observe(document, { childList: true, subtree: true });
        window.addEventListener('pagehide', () => {
            mediaObserver.disconnect();
            stop();
        });
        window.__kasetAudioOutput = { prepare, stop };
        if (window.__kasetAutoplayPending) prepare();
    })();
    """

    nonisolated static let stopScript = "window.__kasetAudioOutput?.stop();"
    nonisolated static let prepareScript = "window.__kasetAudioOutput?.prepare();"
}
