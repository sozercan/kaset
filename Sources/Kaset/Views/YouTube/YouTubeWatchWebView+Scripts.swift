import Foundation

// MARK: - Observer & Extraction Scripts

extension YouTubeWatchWebView {
    /// Observer script for youtube.com watch pages.
    ///
    /// Posts `STATE_UPDATE` (1 Hz + media events) and `VIDEO_ENDED` to the
    /// `youtubePlayer` bridge. Also enforces the Kaset-managed volume target
    /// the same way the music observer does.
    static var observerScript: String {
        """
        (function() {
            'use strict';

            const bridge = window.webkit.messageHandlers.youtubePlayer;
            let lastVideoId = '';

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

            function sendUpdate() {
                try {
                    const video = videoEl();
                    if (!video) { return; }
                    const videoId = currentVideoId();
                    if (videoId !== '') { lastVideoId = videoId; }
                    bridge.postMessage({
                        type: 'STATE_UPDATE',
                        isPlaying: !video.paused && !video.ended,
                        progress: video.currentTime || 0,
                        duration: (video.duration && isFinite(video.duration)) ? video.duration : 0,
                        videoId: videoId,
                        title: currentTitle(),
                        isAd: isAdShowing()
                    });
                } catch (e) {
                    console.log('[KasetYT] update error: ' + e);
                }
            }

            function sendEnded() {
                bridge.postMessage({
                    type: 'VIDEO_ENDED',
                    videoId: lastVideoId || currentVideoId()
                });
            }

            function enforceVolume(video) {
                if (window.__kasetIsSettingVolume) { return; }
                const target = window.__kasetTargetVolume;
                if (typeof target === 'number' && Math.abs(video.volume - target) > 0.01) {
                    window.__kasetIsSettingVolume = true;
                    video.volume = target;
                    setTimeout(function() { window.__kasetIsSettingVolume = false; }, 50);
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

            function attach() {
                const video = videoEl();
                if (!video) { return; }
                if (video.__kasetAttached) { return; }
                video.__kasetAttached = true;

                ['play', 'playing', 'pause', 'seeked', 'loadedmetadata'].forEach(function(evt) {
                    video.addEventListener(evt, sendUpdate);
                });
                video.addEventListener('ended', sendEnded);
                video.addEventListener('volumechange', function() {
                    enforceVolume(video);
                });

                disableAutonav();
                sendUpdate();
            }

            // Re-attach periodically: YouTube swaps <video> elements across
            // SPA navigations and ad transitions.
            setInterval(attach, 2000);
            setInterval(sendUpdate, 1000);
            attach();
        })();
        """
    }

    /// Extraction script: hides all youtube.com chrome and leaves only the
    /// video surface visible, so the WebView can dock into native views.
    ///
    /// Same ancestor-chain visibility approach as the music video mode
    /// (`SingletonPlayerWebView+VideoMode`), targeting the watch-page DOM.
    /// Defines `window.__kasetExtractVideo()` and runs it; `didFinish` calls
    /// it again for cached/fast loads.
    static var extractionScript: String {
        """
        (function() {
            'use strict';

            const styleId = 'kaset-yt-video-style';

            window.__kasetExtractVideo = function() {
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

                    /* Keep YouTube's own controls/overlays hidden */
                    .ytp-chrome-bottom, .ytp-chrome-top, .ytp-gradient-bottom,
                    .ytp-gradient-top, .ytp-ce-element, .ytp-cards-teaser,
                    .ytp-pause-overlay, .ytp-endscreen-content {
                        display: none !important;
                    }

                    html, body {
                        background: #000 !important;
                        overflow: hidden !important;
                        visibility: visible !important;
                    }
                `;

                const markAncestors = function() {
                    const video = document.querySelector('#movie_player video') || document.querySelector('video');
                    if (!video) { return; }

                    document.querySelectorAll('.kaset-visible').forEach(function(el) {
                        el.classList.remove('kaset-visible');
                    });

                    let current = video;
                    while (current && current !== document.documentElement) {
                        current.classList.add('kaset-visible');
                        current = current.parentElement;
                    }
                };

                const enforce = function() {
                    markAncestors();
                    if (window.__kasetYTVideoActive) {
                        requestAnimationFrame(enforce);
                    }
                };

                window.__kasetYTVideoActive = true;
                requestAnimationFrame(enforce);
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
                if (video.paused) { video.play(); return 'playing'; } else { video.pause(); return 'paused'; }
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

    /// Sets the playback volume (0...1) on the video element and player API.
    func setVolume(_ volume: Double) {
        let clamped = volume.isFinite ? min(max(volume, 0), 1) : 1.0
        self.webView?.evaluateJavaScript(
            """
            (function() {
                window.__kasetTargetVolume = \(clamped);
                window.__kasetIsSettingVolume = true;
                const video = document.querySelector('#movie_player video') || document.querySelector('video');
                if (video) { video.volume = \(clamped); }
                const player = document.getElementById('movie_player');
                if (player && typeof player.setVolume === 'function') {
                    player.setVolume(\(Int((clamped * 100).rounded())));
                }
                setTimeout(function() { window.__kasetIsSettingVolume = false; }, 100);
            })();
            """,
            completionHandler: nil
        )
    }
}
