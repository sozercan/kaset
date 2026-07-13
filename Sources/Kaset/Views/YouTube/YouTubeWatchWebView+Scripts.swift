// swiftlint:disable file_length

import Foundation

// MARK: - Observer & Extraction Scripts

extension YouTubeWatchWebView {
    func markCurrentPlaybackOccurrenceEnded() {
        guard let webView = self.webView else { return }
        let generation = self.documentGeneration.currentGeneration
        guard self.documentGeneration.accepts(generation: generation) else { return }
        webView.evaluateJavaScript(
            """
            if (window.__kasetDocumentGeneration === \(generation)) {
                const video = document.querySelector('video');
                if (video) { video.__kasetEndedReported = true; }
            }
            """,
            completionHandler: nil
        )
    }

    /// Observer script for youtube.com watch pages.
    ///
    /// Posts event-driven `STATE_UPDATE` and `VIDEO_ENDED` messages to the
    /// `youtubePlayer` bridge. Progress updates are driven by media events, with
    /// forced final updates on pause/seek/end, so paused pages do not keep a 1 Hz
    /// bridge loop alive. Also enforces the Kaset-managed volume target the same
    /// way the music observer does.
    static var observerScript: String {
        """
        (function() {
            'use strict';

            const bridge = window.webkit.messageHandlers.youtubePlayer;
            const UPDATE_THROTTLE_MS = 1000;
            const MAX_ATTACH_RETRIES = 20;
            var mediaGeneration = 0;
            var mediaVideoId = '';
            var mediaSource = '';
            var lastMediaCurrentTime = 0;
            var mediaIdentityNeedsRefresh = false;
            var lastUpdateTime = 0;
            var trailingUpdateTimeoutId = null;
            var attachRetryCount = 0;
            var attachRetryTimeoutId = null;
            var attachDebounceTimeoutId = null;
            var videoObserver = null;

            function moviePlayer() {
                return document.getElementById('movie_player');
            }

            function videoEl() {
                return document.querySelector('#movie_player video') || document.querySelector('video');
            }

            function videoData() {
                const player = moviePlayer();
                if (player && typeof player.getVideoData === 'function') {
                    try { return player.getVideoData(); } catch (e) { return null; }
                }
                return null;
            }

            function currentVideoId() {
                const data = videoData();
                return (data && (data.video_id || data.videoId)) || '';
            }

            function currentTitle() {
                const data = videoData();
                if (data && data.title) { return data.title; }
                return document.title.replace(/ - YouTube$/, '');
            }

            function isAdShowing() {
                const player = moviePlayer();
                return !!(player && player.classList && player.classList.contains('ad-showing'));
            }

            function clearTrailingUpdate() {
                if (trailingUpdateTimeoutId) {
                    clearTimeout(trailingUpdateTimeoutId);
                    trailingUpdateTimeoutId = null;
                }
            }

            function sendUpdate(force) {
                try {
                    const video = videoEl();
                    if (!video) { return; }
                    bindVideoIdentity(video, false);
                    applyPendingSeek(video);

                    if (force) {
                        clearTrailingUpdate();
                    } else {
                        const now = Date.now();
                        const elapsed = now - lastUpdateTime;
                        if (elapsed < UPDATE_THROTTLE_MS) {
                            if (!trailingUpdateTimeoutId && !video.paused && !video.ended) {
                                trailingUpdateTimeoutId = setTimeout(function() {
                                    trailingUpdateTimeoutId = null;
                                    sendUpdate(true);
                                }, UPDATE_THROTTLE_MS - elapsed);
                            }
                            return;
                        }
                    }
                    lastUpdateTime = Date.now();

                    const videoId = currentVideoId();
                    const hasReadyMedia = !!(video.currentSrc && video.readyState >= 1);
                    const pendingSeekApplied = window.__kasetPendingSeekApplied === true;
                    const pendingSeekFailed = window.__kasetPendingSeekFailed === true;
                    const pendingSeekTarget = window.__kasetPendingSeekResultTarget;
                    const pendingSeekVideoId = window.__kasetPendingSeekResultVideoId || '';
                    const pendingSeekAttempt = window.__kasetPendingSeekAttempt;
                    const nativePausePending = window.__kasetNativePausePending === true;
                    bridge.postMessage({
                        type: 'STATE_UPDATE',
                        documentGeneration: window.__kasetDocumentGeneration,
                        mediaGeneration: video.__kasetMediaGeneration || mediaGeneration,
                        isPlaying: !video.paused && !video.ended,
                        progress: video.currentTime || 0,
                        duration: (video.duration && isFinite(video.duration)) ? video.duration : 0,
                        hasReadyMedia: hasReadyMedia,
                        videoId: videoId,
                        boundVideoId: video.__kasetBoundVideoId || '',
                        title: currentTitle(),
                        isAd: isAdShowing(),
                        pendingSeekApplied: pendingSeekApplied,
                        pendingSeekFailed: pendingSeekFailed,
                        pendingSeekTarget: pendingSeekTarget,
                        pendingSeekVideoId: pendingSeekVideoId,
                        pendingSeekAttempt: pendingSeekAttempt,
                        nativePausePending: nativePausePending
                        ,eventIssuedAtMilliseconds: (typeof performance !== 'undefined'
                            && Number.isFinite(performance.timeOrigin)
                            && typeof performance.now === 'function')
                            ? performance.timeOrigin + performance.now()
                            : Date.now()
                    });
                    if (pendingSeekApplied) window.__kasetPendingSeekApplied = false;
                    if (pendingSeekFailed) window.__kasetPendingSeekFailed = false;
                    if (pendingSeekApplied || pendingSeekFailed) {
                        window.__kasetPendingSeekResultTarget = null;
                        window.__kasetPendingSeekResultVideoId = null;
                    }
                } catch (e) {
                    console.log('[KasetYT] update error: ' + e);
                }
            }

            function bindVideoIdentity(video, transitionEvidence) {
                if (!video || video !== videoEl()) { return; }
                const videoId = currentVideoId();
                const resolvedVideoId = videoId
                    || (!video.__kasetBoundVideoId
                        ? (window.__kasetPendingSeekVideoId || '')
                        : '');
                const source = video.currentSrc || video.src || '';
                const currentTime = Number.isFinite(video.currentTime) ? video.currentTime : 0;
                const hasBoundOccurrence = !!video.__kasetMediaGeneration;
                const isReplacementElement = !hasBoundOccurrence && mediaGeneration > 0;
                const previousMediaVideoId = mediaVideoId;
                const sourceChanged = hasBoundOccurrence && source !== mediaSource;
                const mediaTimeReset = hasBoundOccurrence && currentTime + 2 < lastMediaCurrentTime;
                const identityChanged = !!resolvedVideoId
                    && !!mediaVideoId
                    && resolvedVideoId !== mediaVideoId;
                const identityBecameKnown = !!resolvedVideoId && !mediaVideoId;
                const shouldBind = !hasBoundOccurrence
                    || sourceChanged
                    || mediaTimeReset
                    || (identityChanged && transitionEvidence === true);

                if (!shouldBind) {
                    if (identityBecameKnown || (identityChanged && mediaIdentityNeedsRefresh)) {
                        mediaVideoId = resolvedVideoId;
                        video.__kasetBoundVideoId = resolvedVideoId;
                        mediaIdentityNeedsRefresh = false;
                    }
                    if (!identityChanged) lastMediaCurrentTime = currentTime;
                    return;
                }

                mediaGeneration += 1;
                mediaVideoId = resolvedVideoId;
                mediaSource = source;
                lastMediaCurrentTime = currentTime;
                mediaIdentityNeedsRefresh = (isReplacementElement || sourceChanged || mediaTimeReset)
                    && (!resolvedVideoId || resolvedVideoId === previousMediaVideoId);
                video.__kasetMediaGeneration = mediaGeneration;
                video.__kasetEndedReported = false;
                video.__kasetBoundVideoId = resolvedVideoId;
                window.__kasetPendingSeekInFlightAttempt = null;
            }

            function armEndedOccurrence(video) {
                if (!video || video !== videoEl() || video.ended) { return; }
                bindVideoIdentity(video, false);
                if (video.__kasetEndedReported === true) {
                    mediaGeneration += 1;
                    video.__kasetMediaGeneration = mediaGeneration;
                }
                video.__kasetEndedReported = false;
            }

            function sendEnded(video) {
                if (video !== videoEl() || !video.ended || video.__kasetEndedReported === true) {
                    return;
                }
                video.__kasetEndedReported = true;
                bridge.postMessage({
                    type: 'VIDEO_ENDED',
                    documentGeneration: window.__kasetDocumentGeneration,
                    mediaGeneration: video.__kasetMediaGeneration || mediaGeneration,
                    pendingSeekAttempt: window.__kasetPendingSeekAttempt,
                    eventIssuedAtMilliseconds: Date.now(),
                    videoId: video.__kasetBoundVideoId || currentVideoId(),
                    isAd: isAdShowing()
                });
            }

            function enforceVolume(video) {
                if (window.__kasetIsSettingVolume) { return; }
                const target = window.__kasetTargetVolume;
                // YouTube persists its own mute state across sessions; Kaset
                // owns audio, so unmute whenever our target volume is audible.
                if (typeof target === 'number' && target > 0 && video.muted) {
                    video.muted = false;
                    const player = moviePlayer();
                    if (player && typeof player.unMute === 'function') {
                        try { player.unMute(); } catch (e) {}
                    }
                }
                if (typeof target === 'number' && Math.abs(video.volume - target) > 0.01) {
                    window.__kasetIsSettingVolume = true;
                    video.volume = target;
                    setTimeout(function() { window.__kasetIsSettingVolume = false; }, 50);
                }
            }

            // Apply a pending resume-seek from a session-identity-switch reload.
            // The <video> is created by the player JS after navigation and may
            // not be seekable immediately, so this is called from attach() and
            // media readiness/progress events until metadata is ready. Scoped to
            // this document: window.__kasetPendingSeek is re-injected per page
            // load, so it cannot leak into a later video.
            function applyPendingSeek(video) {
                const target = window.__kasetPendingSeek;
                if (typeof target !== 'number') { return; }
                // An ad can expose the creative's video ID; never consume the
                // requested content seek against advertisement media.
                if (isAdShowing()) { return; }
                if (video.readyState < 1 || !video.currentSrc) { return; }
                const expectedVideoId = window.__kasetPendingSeekVideoId;
                const boundVideoId = video.__kasetBoundVideoId || '';
                if (expectedVideoId && boundVideoId !== expectedVideoId) {
                    // Metadata can lead the physical media during SPA changes.
                    // Keep the target armed until this element is actually bound
                    // to the requested content occurrence.
                    return;
                }
                if (!video.seekable || video.seekable.length === 0) { return; }
                const seekAttempt = window.__kasetPendingSeekAttempt || 0;
                window.__kasetPendingSeekAttempt = seekAttempt;
                if (window.__kasetPendingSeekInFlightAttempt === seekAttempt) { return; }
                window.__kasetPendingSeekInFlightAttempt = seekAttempt;
                try {
                    const seekMediaGeneration = video.__kasetMediaGeneration || 0;
                    const seekSource = video.currentSrc;
                    function stillOwnsSeekOperation() {
                        return video === videoEl()
                            && window.__kasetPendingSeek === target
                            && (window.__kasetPendingSeekVideoId || '') === (expectedVideoId || '')
                            && (video.__kasetBoundVideoId || '') === (expectedVideoId || '')
                            && (video.__kasetMediaGeneration || 0) === seekMediaGeneration
                            && video.currentSrc === seekSource
                            && window.__kasetPendingSeekAttempt === seekAttempt
                            && window.__kasetPendingSeekInFlightAttempt === seekAttempt;
                    }
                    const firstSeekable = video.seekable.start(0);
                    const lastSeekable = video.seekable.end(video.seekable.length - 1);
                    const hasFiniteDuration = video.duration && isFinite(video.duration);
                    const resolvedTarget = hasFiniteDuration
                        ? Math.min(Math.max(target, 0), video.duration)
                        : Math.min(Math.max(target, firstSeekable), lastSeekable);
                    window.__kasetPendingSeekWaits = 0;
                    video.currentTime = resolvedTarget;
                    function reportSeekResult() {
                        if (!stillOwnsSeekOperation()) return;
                        if (Math.abs(video.currentTime - resolvedTarget) <= 1.5) {
                            window.__kasetPendingSeek = null;
                            window.__kasetPendingSeekVideoId = null;
                            window.__kasetPendingSeekWaits = 0;
                            window.__kasetPendingSeekApplied = true;
                            window.__kasetPendingSeekResultTarget = target;
                            window.__kasetPendingSeekResultVideoId = expectedVideoId
                                || currentVideoId()
                                || video.__kasetBoundVideoId
                                || '';
                        } else {
                            window.__kasetPendingSeek = null;
                            window.__kasetPendingSeekVideoId = null;
                            window.__kasetPendingSeekWaits = 0;
                            window.__kasetPendingSeekFailed = true;
                            window.__kasetPendingSeekResultTarget = target;
                            window.__kasetPendingSeekResultVideoId = expectedVideoId
                                || currentVideoId()
                                || video.__kasetBoundVideoId
                                || '';
                        }
                        window.__kasetPendingSeekInFlightAttempt = null;
                        sendUpdate(true);
                    }
                    // Re-assert once if the player clobbers currentTime back near 0,
                    // then wait again before reporting success.
                    setTimeout(function() {
                        if (!stillOwnsSeekOperation()) return;
                        if (Math.abs(video.currentTime - resolvedTarget) > 1.5) {
                            try { video.currentTime = resolvedTarget; } catch (e) {}
                            setTimeout(reportSeekResult, 400);
                            return;
                        }
                        reportSeekResult();
                    }, 400);
                } catch (e) {
                    if (window.__kasetPendingSeekInFlightAttempt === seekAttempt) {
                        window.__kasetPendingSeekInFlightAttempt = null;
                    }
                }
            }

            function disableAutonav() {
                try {
                    const toggle = document.querySelector('.ytp-autonav-toggle-button');
                    if (toggle && toggle.getAttribute('aria-checked') === 'true') {
                        toggle.click();
                        console.log('[KasetYT] Disabled YouTube autonav');
                    }
                } catch (e) {}
            }

            function eventVideo(event) {
                return (event && event.currentTarget) || videoEl();
            }

            function handlePlaybackStarted(event) {
                const video = eventVideo(event);
                if (!video) return;
                bindVideoIdentity(video, false);
                armEndedOccurrence(video);
                enforceVolume(video);
                sendUpdate(true);
            }

            function handlePlaybackStopped(event) {
                const video = eventVideo(event);
                if (!video) return;
                if (event && event.type === 'pause') {
                    window.__kasetNativePausePending = false;
                }
                if (event && (event.type === 'loadedmetadata' || event.type === 'canplay')) {
                    bindVideoIdentity(video, true);
                } else {
                    bindVideoIdentity(video, false);
                }
                if (event && (event.type === 'seeked' || event.type === 'loadedmetadata'
                    || event.type === 'canplay')) {
                    armEndedOccurrence(video);
                }
                sendUpdate(true);
            }

            function handleTimelineUpdate(event) {
                const video = eventVideo(event);
                if (!video) return;
                bindVideoIdentity(video, false);
                applyPendingSeek(video);
                if (!video.paused && !video.ended) {
                    sendUpdate(false);
                }
            }

            function handleEnded(event) {
                const endedVideo = event.currentTarget;
                sendUpdate(true);
                sendEnded(endedVideo);
            }

            function attach() {
                disableAutonav();
                const video = videoEl();
                if (!video) { return false; }
                const videoId = currentVideoId();
                if (video.__kasetAttached) {
                    applyPendingSeek(video);
                    if (videoId && video.__kasetAttachedVideoId !== videoId) {
                        video.__kasetAttachedVideoId = videoId;
                        bindVideoIdentity(video, true);
                        armEndedOccurrence(video);
                        sendUpdate(true);
                    }
                    return true;
                }
                video.__kasetAttached = true;
                video.__kasetAttachedVideoId = videoId || '';
                video.__kasetEndedReported = false;
                bindVideoIdentity(video, video.readyState >= 1);
                armEndedOccurrence(video);
                attachRetryCount = 0;

                ['play', 'playing'].forEach(function(evt) {
                    video.addEventListener(evt, handlePlaybackStarted);
                });
                ['pause', 'seeked', 'loadedmetadata', 'durationchange', 'canplay', 'waiting'].forEach(function(evt) {
                    video.addEventListener(evt, handlePlaybackStopped);
                });
                video.addEventListener('timeupdate', handleTimelineUpdate);
                video.addEventListener('ended', handleEnded);
                video.addEventListener('volumechange', function() {
                    enforceVolume(video);
                });

                enforceVolume(video);
                applyPendingSeek(video);
                sendUpdate(true);
                return true;
            }

            function scheduleAttach() {
                if (attachDebounceTimeoutId) { return; }
                attachDebounceTimeoutId = setTimeout(function() {
                    attachDebounceTimeoutId = null;
                    attach();
                }, 100);
            }

            function installVideoObserver() {
                if (videoObserver || typeof MutationObserver !== 'function') { return false; }
                const root = document.documentElement || document.body;
                if (!root) { return false; }
                videoObserver = new MutationObserver(scheduleAttach);
                videoObserver.observe(root, { childList: true, subtree: true });
                return true;
            }

            function attachWithBoundedRetry() {
                if (attach()) { return; }
                if (!installVideoObserver() && attachRetryCount < MAX_ATTACH_RETRIES && !attachRetryTimeoutId) {
                    attachRetryCount += 1;
                    attachRetryTimeoutId = setTimeout(function() {
                        attachRetryTimeoutId = null;
                        attachWithBoundedRetry();
                    }, 500);
                }
            }

            installVideoObserver();
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', attachWithBoundedRetry);
            } else {
                attachWithBoundedRetry();
            }
        })();
        """
    }

    /// Document-start blackout: the page is black from its very first paint
    /// so YouTube's layout never flashes before extraction runs. Uses
    /// element selectors only, so the extraction script's class-based
    /// `.kaset-visible` chain (and caption whitelists) win once applied.
    static var blackoutScript: String {
        """
        (function() {
            'use strict';
            const style = document.createElement('style');
            style.id = 'kaset-yt-blackout';
            style.textContent = `
                html, body { background: #000 !important; }
                html *, body * { visibility: hidden !important; }
            `;
            document.documentElement.appendChild(style);
        })();
        """
    }

    /// Extraction script: hides all youtube.com chrome and leaves only the
    /// video surface visible, so the WebView can dock into native views.
    ///
    /// Same ancestor-chain visibility approach as the music video mode
    /// (`SingletonPlayerWebView+VideoMode`), targeting the watch-page DOM.
    /// Defines `window.__kasetExtractVideo()` and runs it; `didFinish` calls
    /// it again for cached/fast loads. Enforcement uses bounded RAF bursts plus
    /// a DOM observer so steady state does not keep a per-frame loop alive.
    static var extractionScript: String {
        """
        (function() {
            'use strict';

            const styleId = 'kaset-yt-video-style';
            const MAX_ENFORCEMENT_FRAMES = 12;
            const MUTATION_ENFORCEMENT_FRAMES = 6;

            function ensureStyle() {
                let style = document.getElementById(styleId);
                if (!style) {
                    style = document.createElement('style');
                    style.id = styleId;
                    document.head.appendChild(style);
                }

                style.textContent = `
                    /* Hide everything by default */
                    html, body, * {
                        visibility: hidden !important;
                    }

                    /* Show precisely the video's ancestor chain */
                    .kaset-visible {
                        visibility: visible !important;
                        opacity: 1 !important;
                        padding: 0 !important;
                        margin: 0 !important;
                        background: #000 !important;
                    }

                    .kaset-visible {
                        width: 100vw !important;
                        height: 100vh !important;
                        position: fixed !important;
                        top: 0 !important;
                        left: 0 !important;
                        overflow: visible !important;
                    }

                    video.kaset-visible {
                        z-index: 2147483647 !important;
                        object-fit: contain !important;
                    }

                    /* Captions are overlay siblings of the video, not
                       ancestors — keep them visible above it. */
                    .ytp-caption-window-container,
                    .ytp-caption-window-container *,
                    .caption-window, .caption-window * {
                        visibility: visible !important;
                        z-index: 2147483647 !important;
                    }

                    /* YouTube raises captions when its (invisible) controls
                       show on hover — pin them to the bottom instead. */
                    .caption-window.ytp-caption-window-bottom {
                        bottom: 4% !important;
                        top: auto !important;
                        margin-bottom: 0 !important;
                    }

                    /* Keep YouTube's own controls/overlays hidden */
                    .ytp-chrome-bottom, .ytp-chrome-top, .ytp-gradient-bottom,
                    .ytp-gradient-top, .ytp-ce-element, .ytp-cards-teaser,
                    .ytp-pause-overlay, .ytp-endscreen-content {
                        display: none !important;
                    }

                    /* YouTube hides the cursor over an idle player
                       (ytp-autohide sets cursor: none); the native app owns
                       the cursor, so force it back everywhere. */
                    html, body, #movie_player, #movie_player *, video {
                        cursor: auto !important;
                    }

                    html, body {
                        background: #000 !important;
                        overflow: hidden !important;
                        visibility: visible !important;
                    }
                `;
            }

            function extractionState() {
                if (!window.__kasetYTExtraction) {
                    window.__kasetYTExtraction = {
                        active: false,
                        observer: null,
                        markedObserver: null,
                        markedElements: [],
                        rafScheduled: false,
                        rafHandle: null,
                        remainingFrames: 0
                    };
                }
                return window.__kasetYTExtraction;
            }

            function clearMarkers() {
                document.querySelectorAll('.kaset-visible').forEach(function(el) {
                    el.classList.remove('kaset-visible');
                });
            }

            function stopExtraction() {
                const state = extractionState();
                state.active = false;
                window.__kasetYTVideoActive = false;
                state.remainingFrames = 0;
                if (state.observer) {
                    state.observer.disconnect();
                    state.observer = null;
                }
                if (state.markedObserver) {
                    state.markedObserver.disconnect();
                    state.markedObserver = null;
                }
                state.markedElements = [];
                if (state.rafHandle !== null && typeof cancelAnimationFrame === 'function') {
                    cancelAnimationFrame(state.rafHandle);
                }
                state.rafScheduled = false;
                state.rafHandle = null;
                clearMarkers();
            }

            function markAncestors() {
                const state = extractionState();
                if (!window.__kasetYTVideoActive) { return false; }
                const video = document.querySelector('#movie_player video') || document.querySelector('video');
                if (!video) { return false; }

                const visibleChain = [];
                let current = video;
                while (current && current !== document.documentElement) {
                    visibleChain.push(current);
                    current = current.parentElement;
                }

                document.querySelectorAll('.kaset-visible').forEach(function(el) {
                    if (visibleChain.indexOf(el) === -1) {
                        el.classList.remove('kaset-visible');
                    }
                });
                visibleChain.forEach(function(el) {
                    el.classList.add('kaset-visible');
                });
                state.markedElements = visibleChain;
                reobserveMarkedElements();
                return true;
            }

            function reobserveMarkedElements() {
                const state = extractionState();
                if (!state.markedObserver) { return; }
                state.markedObserver.disconnect();
                state.markedElements.forEach(function(el) {
                    state.markedObserver.observe(el, {
                        attributes: true,
                        attributeFilter: ['class', 'style', 'hidden']
                    });
                });
            }

            function runEnforcementFrame() {
                const state = extractionState();
                state.rafScheduled = false;
                state.rafHandle = null;
                if (!state.active || !window.__kasetYTVideoActive) { return; }
                markAncestors();
                state.remainingFrames -= 1;
                if (state.remainingFrames > 0) {
                    scheduleEnforcement(0);
                }
            }

            function scheduleEnforcement(frameCount) {
                const state = extractionState();
                if (!state.active || !window.__kasetYTVideoActive) { return; }
                state.remainingFrames = Math.max(state.remainingFrames, frameCount);
                if (state.rafScheduled) { return; }
                state.rafScheduled = true;
                state.rafHandle = requestAnimationFrame(runEnforcementFrame);
            }

            function installObserver() {
                const state = extractionState();
                if (state.observer || typeof MutationObserver !== 'function') { return; }
                const root = document.documentElement || document.body;
                if (!root) { return; }
                state.observer = new MutationObserver(function() {
                    if (state.active && window.__kasetYTVideoActive) {
                        scheduleEnforcement(MUTATION_ENFORCEMENT_FRAMES);
                    }
                });
                state.observer.observe(root, { childList: true, subtree: true });
                state.markedObserver = new MutationObserver(function() {
                    if (state.active && window.__kasetYTVideoActive) {
                        scheduleEnforcement(1);
                    }
                });
                reobserveMarkedElements();
            }

            window.__kasetStopYTExtraction = stopExtraction;

            window.__kasetExtractVideo = function() {
                if (window.__kasetYTExtraction && window.__kasetYTExtraction.active) {
                    stopExtraction();
                }
                ensureStyle();
                const state = extractionState();
                state.active = true;
                window.__kasetYTVideoActive = true;
                installObserver();
                scheduleEnforcement(MAX_ENFORCEMENT_FRAMES);
                return { success: true };
            };

            window.__kasetExtractVideo();
        })();
        """
    }
}

// MARK: - Playback Controls

extension YouTubeWatchWebView {
    /// Toggles play/pause on the watch page's video element.
    func playPause() {
        self.webView?.evaluateJavaScript(
            """
            (function() {
                const video = document.querySelector('#movie_player video') || document.querySelector('video');
                if (!video) { return 'no-video'; }
                if (video.paused) {
                    window.__kasetNativePausePending = false;
                    video.play();
                    return 'playing';
                } else {
                    window.__kasetNativePausePending = true;
                    video.pause();
                    return 'paused';
                }
            })();
            """,
            completionHandler: nil
        )
    }

    /// Resumes playback.
    func play() {
        self.webView?.evaluateJavaScript(
            """
            (function() {
                window.__kasetNativePausePending = false;
                const video = document.querySelector('#movie_player video') || document.querySelector('video');
                if (video && video.paused) { video.play(); }
            })();
            """,
            completionHandler: nil
        )
    }

    /// Pauses playback.
    func pause() {
        self.webView?.evaluateJavaScript(
            """
            (function() {
                window.__kasetNativePausePending = true;
                const video = document.querySelector('#movie_player video') || document.querySelector('video');
                if (video && !video.paused) { video.pause(); }
            })();
            """,
            completionHandler: nil
        )
    }

    /// Seeks to a position in seconds.
    func seek(to time: Double) {
        guard time.isFinite, time >= 0 else { return }
        self.webView?.evaluateJavaScript(
            """
            (function() {
                const video = document.querySelector('#movie_player video') || document.querySelector('video');
                if (video) { video.currentTime = \(time); }
            })();
            """,
            completionHandler: nil
        )
    }

    /// Evaluates JavaScript that returns a string (nil on error).
    private func evaluateForString(_ script: String) async -> String? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    /// Encodes a Swift string as a safe JavaScript string literal (including the
    /// surrounding quotes) so arbitrary contents can't break out of the literal
    /// when interpolated into an `evaluateJavaScript` payload.
    static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return json
    }

    /// Fetches the caption tracks the player offers.
    func availableCaptionTracks() async -> [YouTubeCaptionTrack] {
        guard let json = await self.evaluateForString(Self.availableCaptionTracksScript),
              let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else {
            return []
        }
        return entries.compactMap { entry in
            guard let code = entry["code"], !code.isEmpty,
                  let name = entry["name"], !name.isEmpty
            else {
                return nil
            }
            return YouTubeCaptionTrack(languageCode: code, displayName: name)
        }
    }

    /// Activates a caption track by preferred caption identifier (`vssId` when available, else language code), or turns captions off (nil).
    func setCaptionTrack(languageCode: String?) {
        self.webView?.evaluateJavaScript(Self.setCaptionTrackScript(languageCode: languageCode), completionHandler: nil)
    }

    static var availableCaptionTracksScript: String {
        """
        (function() {
            try {
                const player = document.getElementById('movie_player');
                if (!player) { return '[]'; }
                if (typeof player.loadModule === 'function') {
                    try { player.loadModule('captions'); } catch (e) {}
                }

                function textFrom(value) {
                    if (!value) { return ''; }
                    if (typeof value === 'string') { return value; }
                    if (value.simpleText) { return value.simpleText; }
                    if (Array.isArray(value.runs)) {
                        return value.runs.map(function(run) { return run.text || ''; }).join('');
                    }
                    return '';
                }

                function playerResponse() {
                    if (typeof player.getPlayerResponse === 'function') {
                        try {
                            const response = player.getPlayerResponse();
                            if (response) { return response; }
                        } catch (e) {}
                    }
                    return window.ytInitialPlayerResponse || null;
                }

                function responseCaptionTracks() {
                    const response = playerResponse();
                    const renderer = response && response.captions && response.captions.playerCaptionsTracklistRenderer;
                    return (renderer && renderer.captionTracks) || [];
                }

                let tracks = [];
                if (typeof player.getOption === 'function') {
                    try { tracks = player.getOption('captions', 'tracklist') || []; } catch (e) { tracks = []; }
                }
                if (!tracks.length) { tracks = responseCaptionTracks(); }

                const seen = new Set();
                return JSON.stringify(tracks.map(function(track) {
                    const code = track.vssId || track.languageCode || '';
                    const name = textFrom(track.displayName) || textFrom(track.name) || track.languageName || code;
                    return { code: code, name: name };
                }).filter(function(track) {
                    if (!track.code || !track.name || seen.has(track.code)) { return false; }
                    seen.add(track.code);
                    return true;
                }));
            } catch (e) { return '[]'; }
        })();
        """
    }

    static func setCaptionTrackScript(languageCode: String?) -> String {
        if let languageCode {
            let codeLiteral = Self.jsStringLiteral(languageCode)
            return """
            (function() {
                const player = document.getElementById('movie_player');
                if (!player) { return; }
                const requested = \(codeLiteral);

                function playerResponse() {
                    if (typeof player.getPlayerResponse === 'function') {
                        try {
                            const response = player.getPlayerResponse();
                            if (response) { return response; }
                        } catch (e) {}
                    }
                    return window.ytInitialPlayerResponse || null;
                }

                function responseCaptionTracks() {
                    const response = playerResponse();
                    const renderer = response && response.captions && response.captions.playerCaptionsTracklistRenderer;
                    return (renderer && renderer.captionTracks) || [];
                }

                let tracks = [];
                if (typeof player.getOption === 'function') {
                    try { tracks = player.getOption('captions', 'tracklist') || []; } catch (e) { tracks = []; }
                }
                if (!tracks.length) { tracks = responseCaptionTracks(); }
                const selected = tracks.find(function(track) {
                    return track && (track.vssId === requested || track.languageCode === requested);
                }) || (requested.indexOf('.') !== -1 ? { vssId: requested } : { languageCode: requested });

                try { player.loadModule('captions'); } catch (e) {}
                try { player.setOption('captions', 'track', selected); } catch (e) {
                    try { player.setOption('captions', 'track', { languageCode: requested }); } catch (e2) {}
                }
            })();
            """
        }
        return """
        (function() {
            const player = document.getElementById('movie_player');
            if (!player) { return; }
            try { player.setOption('captions', 'track', {}); } catch (e) {}
            try { player.unloadModule('captions'); } catch (e) {}
        })();
        """
    }

    /// The storyboard spec string for the current video, read from the player
    /// response. Drives the ambient backdrop's fine-grained live color.
    ///
    /// Only returns a spec when the player response's own `videoId` matches
    /// `expectedVideoId` — `window.ytInitialPlayerResponse` is the page-load
    /// global and can still describe the *previous* video after a YouTube SPA
    /// auto-advance, which would tint the new page with the old video's colors.
    func storyboardSpec(expectedVideoId: String?) async -> String? {
        // JSON-encode the id into a safe JS string literal rather than raw
        // string interpolation, so a quote/backslash/newline can't break out of
        // the literal at the WKWebView trust boundary.
        let expectedLiteral = Self.jsStringLiteral(expectedVideoId ?? "")
        let script = """
        (function() {
            try {
                var expected = \(expectedLiteral);
                var response = null;
                var player = document.getElementById('movie_player');
                if (player && typeof player.getPlayerResponse === 'function') {
                    response = player.getPlayerResponse();
                }
                if (!response || !response.storyboards) {
                    response = window.ytInitialPlayerResponse;
                }
                if (!response || !response.storyboards) { return ''; }
                // Reject a response that describes a different video than the
                // one we're asking about (stale global after SPA navigation).
                var details = response.videoDetails;
                var responseId = details && details.videoId;
                if (expected && responseId && responseId !== expected) { return ''; }
                var sb = response.storyboards;
                var renderer = sb.playerStoryboardSpecRenderer
                    || sb.playerLiveStoryboardSpecRenderer;
                return (renderer && renderer.spec) || '';
            } catch (e) { return ''; }
        })();
        """
        guard let spec = await self.evaluateForString(script), !spec.isEmpty else {
            return nil
        }
        return spec
    }

    /// The language code of the player's active caption track (nil = off).
    func currentCaptionLanguageCode() async -> String? {
        let script = """
        (function() {
            try {
                const player = document.getElementById('movie_player');
                if (!player || typeof player.getOption !== 'function') { return ''; }
                const track = player.getOption('captions', 'track');
                return (track && (track.vssId || track.languageCode)) || '';
            } catch (e) { return ''; }
        })();
        """
        let code = await self.evaluateForString(script)
        return (code?.isEmpty == false) ? code : nil
    }

    /// Fetches the quality levels the player offers.
    func availableQualityLevels() async -> [String] {
        let script = """
        (function() {
            try {
                const player = document.getElementById('movie_player');
                if (!player || typeof player.getAvailableQualityLevels !== 'function') { return '[]'; }
                return JSON.stringify(player.getAvailableQualityLevels() || []);
            } catch (e) { return '[]'; }
        })();
        """
        guard let json = await self.evaluateForString(script),
              let data = json.data(using: .utf8),
              let levels = try? JSONSerialization.jsonObject(with: data) as? [String]
        else {
            return []
        }
        return levels
    }

    /// The player's current quality level.
    func currentQualityLevel() async -> String? {
        let script = """
        (function() {
            try {
                const player = document.getElementById('movie_player');
                if (!player || typeof player.getPlaybackQuality !== 'function') { return ''; }
                return player.getPlaybackQuality() || '';
            } catch (e) { return ''; }
        })();
        """
        let level = await self.evaluateForString(script)
        return (level?.isEmpty == false) ? level : nil
    }

    /// Requests a playback quality level.
    func setQualityLevel(_ level: String) {
        let script = """
        (function() {
            const player = document.getElementById('movie_player');
            if (!player) { return; }
            try { player.setPlaybackQualityRange('\(level)', '\(level)'); } catch (e) {
                try { player.setPlaybackQuality('\(level)'); } catch (e2) {}
            }
        })();
        """
        self.webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Shows the system AirPlay picker for the watch page's video element.
    func showAirPlayPicker() {
        self.webView?.evaluateJavaScript(
            """
            (function() {
                const video = document.querySelector('#movie_player video') || document.querySelector('video');
                if (video && typeof video.webkitShowPlaybackTargetPicker === 'function') {
                    video.webkitShowPlaybackTargetPicker();
                }
            })();
            """,
            completionHandler: nil
        )
    }

    /// Sets the playback volume (0...1) on the video element and player API.
    func setVolume(_ volume: Double) {
        let clamped = volume.isFinite ? min(max(volume, 0), 1) : 1.0
        self.webView?.evaluateJavaScript(
            """
            (function() {
                window.__kasetTargetVolume = \(clamped);
                window.__kasetIsSettingVolume = true;
                const video = document.querySelector('#movie_player video') || document.querySelector('video');
                if (video) {
                    video.volume = \(clamped);
                    if (\(clamped) > 0 && video.muted) { video.muted = false; }
                }
                const player = document.getElementById('movie_player');
                if (player && typeof player.setVolume === 'function') {
                    player.setVolume(\(Int((clamped * 100).rounded())));
                }
                if (player && \(clamped) > 0 && typeof player.unMute === 'function') {
                    try { player.unMute(); } catch (e) {}
                }
                setTimeout(function() { window.__kasetIsSettingVolume = false; }, 100);
            })();
            """,
            completionHandler: nil
        )
    }
}
