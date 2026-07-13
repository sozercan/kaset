// swiftlint:disable file_length
import os
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
    @Environment(AuthService.self) private var authService

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
            playerService: self.playerService,
            usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore
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
    weak var webKitManager: WebKitManager?
    private weak var currentContainer: NSView?
    private var usesCookieFreeDataStore: Bool?
    var currentVideoId: String?
    var coordinator: Coordinator?
    let logger = DiagnosticsLogger.player
    private var loadGeneration = 0
    private(set) var documentGeneration = WebPlaybackDocumentGeneration()
    private(set) var documentNavigationStartedAtMilliseconds: Double?
    private var documentNavigations: [ObjectIdentifier: WebPlaybackTrackedNavigation] = [:]
    private var cancelledDocumentNavigations: [ObjectIdentifier: WebPlaybackCancelledNavigation] = [:]
    private var continuationGenerationsAwaitingStart: Set<UInt64> = []

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

    nonisolated static func acceptsPlaybackRequest(
        videoId: String,
        currentVideoId: String?,
        hasWebView: Bool,
        strategy: VideoLoadStrategy
    ) -> Bool {
        guard hasWebView, videoId == currentVideoId else { return true }
        return strategy != .standard
    }

    func acceptsPlaybackRequest(
        videoId: String,
        strategy: VideoLoadStrategy
    ) -> Bool {
        Self.acceptsPlaybackRequest(
            videoId: videoId,
            currentVideoId: self.currentVideoId,
            hasWebView: self.webView != nil,
            strategy: strategy
        )
    }

    nonisolated static func freshSameIDPlaybackStrategy(
        isShowingAd: Bool
    ) -> VideoLoadStrategy {
        isShowingAd ? .forceFullPageWhenSameVideoId : .preferInPlaceWhenSameVideoId
    }

    var displayMode: DisplayMode = .hidden
    var mediaControlUsesNextPrev: Bool
    var playbackAudioQuality: SettingsManager.PlaybackAudioQuality

    /// Native timer that re-asserts the media-key override while backgrounded.
    /// See `beginBackgroundMediaControlReassertion()`.
    var mediaControlReassertTimer: Timer?

    /// Tracks if lyrics line-boundary polling should be active.
    /// Used to restore polling after full-page navigation.
    var isLyricsPollActive = false

    /// Last synced-lyrics line ranges supplied by the visible lyrics panel.
    /// Used by the reload fallback so polling does not restart with an empty range list.
    private var lastLyricsLineRanges: [[String: Int]] = []

    private init() {
        self.mediaControlUsesNextPrev = SettingsManager.shared.mediaControlStyle == .nextPreviousTrack
        self.playbackAudioQuality = SettingsManager.shared.playbackAudioQuality
    }

    /// Get or create the singleton WebView.
    func getWebView(
        webKitManager: WebKitManager,
        playerService: PlayerService,
        usesCookieFreeDataStore: Bool = false
    ) -> WKWebView {
        if let existing = webView, self.usesCookieFreeDataStore == usesCookieFreeDataStore {
            return existing
        }
        let previousContainer = self.currentContainer
        if self.webView != nil {
            self.logger.info("Recreating singleton WebView for auth data-store boundary")
            self.tearDown()
        }

        self.logger.info("Creating singleton WebView")
        self.usesCookieFreeDataStore = usesCookieFreeDataStore

        // Create coordinator
        self.coordinator = Coordinator(playerService: playerService)

        let configuration = webKitManager.createWebViewConfiguration(
            websiteDataStore: usesCookieFreeDataStore ? .nonPersistent() : nil
        )

        // Add script message handler
        configuration.userContentController.add(self.coordinator!, name: "singletonPlayer")

        // Dynamic startup state is refreshed before each full page load so the
        // next document gets current volume/autoplay flags at document start.

        self.installUserScripts(
            on: configuration.userContentController,
            shouldAutoplay: playerService.shouldAutoplayPlaybackDocument,
            targetVolume: playerService.volume,
            documentGeneration: Self.userScriptDocumentGeneration(from: self.documentGeneration),
            nativePlaybackGeneration: playerService.currentNativeMusicPlaybackGeneration
        )

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = self.coordinator
        newWebView.customUserAgent = WebKitManager.userAgent
        self.webKitManager = webKitManager
        webKitManager.registerExtensionHostWebView(newWebView, role: .musicPlayer)

        #if DEBUG
            newWebView.isInspectable = true
        #endif

        self.webView = newWebView
        if let previousContainer {
            self.ensureInHierarchy(container: previousContainer)
        }
        return newWebView
    }

    /// Ensures the WebView is in the given container's view hierarchy.
    func ensureInHierarchy(container: NSView) {
        guard let webView else { return }
        self.currentContainer = container
        self.webKitManager?.extensionHostWebViewDidBecomeActive(webView)
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)

        // Use autoresizing to match container size (consistent with waitForValidBoundsAndInject)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]

        // Note: Don't re-inject CSS here if we're already in video mode.
        // Re-injecting causes the YouTube UI to briefly flicker back in because it
        // removes and re-creates our custom video container.
        // updateDisplayMode(.video) handles the initial injection perfectly.
    }

    /// Starts low-frequency line-boundary polling for synced lyrics.
    func startLyricsPoll(lineRanges: [[String: Int]]) {
        self.isLyricsPollActive = true
        self.lastLyricsLineRanges = lineRanges
        let jsonData = (try? JSONSerialization.data(withJSONObject: lineRanges)) ?? Data("[]".utf8)
        let lineRangesJSON = String(data: jsonData, encoding: .utf8) ?? "[]"
        self.webView?.evaluateJavaScript("if (window.startLyricsPoll) { window.startLyricsPoll(\(lineRangesJSON)); }")
    }

    /// Backward-compatible fallback used after page reloads before the lyrics view re-supplies line boundaries.
    func startLyricsPoll() {
        self.startLyricsPoll(lineRanges: self.lastLyricsLineRanges)
    }

    /// Stops high frequency polling for synced lyrics
    func stopLyricsPoll() {
        self.isLyricsPollActive = false
        self.webView?.evaluateJavaScript("if (window.stopLyricsPoll) { window.stopLyricsPoll(); }")
    }

    /// Stops playback, blanks the page, and detaches the persistent music WebView.
    func tearDown() {
        let blankURL = self.beginBlankDocumentNavigation()
        guard let webView else { return }
        self.logger.info("Tearing down singleton music WebView")
        self.loadGeneration += 1
        self.currentVideoId = nil
        webView.evaluateJavaScript("document.querySelector('video')?.pause()", completionHandler: nil)
        if let blankURL {
            webView.load(URLRequest(url: blankURL))
        }
        webView.removeFromSuperview()
        self.webKitManager?.extensionHostWebViewDidDeactivate(role: .musicPlayer)
        self.webView = nil
        self.coordinator = nil
        self.cancelledDocumentNavigations.removeAll()
        self.currentContainer = nil
        self.usesCookieFreeDataStore = nil
    }

    /// Recreates the playback WebView when crossing a cookie-store boundary while preserving the tracked video id.
    func rebuildForAuthDataStoreChange(usesCookieFreeDataStore: Bool) {
        guard self.usesCookieFreeDataStore != usesCookieFreeDataStore else { return }
        guard let webKitManager = self.webKitManager,
              let playerService = self.coordinator?.playerService
        else {
            self.usesCookieFreeDataStore = usesCookieFreeDataStore
            return
        }
        let videoId = self.currentVideoId
        let previousContainer = self.currentContainer
        self.logger.info("Rebuilding singleton music WebView for auth data-store boundary")
        self.tearDown()
        _ = self.getWebView(
            webKitManager: webKitManager,
            playerService: playerService,
            usesCookieFreeDataStore: usesCookieFreeDataStore
        )
        if let previousContainer {
            self.ensureInHierarchy(container: previousContainer)
        }
        self.currentVideoId = videoId
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

        self.cancelActiveDocumentNavigation(on: webView)

        // Update currentVideoId immediately to prevent duplicate loads
        self.currentVideoId = videoId
        self.loadGeneration &+= 1
        self.documentNavigationStartedAtMilliseconds = Date().timeIntervalSince1970 * 1000
        let reservedDocumentGeneration = self.documentGeneration.beginNavigation()

        // Get current volume from PlayerService via coordinator
        let currentVolume = self.coordinator?.playerService.volume ?? 1.0
        let shouldAutoplay = self.coordinator?.playerService.shouldAutoplayPlaybackDocument ?? false
        self.logger.info("Will apply volume \(currentVolume) after page load")

        self.installUserScripts(
            on: webView.configuration.userContentController,
            shouldAutoplay: shouldAutoplay,
            targetVolume: currentVolume,
            documentGeneration: reservedDocumentGeneration,
            nativePlaybackGeneration: self.coordinator?.playerService
                .currentNativeMusicPlaybackGeneration ?? 0
        )

        // Stop current playback first, then load new video. For a forced
        // full-page navigation (e.g. an identity-switch reload) skip pausing the
        // OLD <video>: the navigation tears it down anyway, and the pause event
        // would emit a stale STATE_UPDATE from the outgoing page that can be
        // mis-reconciled against a restored session before the new document loads.
        guard let urlToLoad = Self.playbackURL(
            videoId: videoId,
            documentGeneration: reservedDocumentGeneration
        ) else {
            self.handlePendingDocumentNavigationFailure(webView: webView)
            return
        }
        let prenavScript = """
            window.__kasetAutoplayPending = false;
            window.__kasetAutoplayAttempts = 0;
            window.__kasetAutoplayRetryScheduled = false;
            \(WebPlaybackDocumentGeneration.mediaSuppressionScript)
        """
        // Submit suppression best-effort, but never wait for its callback. During
        // rapid replacements a provisional WebContent process can defer an eval
        // completion for seconds; the generation gate already rejects every
        // outgoing observation, while starting the new navigation tears down its
        // media promptly.
        webView.evaluateJavaScript("\(prenavScript)void 0;", completionHandler: nil)

        // Keep the current page's target volume fresh until the new document
        // gets the same value from its document-start bootstrap.
        webView.evaluateJavaScript(
            "window.__kasetTargetVolume = \(currentVolume);",
            completionHandler: nil
        )
        self.startDocumentNavigation(
            on: webView,
            request: URLRequest(url: urlToLoad),
            generation: reservedDocumentGeneration
        )
    }

    /// Returns the JS snippet that hands the autoplay intent to the freshly loaded
    /// page's window. Restored sessions suppress autoplay so the reconcile path
    /// resumes at the saved seek rather than at 0s.
    nonisolated static func autoplayIntentScript(isRestoringPlaybackSession: Bool) -> String {
        self.autoplayIntentScript(shouldAutoplay: !isRestoringPlaybackSession)
    }

    nonisolated static func autoplayIntentScript(shouldAutoplay: Bool) -> String {
        "window.__kasetAutoplayPending = \(shouldAutoplay ? "true" : "false");"
    }

    nonisolated static func pageBootstrapScript(
        isRestoringPlaybackSession: Bool,
        targetVolume: Double,
        documentGeneration: UInt64,
        nativePlaybackGeneration: UInt64 = 0
    ) -> String {
        self.pageBootstrapScript(
            shouldAutoplay: !isRestoringPlaybackSession,
            targetVolume: targetVolume,
            documentGeneration: documentGeneration,
            nativePlaybackGeneration: nativePlaybackGeneration
        )
    }

    nonisolated static func pageBootstrapScript(
        shouldAutoplay: Bool,
        targetVolume: Double,
        documentGeneration _: UInt64,
        nativePlaybackGeneration: UInt64 = 0
    ) -> String {
        let clampedVolume = if targetVolume.isFinite {
            min(max(targetVolume, 0), 1)
        } else {
            1.0
        }

        return """
            (function() {
                try {
                    const queryGeneration = new URLSearchParams(window.location.search)
                        .get('\(WebPlaybackDocumentGeneration.urlQueryKey)');
                    const fragmentGeneration = new URLSearchParams(
                        window.location.hash.replace(/^#/, '')
                    ).get('\(WebPlaybackDocumentGeneration.urlQueryKey)');
                    const rawGeneration = queryGeneration || fragmentGeneration;
                    const parsedGeneration = rawGeneration === null || rawGeneration === ''
                        ? Number.NaN
                        : Number(rawGeneration);
                    window.__kasetDocumentGeneration =
                        Number.isSafeInteger(parsedGeneration) && parsedGeneration >= 0
                            ? parsedGeneration
                            : -1;
                } catch (e) {
                    window.__kasetDocumentGeneration = -1;
                }
            })();
            window.__kasetNativePlaybackGeneration = \(nativePlaybackGeneration);
            \(Self.autoplayIntentScript(shouldAutoplay: shouldAutoplay))
            window.__kasetPlaybackSuppressed = \(shouldAutoplay ? "false" : "true");
            window.__kasetResumeAdOnly = false;
            if (!window.__kasetPlaybackSuppressionInstalled) {
                window.__kasetPlaybackSuppressionInstalled = true;
                document.addEventListener('play', function(event) {
                    if (!window.__kasetPlaybackSuppressed) return;
                    const media = event.target;
                    if (media && typeof media.pause === 'function') media.pause();
                }, true);
            }
            window.__kasetAutoplayAttempts = 0;
            window.__kasetAutoplayRetryScheduled = false;
            window.__kasetTargetVolume = \(clampedVolume);
        """
    }

    nonisolated static func playbackURL(videoId: String, documentGeneration: UInt64) -> URL? {
        var components = URLComponents(string: "https://music.youtube.com/watch")
        components?.queryItems = [
            URLQueryItem(name: "v", value: videoId),
            URLQueryItem(
                name: WebPlaybackDocumentGeneration.urlQueryKey,
                value: String(documentGeneration)
            ),
        ]
        components?.fragment = "\(WebPlaybackDocumentGeneration.urlQueryKey)=\(documentGeneration)"
        return components?.url
    }

    private func installUserScripts(
        on contentController: WKUserContentController,
        shouldAutoplay: Bool,
        targetVolume: Double,
        documentGeneration: UInt64,
        nativePlaybackGeneration: UInt64
    ) {
        contentController.removeAllUserScripts()

        // Autoplay intent must exist before media lifecycle events like `canplay`.
        // `didFinish` is too late on fast or cached player loads.
        let pageBootstrapScript = WKUserScript(
            source: Self.pageBootstrapScript(
                shouldAutoplay: shouldAutoplay,
                targetVolume: targetVolume,
                documentGeneration: documentGeneration,
                nativePlaybackGeneration: nativePlaybackGeneration
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(pageBootstrapScript)

        // Keep the page preference in sync before any page script reads localStorage.
        let mediaControlBootstrapScript = WKUserScript(
            source: self.mediaControlBootstrapScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(mediaControlBootstrapScript)

        let playbackAudioQualityBootstrapScript = WKUserScript(
            source: self.playbackAudioQualityBootstrapScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(playbackAudioQualityBootstrapScript)

        // Inject mediaSession override at document end without allowing duplicate RAF loops.
        let mediaOverrideScript = WKUserScript(
            source: Self.mediaControlOverrideScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(mediaOverrideScript)

        // Apply preferred playback audio quality at document end and after player recreation.
        let playbackAudioQualityOverrideScript = WKUserScript(
            source: Self.playbackAudioQualityOverrideScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(playbackAudioQualityOverrideScript)

        // Inject observer script (at document end)
        let script = WKUserScript(
            source: Self.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(script)
    }

    func refreshInstalledUserScripts() {
        guard let webView else { return }

        let currentVolume = self.coordinator?.playerService.volume ?? 1.0
        let shouldAutoplay = self.coordinator?.playerService.shouldAutoplayPlaybackDocument ?? false
        self.installUserScripts(
            on: webView.configuration.userContentController,
            shouldAutoplay: shouldAutoplay,
            targetVolume: currentVolume,
            documentGeneration: Self.userScriptDocumentGeneration(from: self.documentGeneration),
            nativePlaybackGeneration: self.coordinator?.playerService
                .currentNativeMusicPlaybackGeneration ?? 0
        )
    }

    func setNativePlaybackGeneration(_ generation: UInt64) {
        self.webView?.evaluateJavaScript(
            "window.__kasetNativePlaybackGeneration = \(generation);",
            completionHandler: nil
        )
    }
}

extension SingletonPlayerWebView {
    struct ContentProcessRecoveryPlan: Equatable {
        let shouldReload: Bool
        let pendingSeek: TimeInterval?
        let shouldAutoResume: Bool
    }

    /// Cancels every outstanding music navigation and makes any surviving
    /// document inert. Used by explicit stop so a late commit/canplay callback
    /// cannot resurrect playback after native state has been cleared.
    func cancelPendingPlayback() async {
        self.loadGeneration &+= 1
        self.invalidateDocumentNavigationState()
        self.currentVideoId = nil
        guard let webView else { return }
        webView.stopLoading()
        _ = try? await webView.evaluateJavaScript("""
            window.__kasetAutoplayPending = false;
            window.__kasetAutoplayAttempts = 0;
            window.__kasetAutoplayRetryScheduled = false;
            \(WebPlaybackDocumentGeneration.mediaSuppressionScript)
        """)
    }

    nonisolated static func userScriptDocumentGeneration(
        from documentGeneration: WebPlaybackDocumentGeneration
    ) -> UInt64 {
        documentGeneration.userScriptGeneration
    }

    nonisolated static func acceptsBridgeMessage(
        sourceWebView: AnyObject?,
        currentWebView: AnyObject?,
        documentGeneration: WebPlaybackDocumentGeneration,
        rawDocumentGeneration: Any?
    ) -> Bool {
        guard let sourceWebView,
              let currentWebView,
              sourceWebView === currentWebView
        else { return false }
        return documentGeneration.accepts(rawGeneration: rawDocumentGeneration)
    }

    nonisolated static func isCurrentBridgeWebView(
        sourceWebView: AnyObject?,
        currentWebView: AnyObject?
    ) -> Bool {
        guard let sourceWebView, let currentWebView else { return false }
        return sourceWebView === currentWebView
    }

    nonisolated static func acceptsBridgeSource(
        isMainFrame: Bool,
        sourceScheme: String,
        sourceHost: String
    ) -> Bool {
        isMainFrame && sourceScheme == "https" && sourceHost == "music.youtube.com"
    }

    nonisolated static func acceptsMainFrameResponse(
        _ response: URLResponse,
        expectedVideoID: String?,
        documentGeneration: WebPlaybackDocumentGeneration
    ) -> Bool {
        WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            response,
            expectedHost: "music.youtube.com",
            expectedVideoID: expectedVideoID,
            allowsInternalBlank: documentGeneration.ownsBlankNavigation(response.url)
        )
    }

    nonisolated static func isAuthoritativePlaybackSample(
        hasReadyMedia: Bool,
        isShowingAd: Bool
    ) -> Bool {
        hasReadyMedia && !isShowingAd
    }

    nonisolated static func contentProcessRecoveryPlan(
        state: PlayerService.PlaybackState,
        progress: TimeInterval,
        isShowingAd: Bool,
        lastNonAdContentProgress: TimeInterval,
        isPendingRestoredLoadDeferred: Bool = false
    ) -> ContentProcessRecoveryPlan {
        guard !isPendingRestoredLoadDeferred else {
            return ContentProcessRecoveryPlan(
                shouldReload: false,
                pendingSeek: nil,
                shouldAutoResume: false
            )
        }
        let shouldReload = switch state {
        case .loading, .playing, .buffering, .paused:
            true
        case .idle, .ended, .error:
            false
        }
        let shouldAutoResume = switch state {
        case .loading, .playing, .buffering:
            true
        case .idle, .paused, .ended, .error:
            false
        }
        let pendingSeek: TimeInterval? = if !shouldReload || state == .loading {
            nil
        } else if isShowingAd {
            lastNonAdContentProgress > 0 ? lastNonAdContentProgress : nil
        } else {
            progress
        }
        return ContentProcessRecoveryPlan(
            shouldReload: shouldReload,
            pendingSeek: pendingSeek,
            shouldAutoResume: shouldAutoResume
        )
    }
}

extension SingletonPlayerWebView {
    func invalidateDocumentNavigationState() {
        for (identifier, navigation) in self.documentNavigations {
            self.cancelledDocumentNavigations[identifier] = WebPlaybackCancelledNavigation(
                generation: navigation.generation,
                shouldReportFailure: true
            )
        }
        self.documentGeneration.invalidate()
        self.documentNavigationStartedAtMilliseconds = nil
        self.documentNavigations.removeAll()
        self.continuationGenerationsAwaitingStart.removeAll()
    }

    func beginBlankDocumentNavigation() -> URL? {
        self.documentNavigations.removeAll()
        self.continuationGenerationsAwaitingStart.removeAll()
        let generation = self.documentGeneration.beginBlankNavigation()
        return WebPlaybackDocumentGeneration.blankURL(generation: generation)
    }

    func recordAcceptedMainFrameResponse(_ response: URLResponse) {
        guard let currentVideoId = self.currentVideoId else { return }
        _ = self.documentGeneration.recordSuccessfulPlaybackResponse(
            url: response.url,
            host: "music.youtube.com",
            videoID: currentVideoId
        )
    }

    func decideNavigationPolicy(
        webView: WKWebView,
        navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }

        if WebPlaybackDocumentGeneration.isInternalBlankNavigation(navigationAction.request.url) {
            decisionHandler(
                self.documentGeneration.ownsBlankNavigation(navigationAction.request.url)
                    ? .allow
                    : .cancel
            )
            return
        }

        if WebPlaybackDocumentGeneration.isFragmentOnlyNavigation(
            from: webView.url,
            to: navigationAction.request.url
        ) {
            self.webKitManager?.extensionHostWebViewWillNavigate(
                webView,
                to: navigationAction.request.url
            )
            decisionHandler(.allow)
            return
        }

        if self.documentGeneration.pendingGeneration != nil {
            decisionHandler(.cancel)
            return
        }

        if let inFlightGeneration = self.documentGeneration.inFlightGeneration {
            guard WebPlaybackDocumentGeneration.requestBelongsToNavigationChain(
                navigationAction.request,
                currentURL: webView.url,
                generation: inFlightGeneration,
                playbackHost: "music.youtube.com",
                committedIntermediaryGeneration: self.documentGeneration.committedIntermediaryGeneration
            ) else {
                decisionHandler(.cancel)
                return
            }
            if WebPlaybackDocumentGeneration.generation(from: navigationAction.request.url)
                != inFlightGeneration
            {
                decisionHandler(.cancel)
                self.continuationGenerationsAwaitingStart.insert(inFlightGeneration)
                if let boundRequest = WebPlaybackDocumentGeneration.requestByBindingGeneration(
                    navigationAction.request,
                    generation: inFlightGeneration
                ) {
                    Task { @MainActor in
                        self.startBoundNavigationContinuation(
                            on: webView,
                            request: boundRequest,
                            generation: inFlightGeneration
                        )
                    }
                }
                return
            }
            self.webKitManager?.extensionHostWebViewWillNavigate(
                webView,
                to: navigationAction.request.url
            )
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)
    }

    func startDocumentNavigation(
        on webView: WKWebView,
        request: URLRequest,
        generation: UInt64
    ) {
        guard webView === self.webView else {
            if self.documentGeneration.pendingGeneration == generation {
                self.handlePendingDocumentNavigationFailure(webView: self.webView)
            }
            return
        }
        guard self.documentGeneration.startNavigation(generation) else { return }
        guard let navigation = webView.load(request) else {
            self.handleCurrentDocumentNavigationFailure(generation, webView: webView)
            return
        }
        self.documentNavigations[ObjectIdentifier(navigation)] = WebPlaybackTrackedNavigation(
            generation: generation
        )
    }

    func startBoundNavigationContinuation(
        on webView: WKWebView,
        request: URLRequest,
        generation: UInt64
    ) {
        guard webView === self.webView,
              self.documentGeneration.inFlightGeneration == generation,
              self.documentGeneration.pendingGeneration == nil
        else {
            self.continuationGenerationsAwaitingStart.remove(generation)
            return
        }
        guard let navigation = webView.load(request) else {
            self.continuationGenerationsAwaitingStart.remove(generation)
            self.handleCurrentDocumentNavigationFailure(generation, webView: webView)
            return
        }
        self.documentNavigations[ObjectIdentifier(navigation)] = WebPlaybackTrackedNavigation(
            generation: generation
        )
        self.continuationGenerationsAwaitingStart.remove(generation)
    }

    func cancelActiveDocumentNavigation(on webView: WKWebView) {
        guard let generation = self.documentGeneration.inFlightGeneration else { return }
        for (identifier, navigation) in self.documentNavigations
            where navigation.generation == generation
        {
            self.cancelledDocumentNavigations[identifier] = WebPlaybackCancelledNavigation(
                generation: generation,
                shouldReportFailure: false
            )
        }
        self.documentNavigations = self.documentNavigations.filter {
            $0.value.generation != generation
        }
        _ = self.documentGeneration.cancelInFlightNavigation(generation)
        self.continuationGenerationsAwaitingStart.remove(generation)
        webView.stopLoading()
    }

    func trackDocumentNavigationStart(_ navigation: WKNavigation?, webView: WKWebView) {
        guard webView === self.webView,
              let navigation,
              self.documentNavigations[ObjectIdentifier(navigation)] == nil,
              let generation = WebPlaybackDocumentGeneration.generation(from: webView.url)
              ?? (self.documentGeneration.committedIntermediaryGeneration
                  == self.documentGeneration.inFlightGeneration
                  && WebPlaybackDocumentGeneration.isAllowedPlaybackNavigationURL(
                      webView.url,
                      playbackHost: "music.youtube.com"
                  ) ? self.documentGeneration.inFlightGeneration : nil),
              generation == self.documentGeneration.inFlightGeneration
        else { return }
        self.documentNavigations[ObjectIdentifier(navigation)] = WebPlaybackTrackedNavigation(
            generation: generation
        )
    }

    func handleDocumentNavigationStart(_ navigation: WKNavigation?, webView: WKWebView) {
        self.trackDocumentNavigationStart(navigation, webView: webView)
        self.webKitManager?.extensionHostWebViewDidStartNavigation(webView)
    }

    func handleDocumentNavigationRedirect(_ navigation: WKNavigation?, webView: WKWebView) {
        guard webView === self.webView,
              let navigation,
              let trackedNavigation = self.documentNavigations[ObjectIdentifier(navigation)],
              trackedNavigation.generation == self.documentGeneration.inFlightGeneration,
              self.documentGeneration.pendingGeneration == nil
        else { return }
        self.refreshInstalledUserScripts()
    }

    func commitDocumentNavigation(_ navigation: WKNavigation?, webView: WKWebView) {
        guard webView === self.webView else { return }
        if let navigation,
           let cancelledNavigation = self.cancelledDocumentNavigations[ObjectIdentifier(navigation)]
        {
            if WebPlaybackDocumentGeneration.shouldSuppressCancelledNavigationCommit(
                cancelledGeneration: cancelledNavigation.generation,
                committedURL: webView.url,
                pendingGeneration: self.documentGeneration.pendingGeneration,
                inFlightGeneration: self.documentGeneration.inFlightGeneration,
                currentGeneration: self.documentGeneration.currentGeneration
            ) {
                let replacementGeneration = self.documentGeneration.pendingGeneration
                    ?? self.documentGeneration.inFlightGeneration
                if let replacementGeneration,
                   replacementGeneration != cancelledNavigation.generation
                {
                    self.suppressSurvivingDocumentMedia(webView)
                } else {
                    self.pauseSurvivingDocument(webView)
                }
            }
            return
        }
        if WebPlaybackDocumentGeneration.isInternalBlankNavigation(webView.url) {
            guard self.documentGeneration.ownsBlankNavigation(webView.url) else {
                self.handleUnexpectedBlankDocumentCommit(navigation, webView: webView)
                return
            }
            return
        }
        guard let navigation,
              var trackedNavigation = self.documentNavigations[ObjectIdentifier(navigation)]
        else { return }
        trackedNavigation.didCommit = true
        if let currentVideoId = self.currentVideoId,
           WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
               webView.url,
               host: "music.youtube.com",
               videoID: currentVideoId
           )
        {
            guard self.documentGeneration.commitNavigation(
                trackedNavigation.generation,
                expectedVideoID: currentVideoId
            ) else { return }
            self.documentNavigationStartedAtMilliseconds = nil
            trackedNavigation.didActivatePlaybackOrigin = true
        } else if WebPlaybackDocumentGeneration.isTrustedIntermediaryURL(webView.url) {
            guard self.documentGeneration.commitIntermediaryNavigation(
                trackedNavigation.generation
            ) else { return }
        }
        self.documentNavigations[ObjectIdentifier(navigation)] = trackedNavigation
        if trackedNavigation.didActivatePlaybackOrigin {
            self.syncAutoplayIntent(on: webView)
        }
    }

    func consumeCancelledDocumentNavigation(
        _ navigation: WKNavigation?
    ) -> WebPlaybackCancelledNavigation? {
        guard let navigation else { return nil }
        return self.cancelledDocumentNavigations.removeValue(
            forKey: ObjectIdentifier(navigation)
        )
    }

    func syncAutoplayIntent(on webView: WKWebView) {
        let generation = self.documentGeneration.currentGeneration
        guard self.documentGeneration.accepts(generation: generation) else { return }
        let shouldAutoplay = self.coordinator?.playerService.shouldAutoplayPlaybackDocument ?? false
        let nativePlaybackGeneration = self.coordinator?.playerService
            .currentNativeMusicPlaybackGeneration ?? 0
        let script = Self.autoplayIntentSynchronizationScript(
            shouldAutoplay: shouldAutoplay,
            nativePlaybackGeneration: nativePlaybackGeneration,
            documentGeneration: generation
        )
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.logger.debug("Autoplay intent synchronization deferred: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func autoplayIntentSynchronizationScript(
        shouldAutoplay: Bool,
        nativePlaybackGeneration: UInt64,
        documentGeneration: UInt64
    ) -> String {
        """
        (function() {
            if (window.__kasetDocumentGeneration !== \(documentGeneration)) return 'stale';
            window.__kasetNativePlaybackGeneration = \(nativePlaybackGeneration);
            window.__kasetAutoplayPending = \(shouldAutoplay ? "true" : "false");
            window.__kasetPlaybackSuppressed = \(shouldAutoplay ? "false" : "true");
            if (window.__kasetAutoplayPending) {
                window.__kasetAutoplayAttempts = 0;
                window.__kasetAutoplayRetryScheduled = false;
            }
            if (!window.__kasetAutoplayPending) { document.querySelector('video')?.pause(); }
            return 'synced';
        })();
        """
    }

    func finishDocumentNavigation(_ navigation: WKNavigation?, webView: WKWebView) -> Bool {
        guard webView === self.webView else { return false }
        if WebPlaybackDocumentGeneration.isInternalBlankNavigation(webView.url) {
            guard self.documentGeneration.ownsBlankNavigation(webView.url) else {
                self.handleUnexpectedBlankDocumentCommit(navigation, webView: webView)
                return false
            }
            return true
        }
        guard let navigation,
              let trackedNavigation = self.documentNavigations.removeValue(
                  forKey: ObjectIdentifier(navigation)
              )
        else { return false }
        guard trackedNavigation.didCommit else {
            self.handleCurrentDocumentNavigationFailure(
                trackedNavigation.generation,
                webView: webView
            )
            return false
        }
        if !trackedNavigation.didActivatePlaybackOrigin {
            return WebPlaybackDocumentGeneration.isAllowedPlaybackNavigationURL(
                webView.url,
                playbackHost: "music.youtube.com"
            ) && trackedNavigation.generation == self.documentGeneration.inFlightGeneration
        }
        guard self.documentGeneration.canFinishNavigation(
            trackedNavigation.generation
        ) else { return false }
        return true
    }

    func handleUnexpectedBlankDocumentCommit(
        _ navigation: WKNavigation?,
        webView: WKWebView
    ) {
        guard webView === self.webView else { return }
        if let navigation,
           self.documentNavigations[ObjectIdentifier(navigation)] != nil
        {
            self.failDocumentNavigation(navigation, webView: webView)
            return
        }
        if let generation = self.documentGeneration.inFlightGeneration {
            self.documentNavigations = self.documentNavigations.filter {
                $0.value.generation != generation
            }
            self.continuationGenerationsAwaitingStart.remove(generation)
            self.handleCurrentDocumentNavigationFailure(generation, webView: webView)
        } else if self.documentGeneration.pendingGeneration != nil {
            self.handlePendingDocumentNavigationFailure(webView: webView)
        } else if self.currentVideoId != nil {
            self.handleCommittedDocumentNavigationFailure(
                self.documentGeneration.currentGeneration,
                webView: webView
            )
        }
    }

    func handleDocumentNavigationFinish(_ navigation: WKNavigation?, webView: WKWebView) -> Bool {
        guard self.finishDocumentNavigation(navigation, webView: webView) else { return false }
        self.webKitManager?.extensionHostWebViewDidFinishNavigation(webView)
        return true
    }

    func failDocumentNavigation(_ navigation: WKNavigation?, webView: WKWebView) {
        if let navigation {
            self.cancelledDocumentNavigations.removeValue(forKey: ObjectIdentifier(navigation))
        }
        guard webView === self.webView,
              let navigation,
              let trackedNavigation = self.documentNavigations.removeValue(
                  forKey: ObjectIdentifier(navigation)
              )
        else { return }
        if trackedNavigation.didActivatePlaybackOrigin {
            self.handleCommittedDocumentNavigationFailure(
                trackedNavigation.generation,
                webView: webView
            )
        } else {
            self.handleCurrentDocumentNavigationFailure(
                trackedNavigation.generation,
                webView: webView
            )
        }
    }

    func handleCurrentDocumentNavigationFailure(_ generation: UInt64, webView: WKWebView?) {
        guard self.documentGeneration.cancelInFlightNavigation(generation) else { return }
        self.pauseSurvivingDocument(webView)
        self.currentVideoId = nil
        self.documentGeneration.invalidate()
        self.coordinator?.playerService.deferRestoredPlaybackAfterNavigationFailure()
        self.refreshInstalledUserScripts()
    }

    func handlePendingDocumentNavigationFailure(webView: WKWebView?) {
        self.documentGeneration.cancelPendingNavigation()
        self.pauseSurvivingDocument(webView)
        self.currentVideoId = nil
        self.documentGeneration.invalidate()
        self.coordinator?.playerService.deferRestoredPlaybackAfterNavigationFailure()
        self.refreshInstalledUserScripts()
    }

    func handleCommittedDocumentNavigationFailure(_ generation: UInt64, webView: WKWebView?) {
        guard self.documentGeneration.currentGeneration == generation,
              self.documentGeneration.pendingGeneration == nil,
              self.documentGeneration.inFlightGeneration == nil
        else { return }
        self.pauseSurvivingDocument(webView)
        self.currentVideoId = nil
        self.documentGeneration.invalidate()
        self.coordinator?.playerService.deferRestoredPlaybackAfterNavigationFailure()
        self.refreshInstalledUserScripts()
    }

    func pauseSurvivingDocument(_ webView: WKWebView?) {
        webView?.stopLoading()
        self.suppressSurvivingDocumentMedia(webView)
    }

    func suppressSurvivingDocumentMedia(_ webView: WKWebView?) {
        webView?.evaluateJavaScript("""
            window.__kasetAutoplayPending = false;
            window.__kasetAutoplayAttempts = 0;
            window.__kasetAutoplayRetryScheduled = false;
            \(WebPlaybackDocumentGeneration.mediaSuppressionScript)
        """, completionHandler: nil)
    }

    func handleDocumentNavigationFailure(
        _ navigation: WKNavigation?,
        webView: WKWebView,
        error: Error
    ) {
        if WebPlaybackNavigationFailure.isRetryableCancellation(error) {
            guard let navigation,
                  let trackedNavigation = self.documentNavigations[ObjectIdentifier(navigation)]
            else {
                if let navigation,
                   let cancelledNavigation = self.cancelledDocumentNavigations.removeValue(
                       forKey: ObjectIdentifier(navigation)
                   )
                {
                    if cancelledNavigation.shouldReportFailure {
                        self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                    }
                    return
                }
                self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                return
            }
            let hasSameGenerationSuccessor = self.documentNavigations.contains { key, candidate in
                key != ObjectIdentifier(navigation)
                    && candidate.generation == trackedNavigation.generation
            }
            if !trackedNavigation.didActivatePlaybackOrigin,
               hasSameGenerationSuccessor
               || self.continuationGenerationsAwaitingStart.contains(trackedNavigation.generation)
            {
                self.documentNavigations.removeValue(forKey: ObjectIdentifier(navigation))
                self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                return
            }
        }
        self.failDocumentNavigation(navigation, webView: webView)
        self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
    }

    func recoverFromContentProcessTermination(webView: WKWebView) {
        guard webView === self.webView else { return }
        DiagnosticsLogger.player.error("Singleton WebView content process terminated, attempting recovery")
        self.invalidateDocumentNavigationState()
        self.cancelledDocumentNavigations.removeAll()

        guard let playerService = self.coordinator?.playerService else {
            if let blankURL = self.beginBlankDocumentNavigation() {
                webView.load(URLRequest(url: blankURL))
            }
            return
        }
        guard !playerService.isStoppingPlayback else {
            self.currentVideoId = nil
            return
        }
        let videoId = playerService.pendingPlayVideoId
            ?? playerService.currentTrack?.videoId
            ?? self.currentVideoId
        guard let videoId else {
            if let blankURL = self.beginBlankDocumentNavigation() {
                webView.load(URLRequest(url: blankURL))
            }
            return
        }

        let recoveryPlan = Self.contentProcessRecoveryPlan(
            state: playerService.state,
            progress: playerService.progress,
            isShowingAd: playerService.isShowingAd,
            lastNonAdContentProgress: playerService.lastNonAdContentProgress(for: videoId),
            isPendingRestoredLoadDeferred: playerService.isPendingRestoredLoadDeferred
        )
        guard recoveryPlan.shouldReload else {
            self.currentVideoId = nil
            return
        }

        let preservedRestoredSeek = playerService.pendingRestoredSeekForWebRecovery(
            videoId: videoId
        )
        let shouldAutoResume = if playerService.isRestoringPlaybackSession
            || playerService.isPendingRestoredLoadDeferred
        {
            playerService.shouldAutoResumeAfterRestoredLoad
        } else {
            recoveryPlan.shouldReload && playerService.shouldResumeAfterInterruption
        }
        playerService.pendingRestoredSeek = preservedRestoredSeek ?? recoveryPlan.pendingSeek
        playerService.beginRestoredPlaybackLoad(autoResumeAfterSeek: shouldAutoResume)
        self.loadVideo(videoId: videoId, strategy: .forceFullPageWhenSameVideoId)
    }
}
