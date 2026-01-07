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
            // Default to 1.0, will be updated when Swift calls setVolume()
            window.__kasetTargetVolume = window.__kasetTargetVolume ?? 1.0;
            let volumeEnforcementTimeout = null; // Debounce volume enforcement

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
                    video.addEventListener('volumechange', () => {
                        // Debounce to prevent rapid-fire enforcement
                        if (volumeEnforcementTimeout) {
                            clearTimeout(volumeEnforcementTimeout);
                        }
                        volumeEnforcementTimeout = setTimeout(() => {
                            const targetVol = window.__kasetTargetVolume;
                            const currentVideo = document.querySelector('video');
                            // Only enforce if we have a valid target volume set by Swift
                            if (currentVideo && targetVol !== undefined && Math.abs(currentVideo.volume - targetVol) > 0.01) {
                                currentVideo.volume = targetVol;
                            }
                            volumeEnforcementTimeout = null;
                        }, 50);
                    });

                    // Don't auto-apply volume here - let didFinish handle it with the current value
                    // This prevents applying stale volume from WebView creation time

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
                        // Apply current target volume to new video element
                        if (window.__kasetTargetVolume !== undefined) {
                            video.volume = window.__kasetTargetVolume;
                        }
                    }
                });
                videoObserver.observe(document.body, { childList: true, subtree: true });
            }

            function startPolling() {
                if (isPollingActive) return;
                isPollingActive = true;

                // Apply target volume when playback starts
                // This is the most reliable point since the video element definitely exists
                const video = document.querySelector('video');
                if (video && window.__kasetTargetVolume !== undefined) {
                    video.volume = window.__kasetTargetVolume;
                }

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
                    // YouTube Music always has a video element for audio, but only shows
                    // a "Video" tab/toggle when there's actual video content (music videos).
                    // Check for the Song/Video toggle which only appears for video tracks.
                    let hasVideo = false;

                    // Method 1: Look for Song/Video toggle buttons in the player page
                    const toggleButtons = document.querySelectorAll('tp-yt-paper-button, button, [role="button"]');
                    for (const btn of toggleButtons) {
                        const text = (btn.textContent || btn.innerText || '').trim().toLowerCase();
                        if (text === 'video' || text === 'song') {
                            // Found the toggle - this track has video
                            hasVideo = true;
                            break;
                        }
                    }

                    // Method 2: Check for video tab in ytmusic-player-page
                    if (!hasVideo) {
                        const playerPage = document.querySelector('ytmusic-player-page');
                        if (playerPage) {
                            const videoTab = playerPage.querySelector('[aria-label*="Video" i], [data-value="VIDEO"]');
                            if (videoTab) hasVideo = true;
                        }
                    }

                    // Method 3: Check if video has actual video dimensions (not just audio poster)
                    if (!hasVideo) {
                        const video = document.querySelector('video');
                        if (video && video.videoWidth > 0 && video.videoHeight > 0) {
                            // Video has dimensions - but this could still be audio with a static image
                            // Check if there's a song-image overlay covering the video (indicates audio-only)
                            const songImage = document.querySelector('.song-image, .thumbnail-image-wrapper');
                            const songImageVisible = songImage && getComputedStyle(songImage).display !== 'none';
                            hasVideo = !songImageVisible;
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
