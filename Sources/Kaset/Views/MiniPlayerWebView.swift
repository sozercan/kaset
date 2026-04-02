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

        // Remove existing handler if present to avoid duplicates, then add fresh one
        // This handles the case where makeNSView is called multiple times
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: "miniPlayer")
        contentController.add(context.coordinator, name: "miniPlayer")

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
        SingletonPlayerWebView.shared.webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "miniPlayer")
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

                    const title = titleEl ? titleEl.textContent : '';
                    const artist = artistEl ? artistEl.textContent : '';
                    const progress = progressBar ? parseInt(progressBar.getAttribute('value') || '0') : 0;
                    const duration = progressBar ? parseInt(progressBar.getAttribute('aria-valuemax') || '0') : 0;

                    // Use video element's paused property for language-agnostic detection
                    // Previously checked button title/aria-label which fails for non-English locales
                    const video = document.querySelector('video');
                    const isPlaying = video ? !video.paused : false;

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

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebView content process crashed - attempt recovery by reloading
            DiagnosticsLogger.player.error("MiniPlayer WebView content process terminated, attempting reload")
            self.onStateChange?(.error("Player crashed, reloading..."))
            webView.reload()
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
///
/// Extensions provide:
/// - Playback controls (SingletonPlayerWebView+PlaybackControls.swift)
/// - Video mode CSS injection (SingletonPlayerWebView+VideoMode.swift)
/// - Observer script (SingletonPlayerWebView+ObserverScript.swift)
@MainActor
final class SingletonPlayerWebView {
    static let shared = SingletonPlayerWebView()

    private(set) var webView: WKWebView?
    var currentVideoId: String?
    var coordinator: Coordinator?
    let logger = DiagnosticsLogger.player

    /// Current display mode for the WebView.
    enum DisplayMode {
        case hidden // 1x1 for audio-only
        case miniPlayer // 160x90 toast
        case video // Full size in video window
    }

    /// How `loadVideo` behaves when Swift already tracks a `videoId` (repeat-one vs queue drift recovery).
    enum VideoLoadStrategy: Equatable {
        /// Skip navigation when `videoId` matches `currentVideoId`.
        case standard
        /// Same `videoId` as tracked: `seek(0)` + play only (fast). Different id: full watch URL load.
        case preferInPlaceWhenSameVideoId
        /// Same `videoId` as tracked: full `webView.load` (DOM out of sync with Swift). Different id: full load.
        case forceFullPageWhenSameVideoId
    }

    var displayMode: DisplayMode = .hidden
    private var mediaControlUsesNextPrev: Bool

    /// Tracks if lyrics high-frequency polling should be active
    /// Used to restore polling after full-page navigation
    var isLyricsPollActive = false

    private init() {
        self.mediaControlUsesNextPrev = SettingsManager.shared.mediaControlStyle == .nextPreviousTrack
    }

    /// Get or create the singleton WebView.
    func getWebView(
        webKitManager: WebKitManager,
        playerService: PlayerService
    ) -> WKWebView {
        if let existing = webView {
            return existing
        }

        self.logger.info("Creating singleton WebView")

        // Create coordinator
        self.coordinator = Coordinator(playerService: playerService)

        let configuration = webKitManager.createWebViewConfiguration()

        // Add script message handler
        configuration.userContentController.add(self.coordinator!, name: "singletonPlayer")

        // Note: We do NOT inject a static volume init script here because the volume
        // may change between WebView creation and page loads. Instead, we:
        // 1. Set __kasetTargetVolume in loadVideo() before loading a new page
        // 2. Update it in didFinish after each page load completes
        // This ensures we always use the CURRENT volume, not a stale value.

        // Keep the page preference in sync before any page script reads localStorage.
        let mediaControlBootstrapScript = WKUserScript(
            source: self.mediaControlBootstrapScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(mediaControlBootstrapScript)

        // Inject mediaSession override at document end without allowing duplicate RAF loops.
        let mediaOverrideScript = WKUserScript(
            source: Self.mediaControlOverrideScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(mediaOverrideScript)

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
        webView.removeFromSuperview()
        container.addSubview(webView)

        // Use autoresizing to match container size (consistent with waitForValidBoundsAndInject)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        // Note: Don't inject CSS here - updateDisplayMode() handles it after layout completes
    }

    /// Starts high frequency polling for synced lyrics
    func startLyricsPoll() {
        self.isLyricsPollActive = true
        self.webView?.evaluateJavaScript("if (window.startLyricsPoll) { window.startLyricsPoll(); }")
    }

    /// Stops high frequency polling for synced lyrics
    func stopLyricsPoll() {
        self.isLyricsPollActive = false
        self.webView?.evaluateJavaScript("if (window.stopLyricsPoll) { window.stopLyricsPoll(); }")
    }

    /// Load a video, stopping any currently playing audio first.
    /// Note: Full page navigation destroys the video element; same-id restarts use ``restartInPlaceFromBeginning()`` when possible.
    /// AirPlay connections will be lost on full navigation but the auto-reconnect picker will appear.
    func loadVideo(videoId: String, strategy: VideoLoadStrategy = .standard) {
        guard let webView else {
            self.logger.error("loadVideo called but webView is nil")
            return
        }

        let previousVideoId = self.currentVideoId

        switch strategy {
        case .standard:
            if videoId == previousVideoId {
                self.logger.debug("Video \(videoId) already loaded, skipping")
                return
            }
        case .preferInPlaceWhenSameVideoId:
            if videoId == previousVideoId {
                self.logger.debug("In-place restart for \(videoId) (same id — avoid full page reload)")
                self.restartInPlaceFromBeginning()
                return
            }
        case .forceFullPageWhenSameVideoId:
            if videoId == previousVideoId {
                self.logger.info("Force full navigation for \(videoId) (DOM/WebView resync)")
            }
        }

        if videoId != previousVideoId {
            self.logger.info("Loading video: \(videoId) (was: \(previousVideoId ?? "none"))")
        }

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

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let playerService: PlayerService

        init(playerService: PlayerService) {
            self.playerService = playerService
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            let observedVideoId: String? = if let videoId = body["videoId"] as? String, !videoId.isEmpty {
                videoId
            } else {
                nil
            }

            if type == "TRACK_ENDED" {
                Task { @MainActor in
                    await self.playerService.handleTrackEnded(observedVideoId: observedVideoId)
                }
                return
            }

            if type == "REMOTE_NEXT" {
                Task { @MainActor in
                    await self.playerService.next()
                }
                return
            }

            if type == "REMOTE_PREVIOUS" {
                Task { @MainActor in
                    await self.playerService.previous()
                }
                return
            }

            // Handle AirPlay status updates
            if type == "AIRPLAY_STATUS" {
                let isConnected = body["isConnected"] as? Bool ?? false
                let wasRequested = body["wasRequested"] as? Bool ?? false

                Task { @MainActor in
                    self.playerService.updateAirPlayStatus(
                        isConnected: isConnected,
                        wasRequested: wasRequested
                    )
                }
                return
            }

            // Handle high frequency lyrics time updates
            if type == "LYRICS_TIME" {
                if let time = body["time"] as? Double {
                    Task { @MainActor in
                        self.playerService.currentTimeMs = Int(time * 1000)
                    }
                }
                return
            }

            guard type == "STATE_UPDATE" else { return }

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

                // Repeat-one must keep enforcing queue/current song even if WebView doesn't flag `trackChanged`
                // for a transient autoplay swap. In other modes, keep the existing trackChanged gate.
                let shouldReconcileMetadata = (trackChanged || self.playerService.repeatMode == .one)
                    && (observedVideoId != nil || !title.isEmpty)

                if shouldReconcileMetadata {
                    self.playerService.updateTrackMetadata(
                        title: title,
                        artist: artist,
                        thumbnailUrl: thumbnailUrl,
                        videoId: observedVideoId
                    )

                    // Close video window on track change, but skip during grace period
                    // (grace period prevents false positives during initial video mode setup)
                    // Note: trackChanged detection now uses videoId changes too, so this
                    // can fire before the player bar text has caught up to the new track.
                    if self.playerService.showVideo, !self.playerService.isVideoGracePeriodActive {
                        DiagnosticsLogger.player.info(
                            "trackChanged to '\(title)' while video shown - closing video window"
                        )
                        self.playerService.showVideo = false
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            DiagnosticsLogger.player.info(
                "Singleton WebView finished loading: \(webView.url?.absoluteString ?? "nil")"
            )

            // Apply the current volume when page finishes loading
            // This is critical because YouTube may set its own default volume
            let savedVolume = self.playerService.volume
            let applyVolumeScript = """
                (function() {
                    // Set target volume for enforcement
                    window.__kasetTargetVolume = \(savedVolume);
                    // Set flag to prevent enforcement from reverting our change
                    window.__kasetIsSettingVolume = true;

                    // Apply to video element if it exists
                    const video = document.querySelector('video');
                    if (video) {
                        video.volume = \(savedVolume);
                    }

                    // Sync YouTube's internal player APIs to prevent overrides
                    const ytVolume = Math.round(\(savedVolume) * 100);
                    const player = document.querySelector('ytmusic-player');
                    if (player && player.playerApi) {
                        player.playerApi.setVolume(ytVolume);
                    }
                    const moviePlayer = document.getElementById('movie_player');
                    if (moviePlayer && moviePlayer.setVolume) {
                        moviePlayer.setVolume(ytVolume);
                    }

                    // Clear flag after a moment
                    setTimeout(() => { window.__kasetIsSettingVolume = false; }, 100);

                    return video ? 'applied' : 'no-video-yet';
                })();
            """
            webView.evaluateJavaScript(applyVolumeScript) { result, error in
                if let error {
                    DiagnosticsLogger.player.error(
                        "Failed to apply saved volume \(savedVolume): \(error.localizedDescription)"
                    )
                } else if let resultString = result as? String {
                    DiagnosticsLogger.player.debug("Volume apply result: \(resultString)")
                }

                // Restore lyrics high-frequency polling if it was active
                if SingletonPlayerWebView.shared.isLyricsPollActive {
                    // Re-start to inject interval onto fresh JS context
                    SingletonPlayerWebView.shared.startLyricsPoll()
                }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebView content process crashed - attempt recovery
            DiagnosticsLogger.player.error("Singleton WebView content process terminated, attempting recovery")

            // Get the current video ID before reloading
            let currentVideoId = SingletonPlayerWebView.shared.currentVideoId

            // Reload the WebView
            webView.reload()

            // If we had a video playing, reload it after a brief delay
            if let videoId = currentVideoId {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    // Reset currentVideoId to force reload
                    SingletonPlayerWebView.shared.currentVideoId = nil
                    SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
                }
            }
        }
    }
}

// MARK: - SingletonPlayerWebView Media Controls

extension SingletonPlayerWebView {
    /// Updates the current page and the bootstrap state used by future page loads.
    func setMediaControlStyle(useNextPrev: Bool) {
        self.mediaControlUsesNextPrev = useNextPrev

        guard let webView = self.webView else { return }
        let script = Self.mediaControlStyleSyncScript(useNextPrev: useNextPrev)
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func mediaControlBootstrapScript() -> String {
        Self.mediaControlStyleBootstrapScript(useNextPrev: self.mediaControlUsesNextPrev)
    }

    static func mediaControlStyleBootstrapScript(useNextPrev: Bool) -> String {
        let jsBoolean = useNextPrev ? "true" : "false"
        return """
            (function() {
                try {
                    localStorage.setItem('kasetUseNextPrev', '\(jsBoolean)');
                } catch (e) {}
                window.__kasetUseNextPrev = \(jsBoolean);
            })();
        """
    }

    static func mediaControlStyleSyncScript(useNextPrev: Bool) -> String {
        let jsBoolean = useNextPrev ? "true" : "false"
        let restoreSeekHandlers = if useNextPrev {
            ""
        } else {
            """
                try {
                    var ms = navigator.mediaSession;
                    ms.setActionHandler('nexttrack', null);
                    ms.setActionHandler('previoustrack', null);
                    ms.setActionHandler('seekforward', function(d) {
                        var v = document.querySelector('video');
                        if (v) v.currentTime = Math.min(v.duration,
                            v.currentTime + ((d && d.seekOffset) || 15));
                    });
                    ms.setActionHandler('seekbackward', function(d) {
                        var v = document.querySelector('video');
                        if (v) v.currentTime = Math.max(0,
                            v.currentTime - ((d && d.seekOffset) || 15));
                    });
                } catch (e) {}
            """
        }

        return """
            (function() {
                try {
                    localStorage.setItem('kasetUseNextPrev', '\(jsBoolean)');
                } catch (e) {}
                window.__kasetUseNextPrev = \(jsBoolean);
                if (typeof window.__kasetRefreshMediaControlStyle === 'function') {
                    window.__kasetRefreshMediaControlStyle();
                }
                \(restoreSeekHandlers)
            })();
        """
    }

    static var mediaControlOverrideScript: String {
        """
        (function() {
            if (typeof window.__kasetUseNextPrev !== 'boolean') {
                try {
                    window.__kasetUseNextPrev =
                        localStorage.getItem('kasetUseNextPrev') === 'true';
                } catch (e) {
                    window.__kasetUseNextPrev = false;
                }
            }

            var overrideFrameId = null;

            function applyOverride() {
                if (!window.__kasetUseNextPrev) {
                    return;
                }
                try {
                    var ms = navigator.mediaSession;
                    ms.setActionHandler('seekforward', null);
                    ms.setActionHandler('seekbackward', null);
                    ms.setActionHandler('nexttrack', function() {
                        window.webkit.messageHandlers.singletonPlayer
                            .postMessage({ type: 'REMOTE_NEXT' });
                    });
                    ms.setActionHandler('previoustrack', function() {
                        window.webkit.messageHandlers.singletonPlayer
                            .postMessage({ type: 'REMOTE_PREVIOUS' });
                    });
                } catch (e) {}
            }

            function scheduleOverrideLoop() {
                if (overrideFrameId !== null || !window.__kasetUseNextPrev) {
                    return;
                }

                overrideFrameId = requestAnimationFrame(function() {
                    overrideFrameId = null;
                    if (!window.__kasetUseNextPrev) {
                        return;
                    }
                    applyOverride();
                    scheduleOverrideLoop();
                });
            }

            window.__kasetRefreshMediaControlStyle = function() {
                applyOverride();
                scheduleOverrideLoop();
            };

            window.__kasetRefreshMediaControlStyle();

            // Re-apply on video events where YouTube re-registers handlers.
            function attachVideoOverride() {
                var v = document.querySelector('video');
                if (!v || v.__kasetOverrideAttached) return;
                v.__kasetOverrideAttached = true;
                ['playing','loadedmetadata','loadeddata','canplay','seeked']
                    .forEach(function(e) { v.addEventListener(e, applyOverride); });
            }

            attachVideoOverride();
            new MutationObserver(attachVideoOverride)
                .observe(document.documentElement, {childList:true, subtree:true});
        })();
        """
    }
}
