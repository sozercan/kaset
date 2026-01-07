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

    var displayMode: DisplayMode = .hidden

    private init() {}

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

    /// Load a video, stopping any currently playing audio first.
    func loadVideo(videoId: String) {
        guard let webView else {
            self.logger.error("loadVideo called but webView is nil")
            return
        }

        let previousVideoId = self.currentVideoId
        guard videoId != previousVideoId else {
            self.logger.debug("Video \(videoId) already loaded, skipping")
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

                    // Close video window on track change, but skip during grace period
                    // (grace period prevents false positives during initial video mode setup)
                    // Note: trackChanged detection uses title/artist comparison from the observer script
                    if self.playerService.showVideo, !self.playerService.isVideoGracePeriodActive {
                        DiagnosticsLogger.player.info(
                            "trackChanged to '\(title)' while video shown - closing video window")
                        self.playerService.showVideo = false
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            DiagnosticsLogger.player.info(
                "Singleton WebView finished loading: \(webView.url?.absoluteString ?? "nil")")

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
            }
        }
    }
}
