// MARK: - SingletonPlayerWebView Observer Script Extension

extension SingletonPlayerWebView {
    /// Observer script for playback state.
    static var observerScript: String {
        """
        (function() {
            'use strict';
            const bridge = window.webkit.messageHandlers.singletonPlayer;
            let lastTitle = '';
            let lastArtist = '';
            let isPollingActive = false;
            let pollIntervalId = null;
            let lastUpdateTime = 0;
            const UPDATE_THROTTLE_MS = 500; // Throttle updates to max 2/sec
            const POLL_INTERVAL_MS = 1000; // Poll at 1Hz during playback (reduced from 250ms)

            // Volume enforcement: track target volume set by Swift
            // Don't set a default - only enforce when explicitly set by Swift
            // window.__kasetTargetVolume is set by volume init script at document start
            let volumeEnforcementTimeout = null; // Debounce volume enforcement
            let isEnforcingVolume = false; // Prevent feedback loops

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

                    video.addEventListener('play', startPolling);
                    video.addEventListener('playing', startPolling);
                    video.addEventListener('pause', stopPolling);
                    video.addEventListener('ended', stopPolling);
                    video.addEventListener('waiting', () => sendUpdate()); // Buffer state
                    video.addEventListener('seeked', () => sendUpdate()); // Seek completed

                    // Volume enforcement: listen for external volume changes with debounce
                    // This catches YouTube's attempts to change volume and reverts to our target
                    video.addEventListener('volumechange', () => {
                        // Skip if we're currently enforcing (prevents feedback loop)
                        if (isEnforcingVolume) return;

                        // Debounce to prevent rapid-fire enforcement
                        if (volumeEnforcementTimeout) {
                            clearTimeout(volumeEnforcementTimeout);
                        }
                        volumeEnforcementTimeout = setTimeout(() => {
                            // Also skip if Swift is actively setting volume
                            if (window.__kasetIsSettingVolume) {
                                volumeEnforcementTimeout = null;
                                return;
                            }
                            const targetVol = window.__kasetTargetVolume;
                            const currentVideo = document.querySelector('video');
                            // Only enforce if target was explicitly set and differs significantly
                            if (currentVideo && typeof targetVol === 'number' && Math.abs(currentVideo.volume - targetVol) > 0.01) {
                                isEnforcingVolume = true;
                                currentVideo.volume = targetVol;

                                // Also enforce via YouTube's internal APIs
                                const ytVolume = Math.round(targetVol * 100);
                                const player = document.querySelector('ytmusic-player');
                                if (player && player.playerApi) {
                                    player.playerApi.setVolume(ytVolume);
                                }
                                const moviePlayer = document.getElementById('movie_player');
                                if (moviePlayer && moviePlayer.setVolume) {
                                    moviePlayer.setVolume(ytVolume);
                                }

                                // Clear flag after a tick to allow next external change to be caught
                                setTimeout(() => { isEnforcingVolume = false; }, 10);
                            }
                            volumeEnforcementTimeout = null;
                        }, 100);
                    });

                    // CRITICAL: Apply target volume immediately when video element is first detected
                    // This handles the case where didFinish already set __kasetTargetVolume but
                    // the video element didn't exist yet. Without this, YouTube creates video at
                    // 100% and volumechange may never fire (no change from initial state).
                    const targetVol = window.__kasetTargetVolume;
                    if (typeof targetVol === 'number') {
                        isEnforcingVolume = true;
                        video.volume = targetVol;

                        // Also set YouTube's internal player API volume
                        const player = document.querySelector('ytmusic-player');
                        if (player && player.playerApi) {
                            player.playerApi.setVolume(Math.round(targetVol * 100));
                        }
                        const moviePlayer = document.getElementById('movie_player');
                        if (moviePlayer && moviePlayer.setVolume) {
                            moviePlayer.setVolume(Math.round(targetVol * 100));
                        }

                        setTimeout(() => { isEnforcingVolume = false; }, 10);
                    }

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
                        video.__kasetListenersAttached = true;
                        attachVideoListeners();
                        // Note: attachVideoListeners now applies target volume immediately
                    }
                });
                videoObserver.observe(document.body, { childList: true, subtree: true });
            }

            function startPolling() {
                if (isPollingActive) return;
                isPollingActive = true;

                // Don't apply volume here - let volume enforcement handle it
                // Applying volume on every startPolling causes volume jumps

                sendUpdate(); // Immediate update
                // Poll at 1Hz during playback for progress updates (reduced CPU usage)
                pollIntervalId = setInterval(sendUpdate, POLL_INTERVAL_MS);
            }

            function stopPolling() {
                isPollingActive = false;
                if (pollIntervalId) {
                    clearInterval(pollIntervalId);
                    pollIntervalId = null;
                }
                sendUpdate(); // Final state update
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
                sendUpdate();
            }

            function sendUpdate() {
                // Throttle updates
                const now = Date.now();
                if (now - lastUpdateTime < UPDATE_THROTTLE_MS && isPollingActive) {
                    return;
                }
                lastUpdateTime = now;

                try {
                    const playPauseBtn = document.querySelector('.play-pause-button.ytmusic-player-bar');
                    const isPlaying = playPauseBtn ?
                        (playPauseBtn.getAttribute('title') === 'Pause' ||
                         playPauseBtn.getAttribute('aria-label') === 'Pause') : false;

                    const progressBar = document.querySelector('#progress-bar');

                    // Extract track metadata
                    const titleEl = document.querySelector('.ytmusic-player-bar.title');
                    const artistEl = document.querySelector('.ytmusic-player-bar.byline');
                    const thumbEl = document.querySelector('.ytmusic-player-bar .thumbnail img, ytmusic-player-bar .image');

                    const title = titleEl ? titleEl.textContent.trim() : '';
                    const artist = artistEl ? artistEl.textContent.trim() : '';
                    let thumbnailUrl = '';

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
                    const trackChanged = (title !== lastTitle || artist !== lastArtist) && title !== '';
                    if (trackChanged) {
                        lastTitle = title;
                        lastArtist = artist;
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
