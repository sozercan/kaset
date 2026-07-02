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
                    applyPendingSeek(video);
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
            // not be seekable immediately, so this is called from both attach()
            // and the 1s sendUpdate tick and retries until metadata is ready.
            // Scoped to this document: window.__kasetPendingSeek is re-injected
            // per page load, so it cannot leak into a later video.
            function applyPendingSeek(video) {
                const target = window.__kasetPendingSeek;
                if (typeof target !== 'number') { return; }
                // Don't seek (or consume the pending value) on a preroll-ad video
                // element — wait for the real content player, or the content would
                // start from 0 after the ad.
                if (isAdShowing()) { return; }
                if (video.readyState < 1) { return; }
                try {
                    video.currentTime = target;
                    // Re-assert once if the player clobbers currentTime back near 0.
                    setTimeout(function() {
                        if (typeof window.__kasetPendingSeek === 'number' &&
                            Math.abs(video.currentTime - target) > 1.5) {
                            try { video.currentTime = target; } catch (e) {}
                        }
                        window.__kasetPendingSeek = null;
                    }, 400);
                } catch (e) {}
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
                enforceVolume(video);
                applyPendingSeek(video);
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
