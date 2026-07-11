// MARK: - SingletonPlayerWebView Observer Script Extension

extension SingletonPlayerWebView {
    /// Pure JS function used by the observer script's `canplay` handler.
    /// Exposed as a named function so unit tests can exercise the branching
    /// inside a `JSContext` without standing up a real `WKWebView`.
    nonisolated static var autoplayRecoveryFunctionJS: String {
        """
        function __kasetAttemptAutoplayRecovery(video, playBtn) {
            if (!window.__kasetAutoplayPending) return 'noop';
            if (!video.paused) { window.__kasetAutoplayPending = false; return 'noop'; }
            window.__kasetAutoplayPending = false;
            if (playBtn) { playBtn.click(); return 'clicked'; }
            try { video.play(); return 'played'; } catch (e) { return 'error'; }
        }
        """
    }

    nonisolated static var mediaIdentityBindingDecisionFunctionJS: String {
        """
        function __kasetShouldBindMediaIdentity(
            sourceChanged,
            mediaTimeReset,
            identityCorrectionEvidence
        ) {
            return sourceChanged
                || mediaTimeReset
                || identityCorrectionEvidence;
        }
        """
    }

    /// Observer script for playback state.
    nonisolated static var observerScript: String {
        """
        (function() {
            'use strict';
            const bridge = window.webkit.messageHandlers.singletonPlayer;
            const observerEpoch = (window.performance && performance.timeOrigin)
                ? performance.timeOrigin : Date.now();
            const documentID = Number(window.__kasetDocumentID || 0);
            \(autoplayRecoveryFunctionJS)
            \(mediaIdentityBindingDecisionFunctionJS)
            let lastTitle = '';
            let lastArtist = '';
            let lastVideoId = '';
            let mediaVideoId = '';
            let mediaSource = '';
            let mediaGeneration = 0;
            let lastMediaCurrentTime = 0;
            let mediaIdentityUncertain = false;
            let mediaIdentityTransitionFromVideoId = '';
            let mediaIdentityIsInitialBinding = false;
            let isPollingActive = false;
            let pollIntervalId = null;
            let lastUpdateTime = 0;
            let trailingUpdateTimeoutId = null;
            const UPDATE_THROTTLE_MS = 500; // Throttle updates to max 2/sec
            const POLL_INTERVAL_MS = 1000; // Poll at 1Hz during playback (reduced from 250ms)

            // Volume enforcement: track target volume set by Swift
            // Don't set a default - only enforce when explicitly set by Swift
            // window.__kasetTargetVolume is set by volume init script at document start
            let isEnforcingVolume = false; // Prevent feedback loops

            // Reusable 3-way volume enforcement (video element + YouTube APIs)
            function enforceVolumeNow() {
                const targetVol = window.__kasetTargetVolume;
                const v = document.querySelector('video');
                if (!v || typeof targetVol !== 'number' || Math.abs(v.volume - targetVol) <= 0.01) return;
                isEnforcingVolume = true;
                v.volume = targetVol;
                const ytVol = Math.round(targetVol * 100);
                const p = document.querySelector('ytmusic-player');
                if (p && p.playerApi) p.playerApi.setVolume(ytVol);
                const mp = document.getElementById('movie_player');
                if (mp && mp.setVolume) mp.setVolume(ytVol);
                setTimeout(() => { isEnforcingVolume = false; }, 50);
            }

            function waitForPlayerBar() {
                const playerBar = document.querySelector('ytmusic-player-bar');
                if (playerBar) {
                    setupObserver(playerBar);
                    setupVideoListeners();
                    return;
                }
                setTimeout(waitForPlayerBar, 500);
            }

            function setupVideoListeners() {
                // Watch for video element to attach play/pause listeners
                function attachVideoListeners() {
                    const video = document.querySelector('video');
                    if (!video) {
                        setTimeout(attachVideoListeners, 500);
                        return;
                    }
                    if (video.__kasetListenersAttached) return;
                    video.__kasetListenersAttached = true;

                    // If metadata is already loaded, establish the current media
                    // immediately. Otherwise the first `loadedmetadata` event owns
                    // the initial bind and must not look like a second transition.
                    if (video.readyState >= 1) {
                        bindMediaIdentity(video, true, false);
                    }

                    video.addEventListener('play', startPolling);
                    video.addEventListener('playing', startPolling);
                    // Enforce volume on playing event to catch all track changes
                    // (auto-advance, SPA navigation, button clicks)
                    video.addEventListener('playing', () => {
                        confirmMediaIdentityOnPlaying(video);
                        bindMediaIdentity(video, false, false);
                        if (window.__kasetBlockAutoplay) {
                            try { video.pause(); } catch (_) {}
                            return;
                        }
                        window.__kasetAutoplayPending = false;
                        enforceVolumeNow();
                        restartLyricsPoll(false);
                    });
                    video.addEventListener('pause', stopPolling);
                    video.addEventListener('ended', () => {
                        sendTrackEnded();
                        stopPolling();
                    });
                    video.addEventListener('waiting', () => sendUpdate(true)); // Buffer state
                    video.addEventListener('seeked', () => {
                        sendUpdate(true); // Seek completed
                        restartLyricsPoll(true);
                    });

                    // AirPlay state tracking
                    video.addEventListener('webkitcurrentplaybacktargetiswirelesschanged', () => {
                        const isWireless = video.webkitCurrentPlaybackTargetIsWireless;
                        const wasConnected = window.__kasetAirPlayConnected;
                        window.__kasetAirPlayConnected = isWireless;

                        bridge.postMessage({
                            type: 'AIRPLAY_STATUS',
                            observerEpoch: observerEpoch,
                            documentID: documentID,
                            isConnected: isWireless,
                            wasConnected: wasConnected,
                            wasRequested: window.__kasetAirPlayRequested || false
                        });
                    });

                    // Check initial AirPlay state
                    const initialWireless = video.webkitCurrentPlaybackTargetIsWireless;
                    if (initialWireless) {
                        window.__kasetAirPlayConnected = true;
                        bridge.postMessage({
                            type: 'AIRPLAY_STATUS',
                            observerEpoch: observerEpoch,
                            documentID: documentID,
                            isConnected: true,
                            wasConnected: false,
                            wasRequested: window.__kasetAirPlayRequested || false
                        });
                    } else if (window.__kasetAirPlayRequested && window.__kasetAirPlayConnected) {
                        window.__kasetAirPlayConnected = false;
                        bridge.postMessage({
                            type: 'AIRPLAY_STATUS',
                            observerEpoch: observerEpoch,
                            documentID: documentID,
                            isConnected: false,
                            wasConnected: true,
                            wasRequested: true
                        });
                    }

                    // Volume enforcement: immediately revert external volume changes
                    // No debounce — the isEnforcingVolume flag prevents feedback loops.
                    // A debounce allowed YouTube's rapid-fire init events to keep pushing
                    // enforcement later, leaving wrong volume audible for 1-2 seconds.
                    video.addEventListener('volumechange', () => {
                        if (isEnforcingVolume) return;
                        if (window.__kasetIsSettingVolume) return;
                        enforceVolumeNow();
                    });

                    // Enforce volume at media lifecycle events where YouTube resets volume.
                    // YouTube's player often restores its stored volume at these points.
                    video.addEventListener('loadedmetadata', () => {
                        bindMediaIdentity(video, true, true);
                        enforceVolumeNow();
                        sendUpdate(true);
                    });
                    video.addEventListener('loadeddata', () => enforceVolumeNow());
                    function recoverAutoplayIfNeeded() {
                        bindMediaIdentity(video, false, false);
                        enforceVolumeNow();
                        if (window.__kasetBlockAutoplay) {
                            try { video.pause(); } catch (_) {}
                            return;
                        }
                        // Autoplay recovery: YTM sometimes leaves the video paused
                        // after navigation even with the WebKit autoplay allowance.
                        const btn = document.querySelector('.play-pause-button.ytmusic-player-bar');
                        __kasetAttemptAutoplayRecovery(video, btn);
                    }

                    video.addEventListener('canplay', recoverAutoplayIfNeeded);

                    // Apply target volume immediately when video element is first detected
                    enforceVolumeNow();

                    // If the media was already ready before this listener attached,
                    // there may not be another `canplay` event to drive recovery.
                    if (video.readyState >= 3) {
                        recoverAutoplayIfNeeded();
                    }

                    // Startup enforcement burst: YouTube may reset volume up to ~2s after
                    // playback starts (via internal player init, quality switching, etc.).
                    // Enforce every 200ms for the first 3 seconds to catch delayed resets.
                    let burstCount = 0;
                    const burstInterval = setInterval(() => {
                        enforceVolumeNow();
                        if (++burstCount >= 15) clearInterval(burstInterval);
                    }, 200);

                    // Start polling if already playing
                    if (!video.paused) {
                        startPolling();
                    }
                }
                attachVideoListeners();

                // Also watch for video element replacement (YouTube may recreate it)
                const videoObserver = new MutationObserver(() => {
                    const video = document.querySelector('video');
                    if (video && !video.__kasetListenersAttached) {
                        attachVideoListeners();
                    }
                });
                videoObserver.observe(document.body, { childList: true, subtree: true });
            }

            function currentPlayerData() {
                const player = document.querySelector('ytmusic-player');
                if (player && player.playerApi && typeof player.playerApi.getVideoData === 'function') {
                    const data = player.playerApi.getVideoData();
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

            function bindMediaIdentity(video, force, transitionEvidence) {
                const videoId = currentVideoId();
                const source = video.currentSrc || video.src || '';
                const currentTime = Number.isFinite(video.currentTime) ? video.currentTime : 0;
                if (!force && source === mediaSource) return;
                const previousMediaVideoId = mediaVideoId;
                const sourceChanged = source !== mediaSource;
                mediaGeneration += 1;
                mediaVideoId = videoId;
                mediaSource = source;
                lastMediaCurrentTime = currentTime;
                mediaIdentityIsInitialBinding = !previousMediaVideoId;
                mediaIdentityTransitionFromVideoId = previousMediaVideoId || videoId;
                mediaIdentityUncertain = !videoId
                    || mediaIdentityIsInitialBinding
                    || ((sourceChanged || transitionEvidence)
                        && videoId === previousMediaVideoId);
                if (!mediaIdentityUncertain) {
                    mediaIdentityTransitionFromVideoId = '';
                    mediaIdentityIsInitialBinding = false;
                }
            }

            function confirmMediaIdentityOnPlaying(video) {
                if (!mediaIdentityUncertain) return;
                const videoId = currentVideoId();
                if (!videoId) return;
                if (mediaIdentityIsInitialBinding || videoId !== mediaIdentityTransitionFromVideoId) {
                    bindMediaIdentity(video, true, false);
                }
            }

            window.__kasetAdvanceMediaGeneration = function() {
                const video = document.querySelector('video');
                if (!video) return false;
                mediaGeneration += 1;
                mediaVideoId = currentVideoId();
                mediaSource = video.currentSrc || video.src || '';
                mediaIdentityUncertain = !mediaVideoId;
                mediaIdentityTransitionFromVideoId = '';
                mediaIdentityIsInitialBinding = false;
                sendUpdate(true);
                return true;
            };

            let lyricsPollTimeoutId = null;
            let lyricsPollActive = false;
            let lyricsLineRanges = [];
            let lastLyricsBucket = null;
            const LYRICS_MAX_POLL_INTERVAL_MS = 250;
            const LYRICS_MIN_POLL_INTERVAL_MS = 50;

            function currentLyricsBucket(timeMs) {
                if (!Array.isArray(lyricsLineRanges) || lyricsLineRanges.length === 0) {
                    return { lineIndex: -1, bucket: -1, nextBoundaryMs: null };
                }
                for (let index = 0; index < lyricsLineRanges.length; index += 1) {
                    const range = lyricsLineRanges[index];
                    if (timeMs >= range.startMs && timeMs < range.endMs) {
                        return { lineIndex: index, bucket: index, nextBoundaryMs: range.endMs };
                    }
                    if (timeMs < range.startMs) {
                        return { lineIndex: -1, bucket: -(index + 1), nextBoundaryMs: range.startMs };
                    }
                }
                return { lineIndex: -1, bucket: -(lyricsLineRanges.length + 1), nextBoundaryMs: null };
            }

            function sendLyricsLineUpdate(force) {
                const v = document.querySelector('video');
                if (!v) return null;
                const timeMs = Math.floor((v.currentTime || 0) * 1000);
                const bucket = currentLyricsBucket(timeMs);
                if (!force && bucket.bucket === lastLyricsBucket) return bucket;
                lastLyricsBucket = bucket.bucket;
                bridge.postMessage({
                    type: 'LYRICS_LINE',
                    observerEpoch: observerEpoch,
                            documentID: documentID,
                    lineIndex: bucket.lineIndex,
                    bucket: bucket.bucket,
                    timeMs: timeMs
                });
                return bucket;
            }

            function scheduleNextLyricsPoll(bucket) {
                if (!lyricsPollActive || lyricsPollTimeoutId) return;
                const v = document.querySelector('video');
                const timeMs = v ? Math.floor((v.currentTime || 0) * 1000) : 0;
                const nextBoundaryMs = bucket && typeof bucket.nextBoundaryMs === 'number'
                    ? bucket.nextBoundaryMs
                    : null;
                const boundaryDelay = nextBoundaryMs === null
                    ? null
                    : nextBoundaryMs - timeMs + 1;
                const minBoundaryDelay = v && (v.paused || v.playbackRate === 0)
                    ? LYRICS_MIN_POLL_INTERVAL_MS
                    : 0;
                const delay = boundaryDelay === null
                    ? LYRICS_MAX_POLL_INTERVAL_MS
                    : Math.max(minBoundaryDelay, Math.min(LYRICS_MAX_POLL_INTERVAL_MS, boundaryDelay));
                lyricsPollTimeoutId = setTimeout(() => {
                    lyricsPollTimeoutId = null;
                    const nextBucket = sendLyricsLineUpdate(false);
                    scheduleNextLyricsPoll(nextBucket);
                }, delay);
            }


            function restartLyricsPoll(force) {
                if (!lyricsPollActive) return;
                if (lyricsPollTimeoutId) {
                    clearTimeout(lyricsPollTimeoutId);
                    lyricsPollTimeoutId = null;
                }
                const bucket = sendLyricsLineUpdate(force);
                scheduleNextLyricsPoll(bucket);
            }

            window.startLyricsPoll = function(lineRanges) {
                lyricsPollActive = true;
                if (lyricsPollTimeoutId) {
                    clearTimeout(lyricsPollTimeoutId);
                    lyricsPollTimeoutId = null;
                }
                const nextRanges = Array.isArray(lineRanges) ? lineRanges : [];
                lyricsLineRanges.length = 0;
                nextRanges.forEach(range => {
                    if (!range || typeof range.startMs !== 'number' || typeof range.endMs !== 'number') return;
                    if (!isFinite(range.startMs) || !isFinite(range.endMs)) return;
                    lyricsLineRanges.push({ startMs: range.startMs, endMs: range.endMs });
                });
                lastLyricsBucket = null;
                const bucket = sendLyricsLineUpdate(true);
                scheduleNextLyricsPoll(bucket);
            };

            window.stopLyricsPoll = function() {
                lyricsPollActive = false;
                if (lyricsPollTimeoutId) {
                    clearTimeout(lyricsPollTimeoutId);
                    lyricsPollTimeoutId = null;
                }
                lastLyricsBucket = null;
            };

            function startPolling() {
                if (isPollingActive) return;
                isPollingActive = true;

                // Don't apply volume here - let volume enforcement handle it
                // Applying volume on every startPolling causes volume jumps

                sendUpdate(true); // Immediate update
                // Poll at 1Hz during playback for progress updates (reduced CPU usage)
                pollIntervalId = setInterval(sendUpdate, POLL_INTERVAL_MS);
            }

            function stopPolling() {
                isPollingActive = false;
                if (pollIntervalId) {
                    clearInterval(pollIntervalId);
                    pollIntervalId = null;
                }
                sendUpdate(true); // Final state update
            }

            function setupObserver(playerBar) {
                // Debounced mutation observer - only triggers on significant changes
                let mutationTimeout = null;
                const observer = new MutationObserver(() => {
                    if (mutationTimeout) return;
                    mutationTimeout = setTimeout(() => {
                        mutationTimeout = null;
                        sendUpdate();
                    }, 100);
                });
                observer.observe(playerBar, {
                    attributes: true, characterData: true,
                    childList: true, subtree: true,
                    attributeFilter: ['title', 'aria-label', 'like-status', 'value', 'aria-valuemax']
                });
                sendUpdate(true);
            }

            function sendTrackEnded() {
                const endedVideoId = mediaIdentityUncertain
                    ? '' : (mediaVideoId || lastVideoId || currentVideoId());
                bridge.postMessage({
                    type: 'TRACK_ENDED',
                    observerEpoch: observerEpoch,
                    documentID: documentID,
                    videoId: endedVideoId,
                    mediaGeneration: mediaGeneration,
                    mediaIdentityUncertain: mediaIdentityUncertain
                });
            }

            function sendUpdate(force = false) {
                // Throttle non-forced updates across polling and mutation paths.
                // If an update is skipped, keep one trailing send so paused/setup
                // mutations that are not followed by a polling tick still reach Swift.
                const now = Date.now();
                if (!force) {
                    const elapsed = now - lastUpdateTime;
                    if (elapsed < UPDATE_THROTTLE_MS) {
                        if (!trailingUpdateTimeoutId) {
                            trailingUpdateTimeoutId = setTimeout(() => {
                                trailingUpdateTimeoutId = null;
                                sendUpdate(true);
                            }, UPDATE_THROTTLE_MS - elapsed);
                        }
                        return;
                    }
                } else if (trailingUpdateTimeoutId) {
                    clearTimeout(trailingUpdateTimeoutId);
                    trailingUpdateTimeoutId = null;
                }
                lastUpdateTime = now;

                try {
                    // Use video element's paused property for language-agnostic detection
                    // Previously checked button title/aria-label which fails for non-English locales
                    const video = document.querySelector('video');
                    const isPlaying = video ? !video.paused : false;

                    const progressBar = document.querySelector('#progress-bar');

                    // Extract track metadata
                    const titleEl = document.querySelector('.ytmusic-player-bar.title');
                    const artistEl = document.querySelector('.ytmusic-player-bar.byline');
                    const thumbEl = document.querySelector('.ytmusic-player-bar .thumbnail img, ytmusic-player-bar .image');

                    const playerData = currentPlayerData();
                    const playerTitle = playerData && typeof playerData.title === 'string'
                        ? playerData.title.trim()
                        : '';
                    const playerArtist = playerData && typeof playerData.author === 'string'
                        ? playerData.author.trim()
                        : '';

                    let title = titleEl ? titleEl.textContent.trim() : '';
                    let artist = artistEl ? artistEl.textContent.trim() : '';
                    const videoId = currentVideoId();
                    if (video && videoId && videoId !== mediaVideoId) {
                        const mediaTime = Number.isFinite(video.currentTime) ? video.currentTime : 0;
                        const source = video.currentSrc || video.src || '';
                        const mediaTimeReset = mediaTime + 2 < lastMediaCurrentTime;
                        const initialEmptyIdentityResolved = mediaIdentityUncertain
                            && mediaIdentityIsInitialBinding
                            && !mediaVideoId
                            && !!videoId;
                        const transitionIdentityResolved = mediaIdentityUncertain
                            && !mediaIdentityIsInitialBinding
                            && !!mediaIdentityTransitionFromVideoId
                            && videoId !== mediaIdentityTransitionFromVideoId;
                        const identityCorrectionEvidence = initialEmptyIdentityResolved
                            || transitionIdentityResolved;
                        if (__kasetShouldBindMediaIdentity(
                            source !== mediaSource,
                            mediaTimeReset,
                            identityCorrectionEvidence
                        )) {
                            bindMediaIdentity(
                                video,
                                true,
                                source !== mediaSource || mediaTimeReset
                            );
                        }
                    }
                    if (video && videoId && videoId === mediaVideoId) {
                        lastMediaCurrentTime = Number.isFinite(video.currentTime) ? video.currentTime : 0;
                    }
                    let thumbnailUrl = '';

                    // Prefer player API metadata when the DOM appears to be lagging behind the actual video.
                    if (playerTitle && title && playerTitle !== title) {
                        title = playerTitle;
                        if (playerArtist) artist = playerArtist;
                    } else {
                        if (!title && playerTitle) title = playerTitle;
                        if (!artist && playerArtist) artist = playerArtist;
                    }

                    // Get the thumbnail URL from the image element
                    if (thumbEl) {
                        thumbnailUrl = thumbEl.src || thumbEl.getAttribute('src') || '';
                    }

                    // Extract like status from the like button renderer
                    let likeStatus = 'INDIFFERENT';
                    const likeRenderer = document.querySelector('ytmusic-like-button-renderer');
                    if (likeRenderer) {
                        const status = likeRenderer.getAttribute('like-status');
                        if (status === 'LIKE') likeStatus = 'LIKE';
                        else if (status === 'DISLIKE') likeStatus = 'DISLIKE';
                    }

                    // Check if track changed
                    const metadataChanged = title !== '' && (title !== lastTitle || artist !== lastArtist);
                    const videoIdChanged = videoId !== '' && videoId !== lastVideoId;
                    const trackChanged = metadataChanged || videoIdChanged;
                    if (trackChanged) {
                        if (title !== '') {
                            lastTitle = title;
                            lastArtist = artist;
                        }
                        if (videoId !== '') {
                            lastVideoId = videoId;
                        }
                    }

                    // Detect if actual video content is available
                    // This is a quick DOM check for initial detection.
                    // The API-based musicVideoType detection in fetchSongMetadata
                    // will provide the authoritative value once metadata is loaded.
                    let hasVideo = false;

                    // Quick check: Look for Song/Video toggle buttons
                    const toggleButtons = document.querySelectorAll('tp-yt-paper-button, button, [role="button"]');
                    for (const btn of toggleButtons) {
                        const text = (btn.textContent || btn.innerText || '').trim().toLowerCase();
                        if (text === 'video' || text === 'song') {
                            hasVideo = true;
                            break;
                        }
                    }

                    bridge.postMessage({
                        type: 'STATE_UPDATE',
                        isPlaying: isPlaying,
                        progress: progressBar ? parseInt(progressBar.getAttribute('value') || '0') : 0,
                        duration: progressBar ? parseInt(progressBar.getAttribute('aria-valuemax') || '0') : 0,
                        title: title,
                        artist: artist,
                        videoId: videoId,
                        mediaVideoId: mediaVideoId,
                        mediaGeneration: mediaGeneration,
                        observerEpoch: observerEpoch,
                            documentID: documentID,
                        thumbnailUrl: thumbnailUrl,
                        trackChanged: trackChanged,
                        likeStatus: likeStatus,
                        hasVideo: hasVideo
                    });
                } catch (e) {}
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', waitForPlayerBar);
            } else {
                waitForPlayerBar();
            }
        })();
        """
    }
}
