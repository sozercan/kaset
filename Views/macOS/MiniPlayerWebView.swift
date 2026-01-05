import SwiftUI
import WebKit

// MARK: - MiniPlayerWebView

/// A visible WebView that displays the YouTube Music player.
/// This is required because YouTube Music won't initialize the video player
/// without user interaction - autoplay is blocked in hidden WebViews.
/// Uses SingletonPlayerWebView for the actual WebView instance.
struct MiniPlayerWebView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    /// The video ID to play.
    let videoId: String

    /// Callback for player state changes.
    var onStateChange: ((PlayerState) -> Void)?

    /// Callback for metadata updates (title, artist, duration).
    var onMetadataChange: ((String, String, Double) -> Void)?

    enum PlayerState {
        case loading
        case playing
        case paused
        case ended
        case error(String)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onStateChange: self.onStateChange, onMetadataChange: self.onMetadataChange)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true

        // Get or create the singleton WebView
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        // Add additional message handler for this view's callbacks
        webView.configuration.userContentController.add(context.coordinator, name: "miniPlayer")

        // Ensure WebView is in this container
        SingletonPlayerWebView.shared.ensureInHierarchy(container: container)

        // Load the video if needed
        SingletonPlayerWebView.shared.loadVideo(videoId: self.videoId)

        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        // Update WebView frame if needed
        SingletonPlayerWebView.shared.ensureInHierarchy(container: container)
    }

    static func dismantleNSView(_: NSView, coordinator _: Coordinator) {
        // WebView is managed by SingletonPlayerWebView.shared - it persists
        // Remove the message handler to avoid duplicate handlers
        SingletonPlayerWebView.shared.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "miniPlayer")
    }

    // MARK: - Observer Script

    /// Script that observes the YouTube Music player bar and sends updates
    private static var observerScript: String {
        """
        (function() {
            'use strict';

            const bridge = window.webkit.messageHandlers.miniPlayer;

            function log(msg) {
                console.log('[MiniPlayer] ' + msg);
            }

            // Wait for the player bar to appear and observe it
            function waitForPlayerBar() {
                const playerBar = document.querySelector('ytmusic-player-bar');
                if (playerBar) {
                    log('Player bar found, setting up observer');
                    setupObserver(playerBar);
                    return;
                }
                setTimeout(waitForPlayerBar, 500);
            }

            function setupObserver(playerBar) {
                const observer = new MutationObserver(function(mutations) {
                    sendUpdate();
                });

                observer.observe(playerBar, {
                    attributes: true,
                    characterData: true,
                    childList: true,
                    subtree: true,
                    attributeOldValue: true,
                    characterDataOldValue: true
                });

                // Send initial update
                sendUpdate();

                // Also send periodic updates
                setInterval(sendUpdate, 1000);
            }

            function sendUpdate() {
                try {
                    const titleEl = document.querySelector('.ytmusic-player-bar.title');
                    const artistEl = document.querySelector('.ytmusic-player-bar.byline');
                    const progressBar = document.querySelector('#progress-bar');
                    const playPauseBtn = document.querySelector('.play-pause-button.ytmusic-player-bar');

                    const title = titleEl ? titleEl.textContent : '';
                    const artist = artistEl ? artistEl.textContent : '';
                    const progress = progressBar ? parseInt(progressBar.getAttribute('value') || '0') : 0;
                    const duration = progressBar ? parseInt(progressBar.getAttribute('aria-valuemax') || '0') : 0;

                    // Check if playing by looking at the button title
                    const isPlaying = playPauseBtn ?
                        playPauseBtn.getAttribute('title') === 'Pause' ||
                        playPauseBtn.getAttribute('aria-label') === 'Pause' : false;

                    bridge.postMessage({
                        type: 'STATE_UPDATE',
                        title: title,
                        artist: artist,
                        progress: progress,
                        duration: duration,
                        isPlaying: isPlaying
                    });
                } catch (e) {
                    log('Error sending update: ' + e);
                }
            }

            // Start waiting
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', waitForPlayerBar);
            } else {
                waitForPlayerBar();
            }
        })();
        """
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onStateChange: ((PlayerState) -> Void)?
        var onMetadataChange: ((String, String, Double) -> Void)?

        init(
            onStateChange: ((PlayerState) -> Void)?,
            onMetadataChange: ((String, String, Double) -> Void)?
        ) {
            self.onStateChange = onStateChange
            self.onMetadataChange = onMetadataChange
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            // Page loaded
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            self.onStateChange?(.error(error.localizedDescription))
        }

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            if type == "STATE_UPDATE" {
                let title = body["title"] as? String ?? ""
                let artist = body["artist"] as? String ?? ""
                let duration = body["duration"] as? Double ?? 0
                let isPlaying = body["isPlaying"] as? Bool ?? false

                if !title.isEmpty {
                    self.onMetadataChange?(title, artist, duration)
                }

                self.onStateChange?(isPlaying ? .playing : .paused)
            }
        }
    }
}

// MARK: - SingletonPlayerWebView

/// Manages a single WebView instance for the entire app lifetime.
/// This ensures there's only ever ONE WebView playing audio.
@MainActor
final class SingletonPlayerWebView {
    static let shared = SingletonPlayerWebView()

    private(set) var webView: WKWebView?
    var currentVideoId: String?
    private var coordinator: Coordinator?
    private let logger = DiagnosticsLogger.player

    /// Current display mode for the WebView.
    enum DisplayMode {
        case hidden // 1x1 for audio-only
        case miniPlayer // 160x90 toast
        case video // Full size in video window
    }

    private(set) var displayMode: DisplayMode = .hidden

    private init() {
        Self.writeDebugLog("SingletonPlayerWebView initialized")
    }

    /// Get or create the singleton WebView.
    func getWebView(
        webKitManager: WebKitManager,
        playerService: PlayerService
    ) -> WKWebView {
        if let existing = webView {
            return existing
        }

        Self.writeDebugLog("Creating singleton WebView")
        self.logger.info("Creating singleton WebView")

        // Create coordinator
        self.coordinator = Coordinator(playerService: playerService)

        let configuration = webKitManager.createWebViewConfiguration()

        // Add script message handler
        configuration.userContentController.add(self.coordinator!, name: "singletonPlayer")

        // Inject volume initialization script FIRST (at document start)
        // This ensures __kasetTargetVolume is set before the observer script runs
        let savedVolume = playerService.volume
        let volumeInitScript = WKUserScript(
            source: "window.__kasetTargetVolume = \(savedVolume);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(volumeInitScript)

        // Inject observer script (at document end)
        let script = WKUserScript(
            source: Self.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = self.coordinator
        newWebView.customUserAgent = WebKitManager.userAgent

        #if DEBUG
            newWebView.isInspectable = true
        #endif

        self.webView = newWebView
        return newWebView
    }

    /// Ensures the WebView is in the given container's view hierarchy.
    func ensureInHierarchy(container: NSView) {
        guard let webView, webView.superview !== container else { return }
        Self.writeDebugLog("ensureInHierarchy: reparenting WebView to new container")
        webView.removeFromSuperview()
        container.addSubview(webView)

        // Use autoresizing to match container size
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // If we're in video mode, re-apply the CSS injection after reparenting
        if self.displayMode == .video {
            Self.writeDebugLog("ensureInHierarchy: in video mode, injecting CSS")
            // Delay slightly to let the layout happen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.injectVideoModeCSS()
            }
        }
    }

    /// Updates WebView size based on display mode.
    func updateDisplayMode(_ mode: DisplayMode) {
        guard let webView else {
            Self.writeDebugLog("updateDisplayMode called but webView is nil!")
            return
        }
        self.displayMode = mode
        Self.writeDebugLog("updateDisplayMode called with mode: \(mode)")

        switch mode {
        case .hidden:
            // WebView stays in hierarchy but tiny
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            self.removeVideoModeCSS()
        case .miniPlayer:
            webView.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
            self.removeVideoModeCSS()
        case .video:
            // Full size - parent container determines size
            if let superview = webView.superview {
                webView.frame = superview.bounds
                Self.writeDebugLog("WebView frame set to: \(superview.bounds)")
            } else {
                Self.writeDebugLog("WebView has no superview!")
            }
            webView.autoresizingMask = [.width, .height]
            self.injectVideoModeCSS()
        }
    }

    /// Injects CSS to hide YouTube Music UI and show only the video.
    private func injectVideoModeCSS() {
        guard let webView else { return }

        Self.writeDebugLog("Starting video mode injection...")

        // First, let's debug what's in the DOM
        let debugScript = """
            (function() {
                const video = document.querySelector('video');
                const videoInfo = video ? {
                    src: video.src ? video.src.substring(0, 100) : 'none',
                    width: video.videoWidth,
                    height: video.videoHeight,
                    paused: video.paused,
                    display: getComputedStyle(video).display,
                    visibility: getComputedStyle(video).visibility
                } : 'no video element';

                const tabs = document.querySelectorAll('tp-yt-paper-tab');
                const tabTexts = Array.from(tabs).map(t => t.textContent.trim());

                const playerPage = document.querySelector('ytmusic-player-page');
                const moviePlayer = document.querySelector('#movie_player');
                const html5Player = document.querySelector('.html5-video-player');

                return {
                    videoInfo: videoInfo,
                    tabTexts: tabTexts,
                    hasPlayerPage: !!playerPage,
                    hasMoviePlayer: !!moviePlayer,
                    hasHtml5Player: !!html5Player,
                    url: window.location.href
                };
            })();
        """

        webView.evaluateJavaScript(debugScript) { [weak self] result, error in
            if let error {
                Self.writeDebugLog("Debug script error: \(error.localizedDescription)")
            } else if let info = result {
                Self.writeDebugLog("DOM Debug: \(info)")
            }

            // Now click the Video tab
            self?.clickVideoTabAndInjectCSS()
        }
    }

    /// Write debug log to a file for debugging.
    private static func writeDebugLog(_ message: String) {
        let logFile = URL(fileURLWithPath: "/tmp/kaset_video_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
        print("[Kaset Video Debug] \(message)")
    }

    /// Clicks the Video tab and then injects CSS.
    private func clickVideoTabAndInjectCSS() {
        guard let webView else { return }

        // The Song/Video toggle is different from the tabs
        // It appears as a segmented control near the top of the player page
        let clickVideoTabScript = """
            (function() {
                // Method 1: Look for the Song/Video toggle buttons
                // These are typically in a toggle group with "Song" and "Video" labels
                const toggleButtons = document.querySelectorAll('tp-yt-paper-button, button, [role="button"]');
                for (const btn of toggleButtons) {
                    const text = (btn.textContent || btn.innerText || '').trim().toLowerCase();
                    if (text === 'video') {
                        btn.click();
                        console.log('[Kaset] Clicked Video toggle button');
                        return { clicked: true, method: 'toggleButton', text: text };
                    }
                }

                // Method 2: Look for ytmusic-player-page and find the toggle there
                const playerPage = document.querySelector('ytmusic-player-page');
                if (playerPage) {
                    // The toggle might be in a specific container
                    const toggleContainer = playerPage.querySelector('.toggle-container, .segment-button-container, [class*="toggle"]');
                    if (toggleContainer) {
                        const buttons = toggleContainer.querySelectorAll('button, [role="button"]');
                        for (const btn of buttons) {
                            const text = (btn.textContent || '').trim().toLowerCase();
                            if (text === 'video') {
                                btn.click();
                                return { clicked: true, method: 'toggleContainer', text: text };
                            }
                        }
                    }
                }

                // Method 3: Find by aria-label or data attributes
                const videoBtn = document.querySelector('[aria-label*="Video" i], [data-value="VIDEO"]');
                if (videoBtn) {
                    videoBtn.click();
                    return { clicked: true, method: 'ariaLabel' };
                }

                // Method 4: Look in the header area for Song/Video chips
                const chips = document.querySelectorAll('yt-chip-cloud-chip-renderer, ytmusic-chip-renderer, .chip');
                for (const chip of chips) {
                    const text = (chip.textContent || '').trim().toLowerCase();
                    if (text === 'video') {
                        chip.click();
                        return { clicked: true, method: 'chip', text: text };
                    }
                }

                return { clicked: false, message: 'Video toggle not found' };
            })();
        """

        webView.evaluateJavaScript(clickVideoTabScript) { [weak self] result, error in
            if let error {
                Self.writeDebugLog("Click video error: \(error.localizedDescription)")
            } else {
                Self.writeDebugLog("Click video result: \(String(describing: result))")
            }

            // Wait a moment for the video mode to activate, then inject CSS
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.injectVideoModeStyles()
            }
        }
    }

    /// Actually injects the CSS styles for video mode.
    private func injectVideoModeStyles() {
        guard let webView else { return }

        // CSS to hide YouTube Music UI but NOT the video element
        let css = """
            /* Hide navigation and player bar */
            ytmusic-player-bar,
            ytmusic-nav-bar,
            #nav-bar-background,
            ytmusic-guide-renderer,
            #guide-wrapper {
                display: none !important;
            }

            /* Hide the side panel (queue, lyrics, etc) */
            .side-panel,
            #side-panel,
            .content-side-panel,
            ytmusic-player-queue,
            ytmusic-tab-renderer {
                display: none !important;
            }

            /* Hide ALL player controls - these appear on top of video */
            /* Use very specific selectors and multiple hiding techniques */
            .middle-controls,
            .left-controls,
            .right-controls,
            .player-controls-container,
            .song-media-controls,
            .middle-controls-buttons,
            .shuffle-button,
            .previous-button,
            .play-pause-button,
            .next-button,
            .repeat-button,
            .time-info,
            .slider-container,
            ytmusic-player-page .middle-controls,
            ytmusic-player-page .player-controls-container,
            ytmusic-player .middle-controls,
            ytmusic-player .player-controls-container,
            #player .middle-controls,
            #player .player-controls-container {
                display: none !important;
                visibility: hidden !important;
                opacity: 0 !important;
                pointer-events: none !important;
                width: 0 !important;
                height: 0 !important;
                overflow: hidden !important;
                position: absolute !important;
                left: -9999px !important;
            }

            /* Hide ALL icon buttons in player */
            tp-yt-paper-icon-button,
            ytmusic-player-page tp-yt-paper-icon-button,
            ytmusic-player tp-yt-paper-icon-button,
            #player tp-yt-paper-icon-button,
            .ytmusic-player-page tp-yt-paper-icon-button {
                display: none !important;
                visibility: hidden !important;
                opacity: 0 !important;
            }

            /* Hide player page content except the player itself */
            .content-info-wrapper,
            .song-info,
            .byline-wrapper,
            .title-wrapper,
            #tabsContainer,
            .tab-headers,
            tp-yt-paper-tab,
            ytmusic-like-button-renderer,
            .toggle-player-page-button,
            .player-minimize-button,
            .expand-button,
            #progress-bar,
            .slider,
            .menu-button,
            #menu-button,
            ytmusic-toggle-button-renderer,
            .description,
            .metadata,
            .subtitle,
            .byline {
                display: none !important;
            }

            /* Hide YT player chrome */
            .ytp-chrome-top,
            .ytp-chrome-bottom,
            .ytp-gradient-top,
            .ytp-gradient-bottom,
            .ytp-pause-overlay,
            .ytp-watermark {
                display: none !important;
            }

            /* Dark background */
            html, body, ytmusic-app, ytmusic-app-layout, #layout {
                background: #000 !important;
                overflow: hidden !important;
            }

            /* Position the player page to fill viewport */
            ytmusic-player-page {
                position: fixed !important;
                top: 0 !important;
                left: 0 !important;
                width: 100vw !important;
                height: 100vh !important;
                background: #000 !important;
                padding: 0 !important;
                margin: 0 !important;
            }

            /* Make sure video fills the screen - leave space for native controls */
            video {
                position: fixed !important;
                top: 0 !important;
                left: 0 !important;
                width: 100vw !important;
                height: calc(100vh - 60px) !important;
                object-fit: contain !important;
                z-index: 999999 !important;
                background: #000 !important;
            }

            /* Position player containers */
            ytmusic-player, #player, #movie_player, .html5-video-player, .html5-video-container {
                position: fixed !important;
                top: 0 !important;
                left: 0 !important;
                width: 100vw !important;
                height: 100vh !important;
                background: #000 !important;
            }

            /* Hide the bottom bar area that shows gray */
            .av-surround, .player-bar-background, .ytmusic-player-bar {
                display: none !important;
                background: #000 !important;
            }
        """

        let script = """
            (function() {
                // Remove existing style if present
                const existing = document.getElementById('kaset-video-mode-style');
                if (existing) existing.remove();

                const style = document.createElement('style');
                style.id = 'kaset-video-mode-style';
                style.textContent = `\(css.replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "\n", with: " "))`;
                document.head.appendChild(style);
                console.log('[Kaset] Video mode CSS injected');
            })();
        """

        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                Self.writeDebugLog("Failed to inject video mode CSS: \(error.localizedDescription)")
            } else {
                Self.writeDebugLog("Video mode CSS injected successfully")
                // Debug: check video state after CSS injection
                self?.debugVideoStateAfterInjection()
            }
        }
    }

    /// Debug helper to check video state after CSS injection.
    private func debugVideoStateAfterInjection() {
        guard let webView else { return }

        let debugScript = """
            (function() {
                const video = document.querySelector('video');
                if (!video) return { error: 'No video element found' };

                const style = getComputedStyle(video);
                const songImage = document.querySelector('.song-image img, .thumbnail img');
                return {
                    hasSrc: !!video.src,
                    srcPrefix: video.src ? video.src.substring(0, 50) : 'none',
                    videoWidth: video.videoWidth,
                    videoHeight: video.videoHeight,
                    clientWidth: video.clientWidth,
                    clientHeight: video.clientHeight,
                    display: style.display,
                    visibility: style.visibility,
                    opacity: style.opacity,
                    position: style.position,
                    zIndex: style.zIndex,
                    paused: video.paused,
                    currentTime: video.currentTime,
                    readyState: video.readyState,
                    songImageSrc: songImage ? songImage.src : 'none'
                };
            })();
        """

        webView.evaluateJavaScript(debugScript) { result, error in
            if let error {
                Self.writeDebugLog("Post-injection debug error: \(error.localizedDescription)")
            } else {
                Self.writeDebugLog("Post-injection video state: \(String(describing: result))")
            }
        }
    }

    /// Removes the video mode CSS to restore normal YouTube Music UI.
    private func removeVideoModeCSS() {
        guard let webView else { return }

        let script = """
            (function() {
                const style = document.getElementById('kaset-video-mode-style');
                if (style) style.remove();
            })();
        """

        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Load a video, stopping any currently playing audio first.
    func loadVideo(videoId: String) {
        guard let webView else {
            self.logger.error("loadVideo called but webView is nil")
            return
        }

        let previousVideoId = self.currentVideoId
        guard videoId != previousVideoId else {
            self.logger.info("Video \(videoId) already loaded, skipping")
            return
        }

        self.logger.info("Loading video: \(videoId) (was: \(previousVideoId ?? "none"))")

        // Update currentVideoId immediately to prevent duplicate loads
        self.currentVideoId = videoId

        // Get current volume from PlayerService via coordinator
        let currentVolume = self.coordinator?.playerService.volume ?? 1.0
        self.logger.info("Will apply volume \(currentVolume) after page load")

        // Stop current playback first, then load new video
        let urlToLoad = URL(string: "https://music.youtube.com/watch?v=\(videoId)")!
        webView.evaluateJavaScript("document.querySelector('video')?.pause()") { [weak self] _, _ in
            guard let self, let webView = self.webView else { return }

            // Set target volume BEFORE loading so it's ready when video element appears
            let setTargetScript = "window.__kasetTargetVolume = \(currentVolume);"
            webView.evaluateJavaScript(setTargetScript, completionHandler: nil)

            webView.load(URLRequest(url: urlToLoad))
        }
    }

    // MARK: - Playback Controls

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

    // Observer script for playback state
    private static var observerScript: String {
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
            let isEnforcingVolume = false; // Prevent infinite loops

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

                    // Volume enforcement: listen for external volume changes
                    video.addEventListener('volumechange', () => {
                        if (isEnforcingVolume) return; // Ignore our own changes
                        const targetVol = window.__kasetTargetVolume;
                        // Only enforce if we have a valid target volume set by Swift
                        if (targetVol !== undefined && Math.abs(video.volume - targetVol) > 0.01) {
                            isEnforcingVolume = true;
                            video.volume = targetVol;
                            isEnforcingVolume = false;
                        }
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

                    // Detect if video is available
                    // YouTube Music always streams from video, so video is always available
                    // when there's a track playing. Check if video element exists and has src.
                    const video = document.querySelector('video');
                    const hasVideo = video !== null && video.src && video.src.length > 0;

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

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let playerService: PlayerService

        init(playerService: PlayerService) {
            self.playerService = playerService
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String,
                  type == "STATE_UPDATE"
            else { return }

            let isPlaying = body["isPlaying"] as? Bool ?? false
            let progress = body["progress"] as? Int ?? 0
            let duration = body["duration"] as? Int ?? 0
            let title = body["title"] as? String ?? ""
            let artist = body["artist"] as? String ?? ""
            let thumbnailUrl = body["thumbnailUrl"] as? String ?? ""
            let trackChanged = body["trackChanged"] as? Bool ?? false
            let likeStatusString = body["likeStatus"] as? String ?? "INDIFFERENT"
            let hasVideo = body["hasVideo"] as? Bool ?? false

            // Parse like status
            let likeStatus: LikeStatus = switch likeStatusString {
            case "LIKE":
                .like
            case "DISLIKE":
                .dislike
            default:
                .indifferent
            }

            Task { @MainActor in
                self.playerService.updatePlaybackState(
                    isPlaying: isPlaying,
                    progress: Double(progress),
                    duration: Double(duration)
                )

                // Update video availability
                self.playerService.updateVideoAvailability(hasVideo: hasVideo)

                // Update like status only when track changes (initial state)
                if trackChanged {
                    self.playerService.updateLikeStatus(likeStatus)
                }

                // Update track metadata if track changed
                if trackChanged, !title.isEmpty {
                    self.playerService.updateTrackMetadata(
                        title: title,
                        artist: artist,
                        thumbnailUrl: thumbnailUrl
                    )
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            DiagnosticsLogger.player.info("Singleton WebView finished loading: \(webView.url?.absoluteString ?? "nil")")

            // Apply saved volume when page loads
            // Use a script that waits for the video element to exist
            let savedVolume = self.playerService.volume
            let applyVolumeScript = """
                (function() {
                    window.__kasetTargetVolume = \(savedVolume);
                    function applyVolume() {
                        const video = document.querySelector('video');
                        if (video) {
                            video.volume = \(savedVolume);
                            return;
                        }
                        setTimeout(applyVolume, 100);
                    }
                    applyVolume();
                })();
            """
            webView.evaluateJavaScript(applyVolumeScript, completionHandler: nil)
            DiagnosticsLogger.player.debug("Injected volume apply script: \(savedVolume)")
        }
    }
}
