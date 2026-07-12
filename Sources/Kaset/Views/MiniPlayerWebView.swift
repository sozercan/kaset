// swiftlint:disable file_length
import os
import SwiftUI
import WebKit

// MARK: - WebPlaybackIdentityTransition

enum WebPlaybackIdentityTransition {
    static func isConfirmed(
        observedVideoId: String?,
        lastAcceptedObservedVideoId: String?,
        expectedVideoIdBeforeReconciliation: String?
    ) -> Bool {
        guard let observedVideoId else { return false }
        if let lastAcceptedObservedVideoId {
            return observedVideoId != lastAcceptedObservedVideoId
        }
        guard let expectedVideoIdBeforeReconciliation else { return false }
        return observedVideoId != expectedVideoIdBeforeReconciliation
    }

    static func shouldAcceptMediaState(
        queueEntryChanged: Bool,
        observerEpoch: Double,
        lastAcceptedObserverEpoch: Double?,
        mediaGeneration: Int,
        lastAcceptedMediaGeneration: Int?
    ) -> Bool {
        guard self.isObservationOrdered(
            observerEpoch: observerEpoch,
            lastAcceptedObserverEpoch: lastAcceptedObserverEpoch,
            mediaGeneration: mediaGeneration,
            lastAcceptedMediaGeneration: lastAcceptedMediaGeneration
        ) else {
            return false
        }
        guard let lastAcceptedObserverEpoch else { return true }
        if observerEpoch > lastAcceptedObserverEpoch {
            return true
        }
        guard let lastAcceptedMediaGeneration else { return true }
        if mediaGeneration < lastAcceptedMediaGeneration {
            return false
        }
        return !queueEntryChanged || mediaGeneration > lastAcceptedMediaGeneration
    }

    static func isObservationOrdered(
        observerEpoch: Double,
        lastAcceptedObserverEpoch: Double?,
        mediaGeneration: Int,
        lastAcceptedMediaGeneration: Int?
    ) -> Bool {
        guard let lastAcceptedObserverEpoch else { return true }
        if observerEpoch < lastAcceptedObserverEpoch {
            return false
        }
        if observerEpoch > lastAcceptedObserverEpoch {
            return true
        }
        guard let lastAcceptedMediaGeneration else { return true }
        return mediaGeneration >= lastAcceptedMediaGeneration
    }

    static func shouldAcceptEndedOccurrence(
        observerEpoch: Double,
        lastHandledObserverEpoch: Double?,
        mediaGeneration: Int,
        lastHandledMediaGeneration: Int?
    ) -> Bool {
        guard let lastHandledObserverEpoch else { return true }
        if observerEpoch < lastHandledObserverEpoch {
            return false
        }
        if observerEpoch > lastHandledObserverEpoch {
            return true
        }
        guard let lastHandledMediaGeneration else { return true }
        return mediaGeneration > lastHandledMediaGeneration
    }

    static func shouldHandleDeferredIdentitylessObservation(
        isDeferred: Bool,
        observedVideoId: String?,
        mediaVideoId: String?
    ) -> Bool {
        isDeferred && observedVideoId == nil && mediaVideoId == nil
    }

    static func didQueueEntryChange(
        hasBaseline: Bool,
        lastAcceptedQueueEntryID: UUID?,
        currentQueueEntryID: UUID?
    ) -> Bool {
        hasBaseline && lastAcceptedQueueEntryID != currentQueueEntryID
    }
}

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
final class SingletonPlayerWebView { // swiftlint:disable:this type_body_length
    private struct PendingRouterNavigation {
        let videoId: String
        let fallbackURL: URL
        let generation: Int
    }

    static let shared = SingletonPlayerWebView()

    private(set) var webView: WKWebView?
    weak var webKitManager: WebKitManager?
    private weak var currentContainer: NSView?
    private var usesCookieFreeDataStore: Bool?
    var currentVideoId: String?
    var coordinator: Coordinator?
    let logger = DiagnosticsLogger.player
    private var loadGeneration = 0
    private var pendingRouterNavigation: PendingRouterNavigation?
    private var documentIDGeneration = 0
    var pendingDocumentID: Int?
    var activeDocumentNavigation: WKNavigation?
    var activeDocumentNavigationID: Int?
    var isDocumentNavigationInProgress = false

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
    var mediaControlUsesNextPrev: Bool
    var playbackAudioQuality: SettingsManager.PlaybackAudioQuality
    private var hasStartedHomePreload = false

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

        let shouldBlockAutoplay = playerService.isRestoringPlaybackSession
            || playerService.isPendingRestoredLoadDeferred
            || playerService.pendingPlayVideoId == nil

        self.installUserScripts(
            on: configuration.userContentController,
            shouldBlockAutoplay: shouldBlockAutoplay,
            targetVolume: playerService.volume
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
        self.preloadHomePageIfNeeded()
        return newWebView
    }

    private func preloadHomePageIfNeeded() {
        guard !UITestConfig.isRunningUnitTests else { return }
        guard !self.hasStartedHomePreload else { return }
        guard self.currentVideoId == nil else { return }
        guard let webView else { return }
        guard let homeURL = URL(string: "https://music.youtube.com/") else {
            self.logger.error("Unable to construct YT Music home URL")
            return
        }

        self.hasStartedHomePreload = true
        self.logger.info("Preloading YT Music home page")
        webView.load(URLRequest(url: homeURL))
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
        guard let webView else { return }
        self.logger.info("Tearing down singleton music WebView")
        self.loadGeneration += 1
        self.pendingRouterNavigation = nil
        self.pendingDocumentID = nil
        self.activeDocumentNavigation = nil
        self.activeDocumentNavigationID = nil
        self.isDocumentNavigationInProgress = false
        self.currentVideoId = nil
        webView.evaluateJavaScript("document.querySelector('video')?.pause()", completionHandler: nil)
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        self.webKitManager?.extensionHostWebViewDidDeactivate(role: .musicPlayer)
        self.webView = nil
        self.coordinator?.cancelPlaybackBridgeTasks()
        self.coordinator = nil
        self.currentContainer = nil
        self.usesCookieFreeDataStore = nil
        self.hasStartedHomePreload = false
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
                self.logger.debug("Video \(videoId) already loaded, skipping routing and playing")
                self.play()
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

        guard let urlToLoad = Self.youtubeMusicWatchURL(videoId: videoId) else {
            self.logger.error("Unable to construct YouTube Music watch URL")
            return
        }

        if videoId != previousVideoId {
            self.logger.info("Loading video: \(videoId) (was: \(previousVideoId ?? "none"))")
        }

        // Update currentVideoId immediately to prevent duplicate loads
        self.currentVideoId = videoId
        self.loadGeneration &+= 1
        let generation = self.loadGeneration
        self.pendingRouterNavigation = nil

        // Get current volume from PlayerService via coordinator
        let currentVolume = self.coordinator?.playerService.volume ?? 1.0
        let isRestoringPlaybackSession = self.coordinator?.playerService.isRestoringPlaybackSession ?? false
        self.logger.info("Will apply volume \(currentVolume) after page load")

        self.installUserScripts(
            on: webView.configuration.userContentController,
            shouldBlockAutoplay: isRestoringPlaybackSession,
            targetVolume: currentVolume
        )

        // Prefer in-page router navigation when the shell is already loaded.
        // For a forced full-page navigation (e.g. an identity-switch reload), skip pausing the
        // OLD <video>: the navigation tears it down anyway, and the pause event would emit a
        // stale STATE_UPDATE from the outgoing page that can be mis-reconciled against a restored
        // session before the new document loads.
        let skipPrenavPause = (strategy == .forceFullPageWhenSameVideoId && videoId == previousVideoId)
        if skipPrenavPause {
            webView.evaluateJavaScript("window.__kasetTargetVolume = \(currentVolume);", completionHandler: nil)
            webView.load(URLRequest(url: urlToLoad))
            return
        }
        let prenavScript = "document.querySelector('video')?.pause();"
        webView.evaluateJavaScript("\(prenavScript)void 0;") { [weak self] _, _ in
            guard let self, let webView = self.webView else { return }
            guard self.loadGeneration == generation, self.currentVideoId == videoId else { return }

            // Keep the current page's target volume fresh until the new document
            // finishes loading and gets the same value from didFinish.
            let prepareScript = """
            window.__kasetTargetVolume = \(currentVolume);
            window.__kasetAutoplayPending = \(isRestoringPlaybackSession ? "false" : "true");
            window.__kasetBlockAutoplay = \(isRestoringPlaybackSession ? "true" : "false");
            """
            webView.evaluateJavaScript(prepareScript, completionHandler: nil)
            self.navigateViaRouter(videoId: videoId, fallbackURL: urlToLoad, generation: generation)
        }
    }

    nonisolated static func youtubeMusicWatchURL(videoId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: videoId)]
        return components.url
    }

    nonisolated static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return literal
    }

    private func navigateViaRouter(videoId: String, fallbackURL: URL, generation: Int) {
        guard let webView else { return }

        let host = webView.url?.host ?? ""
        guard host == "music.youtube.com" || host == "www.music.youtube.com" else {
            self.logger.debug("Router unavailable (host: \(host, privacy: .public)); falling back to full load")
            self.pendingRouterNavigation = nil
            webView.load(URLRequest(url: fallbackURL))
            return
        }

        let videoIdLiteral = Self.javaScriptStringLiteral(videoId)
        let routerScript = """
        (function() {
            const app = document.querySelector('ytmusic-app');
            if (!app || typeof app.resolveCommand !== 'function') return false;
            try {
                app.resolveCommand({ watchEndpoint: { videoId: \(videoIdLiteral) } });
                return true;
            } catch (_) {
                return false;
            }
        })();
        """

        webView.evaluateJavaScript(routerScript) { [weak self] result, _ in
            guard let self, let webView = self.webView else { return }
            guard self.loadGeneration == generation, self.currentVideoId == videoId else { return }
            let didNavigate = result as? Bool ?? false
            if didNavigate {
                self.logger.info("Router navigation started for video: \(videoId)")
                self.pendingRouterNavigation = PendingRouterNavigation(
                    videoId: videoId,
                    fallbackURL: fallbackURL,
                    generation: generation
                )
                self.scheduleRouterNavigationFallback(
                    videoId: videoId,
                    fallbackURL: fallbackURL,
                    generation: generation
                )
            } else {
                self.logger.info("Router navigation failed for video: \(videoId), using full load")
                self.pendingRouterNavigation = nil
                webView.load(URLRequest(url: fallbackURL))
            }
        }
    }

    func confirmRouterNavigationIfNeeded(videoId: String?) {
        guard let videoId,
              let pendingRouterNavigation = self.pendingRouterNavigation,
              pendingRouterNavigation.videoId == videoId,
              pendingRouterNavigation.generation == self.loadGeneration
        else {
            return
        }

        self.pendingRouterNavigation = nil
        self.logger.debug("Router navigation confirmed for video: \(videoId)")
    }

    private func scheduleRouterNavigationFallback(
        videoId: String,
        fallbackURL: URL,
        generation: Int
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self,
                  let pendingRouterNavigation = self.pendingRouterNavigation,
                  pendingRouterNavigation.videoId == videoId,
                  pendingRouterNavigation.fallbackURL == fallbackURL,
                  pendingRouterNavigation.generation == generation,
                  self.loadGeneration == generation,
                  self.currentVideoId == videoId,
                  let webView = self.webView
            else {
                return
            }

            self.pendingRouterNavigation = nil
            self.logger.warning("Router navigation to \(videoId) was not media-confirmed; using full load")
            webView.load(URLRequest(url: fallbackURL))
        }
    }

    /// Returns the JS snippet that hands the autoplay intent to the freshly loaded
    /// page's window. Restored sessions suppress autoplay so the reconcile path
    /// resumes at the saved seek rather than at 0s.
    nonisolated static func autoplayIntentScript(shouldBlockAutoplay: Bool) -> String {
        """
        window.__kasetAutoplayPending = \(shouldBlockAutoplay ? "false" : "true");
        window.__kasetBlockAutoplay = \(shouldBlockAutoplay ? "true" : "false");
        """
    }

    nonisolated static func pageBootstrapScript(
        shouldBlockAutoplay: Bool,
        targetVolume: Double,
        documentID: Int = 0
    ) -> String {
        let clampedVolume = if targetVolume.isFinite {
            min(max(targetVolume, 0), 1)
        } else {
            1.0
        }

        return """
            \(Self.autoplayIntentScript(shouldBlockAutoplay: shouldBlockAutoplay))
            window.__kasetTargetVolume = \(clampedVolume);
            window.__kasetDocumentID = \(documentID);
        """
    }

    private func installUserScripts(
        on contentController: WKUserContentController,
        shouldBlockAutoplay: Bool,
        targetVolume: Double
    ) {
        contentController.removeAllUserScripts()
        self.documentIDGeneration &+= 1
        let documentID = self.documentIDGeneration
        self.pendingDocumentID = documentID

        // Autoplay intent must exist before media lifecycle events like `canplay`.
        // `didFinish` is too late on fast or cached player loads.
        let pageBootstrapScript = WKUserScript(
            source: Self.pageBootstrapScript(
                shouldBlockAutoplay: shouldBlockAutoplay,
                targetVolume: targetVolume,
                documentID: documentID
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

        let playerService = self.coordinator?.playerService
        let currentVolume = playerService?.volume ?? 1.0
        let shouldBlockAutoplay = playerService?.isRestoringPlaybackSession == true
            || playerService?.isPendingRestoredLoadDeferred == true
            || playerService?.pendingPlayVideoId == nil
        self.installUserScripts(
            on: webView.configuration.userContentController,
            shouldBlockAutoplay: shouldBlockAutoplay,
            targetVolume: currentVolume
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private static let queueNavigationObservationGrace: Duration = .seconds(1)

        let playerService: PlayerService
        private var lastAcceptedObservedVideoId: String?
        private var lastAcceptedObserverEpoch: Double?
        private var lastAcceptedMediaGeneration: Int?
        private var lastHandledEndedObserverEpoch: Double?
        private var lastHandledEndedMediaGeneration: Int?
        private var lastAcceptedQueueEntryID: UUID?
        private var hasAcceptedQueueEntryBaseline = false
        private var documentGeneration = 0
        private var activeDocumentID: Int?
        private var playbackBridgeTask: Task<Void, Never>?
        private var playbackBridgeTaskID: UInt64 = 0
        private var playbackBridgeTailTaskID: UInt64?
        private var playbackBridgeTasks: [UInt64: Task<Void, Never>] = [:]

        init(playerService: PlayerService) {
            self.playerService = playerService
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView === SingletonPlayerWebView.shared.webView,
                  SingletonPlayerWebView.shared.coordinator === self,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            if Self.isDocumentScopedMessage(type) {
                guard let activeDocumentID = self.activeDocumentID,
                      body["documentID"] as? Int == activeDocumentID
                else {
                    return
                }
            }

            let messageGeneration = self.documentGeneration
            let observedVideoId = Self.observedVideoId(from: body)

            switch type {
            case "TRACK_ENDED":
                guard (body["mediaIdentityUncertain"] as? Bool) != true else { return }
                let observerEpoch = body["observerEpoch"] as? Double ?? 0
                let mediaGeneration = body["mediaGeneration"] as? Int ?? 0
                self.enqueuePlaybackBridgeMessage(generation: messageGeneration) { coordinator in
                    guard coordinator.consumeTrackEndedOccurrence(
                        observerEpoch: observerEpoch,
                        mediaGeneration: mediaGeneration
                    ) else {
                        return
                    }
                    await coordinator.playerService.handleTrackEnded(
                        observedVideoId: observedVideoId,
                        shouldContinue: {
                            !Task.isCancelled && coordinator.isCurrentDocument(messageGeneration)
                        }
                    )
                }
            case "REMOTE_NEXT":
                self.enqueuePlaybackBridgeMessage(generation: messageGeneration) { coordinator in
                    await coordinator.playerService.next()
                }
            case "REMOTE_PREVIOUS":
                self.enqueuePlaybackBridgeMessage(generation: messageGeneration) { coordinator in
                    await coordinator.playerService.previous()
                }
            case "AIRPLAY_STATUS":
                self.handleAirPlayStatusUpdate(body: body, messageGeneration: messageGeneration)
            case "LYRICS_LINE":
                self.handleLyricsLineUpdate(body: body, messageGeneration: messageGeneration)
            case "PLAYBACK_AUDIO_QUALITY_STATS":
                Self.logAudioQualityStats(body: body, observedVideoId: observedVideoId)
            case "QUEUE_INJECTION_RESULT":
                self.enqueuePlaybackBridgeMessage(generation: messageGeneration) { coordinator in
                    coordinator.handleQueueInjectionResult(
                        body: body,
                        observedVideoId: observedVideoId
                    )
                }
            case "STATE_UPDATE":
                let mediaVideoId = Self.nonEmptyVideoId(body["mediaVideoId"])
                let observationReceivedAt = ContinuousClock.now
                SingletonPlayerWebView.shared.confirmRouterNavigationIfNeeded(videoId: mediaVideoId)
                self.enqueuePlaybackBridgeMessage(generation: messageGeneration) { coordinator in
                    await coordinator.handleStateUpdate(
                        body: body,
                        observedVideoId: observedVideoId,
                        mediaVideoId: mediaVideoId,
                        observationReceivedAt: observationReceivedAt,
                        messageGeneration: messageGeneration
                    )
                }
            default:
                return
            }
        }

        private func enqueuePlaybackBridgeMessage(
            generation: Int,
            operation: @escaping @MainActor (Coordinator) async -> Void
        ) {
            let previousTask = self.playbackBridgeTask
            self.playbackBridgeTaskID &+= 1
            let taskID = self.playbackBridgeTaskID
            let task = Task { @MainActor [weak self] in
                defer {
                    self?.playbackBridgeTasks[taskID] = nil
                    if self?.playbackBridgeTailTaskID == taskID {
                        self?.playbackBridgeTask = nil
                        self?.playbackBridgeTailTaskID = nil
                    }
                }
                _ = await previousTask?.value
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentDocument(generation)
                else {
                    return
                }
                await operation(self)
            }
            self.playbackBridgeTask = task
            self.playbackBridgeTailTaskID = taskID
            self.playbackBridgeTasks[taskID] = task
        }

        func cancelPlaybackBridgeTasks() {
            for task in self.playbackBridgeTasks.values {
                task.cancel()
            }
            self.playbackBridgeTasks.removeAll()
            self.playbackBridgeTask = nil
            self.playbackBridgeTailTaskID = nil
        }

        private static func isDocumentScopedMessage(_ type: String) -> Bool {
            switch type {
            case "TRACK_ENDED", "REMOTE_NEXT", "REMOTE_PREVIOUS", "AIRPLAY_STATUS", "LYRICS_LINE", "QUEUE_INJECTION_RESULT", "STATE_UPDATE":
                true
            default:
                false
            }
        }

        private func isCurrentDocument(_ generation: Int) -> Bool {
            SingletonPlayerWebView.shared.coordinator === self
                && generation == self.documentGeneration
        }

        private func consumeTrackEndedOccurrence(
            observerEpoch: Double,
            mediaGeneration: Int
        ) -> Bool {
            guard WebPlaybackIdentityTransition.shouldAcceptEndedOccurrence(
                observerEpoch: observerEpoch,
                lastHandledObserverEpoch: self.lastHandledEndedObserverEpoch,
                mediaGeneration: mediaGeneration,
                lastHandledMediaGeneration: self.lastHandledEndedMediaGeneration
            ) else {
                return false
            }
            self.lastHandledEndedObserverEpoch = observerEpoch
            self.lastHandledEndedMediaGeneration = mediaGeneration
            return true
        }

        private static func observedVideoId(from body: [String: Any]) -> String? {
            guard let videoId = body["videoId"] as? String, !videoId.isEmpty else { return nil }
            return videoId
        }

        private func handleAirPlayStatusUpdate(body: [String: Any], messageGeneration: Int) {
            let isConnected = body["isConnected"] as? Bool ?? false
            let wasRequested = body["wasRequested"] as? Bool ?? false

            Task { @MainActor in
                guard self.isCurrentDocument(messageGeneration) else { return }
                self.playerService.updateAirPlayStatus(
                    isConnected: isConnected,
                    wasRequested: wasRequested
                )
            }
        }

        private func handleLyricsLineUpdate(body: [String: Any], messageGeneration: Int) {
            let lineIndex = body["lineIndex"] as? Int ?? -1
            let normalizedLineIndex = lineIndex >= 0 ? lineIndex : nil
            let displayTimeMs = body["timeMs"] as? Int

            Task { @MainActor in
                guard self.isCurrentDocument(messageGeneration) else { return }
                guard self.playerService.currentLyricsLineIndex != normalizedLineIndex ||
                    self.playerService.currentLyricsDisplayTimeMs != displayTimeMs
                else { return }
                self.playerService.currentLyricsLineIndex = normalizedLineIndex
                self.playerService.currentLyricsDisplayTimeMs = displayTimeMs
            }
        }

        private func handleQueueInjectionResult(
            body: [String: Any],
            observedVideoId: String?
        ) {
            guard let observedVideoId else { return }
            let success = body["success"] as? Bool ?? false
            let reason = body["reason"] as? String
            guard let attemptGeneration = body["attemptGeneration"] as? Int else { return }

            self.playerService.handleWebQueueInjectionResult(
                videoId: observedVideoId,
                attemptGeneration: attemptGeneration,
                success: success,
                reason: reason
            )
        }

        private static let allowedAudioQualityStatsKeys: Set<String> = [
            "afmt",
            "audioBitrate",
            "audioCodec",
            "audioCodecs",
            "audioFormat",
            "audioItag",
            "audioMimeType",
            "audioQuality",
            "audio_format",
            "bitrate",
            "codec",
            "codecs",
            "debug_audioFormat",
            "debug_audioQuality",
            "debug_playbackQuality",
            "itag",
            "mimeType",
            "quality",
        ]

        private static let allowedAudioQualityStatsFragments: Set<String> = [
            "bitrate",
            "codec",
            "format",
            "itag",
            "mime",
            "quality",
        ]

        private static func logAudioQualityStats(body: [String: Any], observedVideoId: String?) {
            let message = Self.audioQualityStatsLogMessage(body: body, observedVideoId: observedVideoId)
            DiagnosticsLogger.player.info("Audio quality stats: \(message, privacy: .private)")
        }

        static func audioQualityStatsLogMessage(body: [String: Any], observedVideoId: String?) -> String {
            let preferred = Self.sanitizedLogString(body["preferred"])
            let desired = Self.sanitizedLogString(body["desired"])
            let applied = (body["applied"] as? Bool) == true ? "true" : "false"
            let observed = Self.sanitizedLogString(body["observed"])
            let source = Self.sanitizedLogString(body["source"])
            let videoId = Self.sanitizedLogString(observedVideoId, fallback: "unknown")
            let available = Self.compactJSONText(
                Self.sanitizedPrimitiveArray(body["available"]) ?? [],
                fallback: "[]"
            )
            let stats = Self.compactJSONText(Self.sanitizedStatsForNerds(body["stats"]), fallback: "{}")

            return """
            preferred=\(preferred) desired=\(desired) applied=\(applied) observed=\(observed) \
            source=\(source) videoId=\(videoId) available=\(available) stats=\(stats)
            """
        }

        private static func sanitizedLogString(_ value: Any?, fallback: String = "unknown") -> String {
            guard let value else { return fallback }

            let string: String = if let stringValue = value as? String {
                stringValue
            } else {
                String(describing: value)
            }

            let flattened = string
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")

            guard !flattened.isEmpty else { return fallback }
            return String(flattened.prefix(200))
        }

        private static func compactJSONText(_ value: Any, fallback: String) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else {
                return fallback
            }

            return text
        }

        private static func sanitizedStatsForNerds(_ value: Any?) -> [String: Any] {
            guard let value = value as? [String: Any] else { return [:] }

            var sanitized: [String: Any] = [:]
            for key in value.keys.sorted() where sanitized.count < 12 {
                guard Self.isAllowedAudioQualityStatsKey(key) else { continue }

                let sanitizedKey = String(key.prefix(80))
                if let primitive = Self.sanitizedPrimitive(value[key]) {
                    sanitized[sanitizedKey] = primitive
                    continue
                }

                if let primitiveArray = Self.sanitizedPrimitiveArray(value[key]) {
                    sanitized[sanitizedKey] = primitiveArray
                }
            }

            return sanitized
        }

        private static func isAllowedAudioQualityStatsKey(_ key: String) -> Bool {
            if self.allowedAudioQualityStatsKeys.contains(key) {
                return true
            }

            let lowercasedKey = key.lowercased()
            return lowercasedKey.contains("audio")
                && Self.allowedAudioQualityStatsFragments.contains { lowercasedKey.contains($0) }
        }

        private static func sanitizedPrimitiveArray(_ value: Any?) -> [Any]? {
            guard let values = value as? [Any] else { return nil }

            let sanitized = values.prefix(12).compactMap { Self.sanitizedPrimitive($0) }
            return sanitized.isEmpty ? nil : sanitized
        }

        private static func sanitizedPrimitive(_ value: Any?) -> Any? {
            guard let value else { return nil }

            if let value = value as? String {
                return String(value.prefix(160))
            }

            if let value = value as? Bool {
                return value
            }

            return Self.sanitizedNumericPrimitive(value)
        }

        private static func sanitizedNumericPrimitive(_ value: Any) -> Any? {
            if let value = value as? Int {
                return value
            }

            if let value = value as? Int8 {
                return value
            }

            if let value = value as? Int16 {
                return value
            }

            if let value = value as? Int32 {
                return value
            }

            if let value = value as? Int64 {
                return value
            }

            if let value = value as? UInt {
                return value
            }

            if let value = value as? UInt8 {
                return value
            }

            if let value = value as? UInt16 {
                return value
            }

            if let value = value as? UInt32 {
                return value
            }

            if let value = value as? UInt64 {
                return value
            }

            if let value = value as? Double {
                return value.isFinite ? value : nil
            }

            if let value = value as? Float {
                return value.isFinite ? Double(value) : nil
            }

            if let value = value as? NSNumber {
                return value.doubleValue.isFinite ? value : nil
            }

            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame == true else {
                decisionHandler(.allow)
                return
            }

            SingletonPlayerWebView.shared.webKitManager?.extensionHostWebViewWillNavigate(
                webView,
                to: navigationAction.request.url
            )
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let startedCurrentNavigation = SingletonPlayerWebView.shared.beginDocumentNavigation(
                navigation,
                in: webView
            )
            if startedCurrentNavigation {
                self.playerService.clearWebQueueInjectionState()
            }
            SingletonPlayerWebView.shared.webKitManager?.extensionHostWebViewDidStartNavigation(webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard SingletonPlayerWebView.shared.commitDocumentNavigation(navigation, in: webView) else {
                return
            }
            self.cancelPlaybackBridgeTasks()
            self.activeDocumentID = SingletonPlayerWebView.shared.activeDocumentNavigationID
            self.documentGeneration &+= 1
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let finishedActiveNavigation = SingletonPlayerWebView.shared.finishDocumentNavigation(
                navigation,
                in: webView
            )
            SingletonPlayerWebView.shared.webKitManager?.extensionHostWebViewDidFinishNavigation(webView)
            if finishedActiveNavigation {
                self.playerService.syncWebQueue()
            }
            DiagnosticsLogger.player.info(
                "Singleton WebView finished loading: \(webView.url?.absoluteString ?? "nil")"
            )

            // Apply the current volume when page finishes loading
            // This is critical because YouTube may set its own default volume
            let savedVolume = self.playerService.volume
            let applyVolumeScript = """
                (function() {
                    try {
                        const volume = \(savedVolume);
                        window.__kasetTargetVolume = volume;
                        window.__kasetIsSettingVolume = true;

                        const video = document.querySelector('video');
                        if (video) {
                            video.volume = volume;
                        }

                        // Sync YouTube's internal player APIs if ready
                        const ytVolume = Math.round(volume * 100);
                        const player = document.querySelector('ytmusic-player');
                        if (player && player.playerApi && typeof player.playerApi.setVolume === 'function') {
                            player.playerApi.setVolume(ytVolume);
                        }
                        const moviePlayer = document.getElementById('movie_player');
                        if (moviePlayer && typeof moviePlayer.setVolume === 'function') {
                            moviePlayer.setVolume(ytVolume);
                        }

                        setTimeout(() => { window.__kasetIsSettingVolume = false; }, 100);
                        return video ? 'applied' : 'no-video-yet';
                    } catch (e) {
                         return 'error: ' + e;
                    }
                })();
            """
            let shouldBlockAutoplay = self.playerService.isRestoringPlaybackSession
                || self.playerService.isPendingRestoredLoadDeferred
                || self.playerService.pendingPlayVideoId == nil
            SingletonPlayerWebView.shared.setAutoplayBlocked(shouldBlockAutoplay)

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
                    SingletonPlayerWebView.shared.startLyricsPoll()
                }

                // Re-inject video mode CSS if it was active
                if SingletonPlayerWebView.shared.displayMode == .video {
                    SingletonPlayerWebView.shared.refreshVideoModeCSS()
                    // If refresh fails to find the container (because it's a new page),
                    // it will log a debug message. We should also call the full injection.
                    SingletonPlayerWebView.shared.injectVideoModeCSS()
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError _: Error) {
            let failedActiveNavigation = SingletonPlayerWebView.shared.finishDocumentNavigation(
                navigation,
                in: webView
            )
            SingletonPlayerWebView.shared.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
            if failedActiveNavigation {
                self.playerService.syncWebQueue()
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError _: Error
        ) {
            let failedActiveNavigation = SingletonPlayerWebView.shared.finishDocumentNavigation(
                navigation,
                in: webView
            )
            SingletonPlayerWebView.shared.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
            if failedActiveNavigation {
                self.playerService.syncWebQueue()
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

extension SingletonPlayerWebView.Coordinator {
    // swiftlint:disable:next function_body_length
    func handleStateUpdate(
        body: [String: Any],
        observedVideoId: String?,
        mediaVideoId: String?,
        observationReceivedAt: ContinuousClock.Instant,
        messageGeneration: Int
    ) async {
        let isPlaying = body["isPlaying"] as? Bool ?? false
        let progress = (body["progress"] as? NSNumber)?.doubleValue ?? 0
        let duration = (body["duration"] as? NSNumber)?.doubleValue ?? 0
        let title = body["title"] as? String ?? ""
        let artist = body["artist"] as? String ?? ""
        let thumbnailUrl = body["thumbnailUrl"] as? String ?? ""
        let trackChanged = body["trackChanged"] as? Bool ?? false
        let likeStatus = Self.likeStatus(from: body["likeStatus"] as? String)
        let hasVideo = body["hasVideo"] as? Bool ?? false
        let mediaGeneration = body["mediaGeneration"] as? Int ?? 0
        let observerEpoch = body["observerEpoch"] as? Double ?? 0

        guard self.isCurrentDocument(messageGeneration) else { return }
        guard WebPlaybackIdentityTransition.isObservationOrdered(
            observerEpoch: observerEpoch,
            lastAcceptedObserverEpoch: self.lastAcceptedObserverEpoch,
            mediaGeneration: mediaGeneration,
            lastAcceptedMediaGeneration: self.lastAcceptedMediaGeneration
        ) else {
            return
        }

        let shouldContinuePendingAdvance = await self.playerService
            .reconcilePendingNativeQueueAdvanceObservation(videoId: mediaVideoId)
        guard self.isCurrentDocument(messageGeneration),
              shouldContinuePendingAdvance
        else {
            return
        }

        if WebPlaybackIdentityTransition.shouldHandleDeferredIdentitylessObservation(
            isDeferred: self.playerService.isPendingRestoredLoadDeferred,
            observedVideoId: observedVideoId,
            mediaVideoId: mediaVideoId
        ) {
            self.playerService.updatePlaybackState(
                isPlaying: isPlaying,
                progress: self.playerService.progress,
                duration: self.playerService.duration
            )
            return
        }

        let isWithinQueueNavigationObservationGrace = if let navigationStartedAt = self.playerService
            .protectedQueueNavigationStartedAt
        {
            observationReceivedAt - navigationStartedAt < Self.queueNavigationObservationGrace
        } else {
            false
        }

        // A manual queue load can start before this coordinator accepts any media
        // baseline (initial playback or coordinator recreation). Suppress the
        // immediate outgoing frame, but keep the grace bounded so a persistent
        // wrong-media observation can still trigger the existing recovery path.
        if !self.hasAcceptedQueueEntryBaseline,
           self.playerService.isKasetInitiatedPlayback,
           mediaVideoId != nil,
           !self.playerService.observedPlaybackMatchesCurrentTarget(videoId: mediaVideoId),
           isWithinQueueNavigationObservationGrace
        {
            return
        }

        // A manual queue move changes the native occurrence immediately, while
        // the outgoing media element can still emit one final paused/time update.
        // Reject that old occurrence before metadata reconciliation can schedule
        // a recovery load for the already-selected target.
        let queueEntryIDBeforeReconciliation = self.playerService.currentQueueEntryID
        let queueEntryChangedBeforeReconciliation = WebPlaybackIdentityTransition.didQueueEntryChange(
            hasBaseline: self.hasAcceptedQueueEntryBaseline,
            lastAcceptedQueueEntryID: self.lastAcceptedQueueEntryID,
            currentQueueEntryID: queueEntryIDBeforeReconciliation
        )
        let shouldAcceptBeforeReconciliation = WebPlaybackIdentityTransition.shouldAcceptMediaState(
            queueEntryChanged: queueEntryChangedBeforeReconciliation,
            observerEpoch: observerEpoch,
            lastAcceptedObserverEpoch: self.lastAcceptedObserverEpoch,
            mediaGeneration: mediaGeneration,
            lastAcceptedMediaGeneration: self.lastAcceptedMediaGeneration
        )
        if !shouldAcceptBeforeReconciliation, isWithinQueueNavigationObservationGrace {
            return
        }

        let expectedVideoIdBeforeReconciliation = self.playerService.currentTrack?.videoId
            ?? self.playerService.pendingPlayVideoId
        let shouldApplyPlaybackState = self.playerService.reconcileWebPlaybackMetadata(
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            observedVideoId: observedVideoId,
            mediaVideoId: mediaVideoId,
            bridgeTrackChanged: trackChanged
        )

        let currentQueueEntryID = self.playerService.currentQueueEntryID
        let queueEntryChanged = WebPlaybackIdentityTransition.didQueueEntryChange(
            hasBaseline: self.hasAcceptedQueueEntryBaseline,
            lastAcceptedQueueEntryID: self.lastAcceptedQueueEntryID,
            currentQueueEntryID: currentQueueEntryID
        )
        let shouldAcceptMediaState = WebPlaybackIdentityTransition.shouldAcceptMediaState(
            queueEntryChanged: queueEntryChanged,
            observerEpoch: observerEpoch,
            lastAcceptedObserverEpoch: self.lastAcceptedObserverEpoch,
            mediaGeneration: mediaGeneration,
            lastAcceptedMediaGeneration: self.lastAcceptedMediaGeneration
        )

        let mediaMatches = self.playerService.observedPlaybackMatchesCurrentTarget(
            videoId: mediaVideoId
        )
        guard shouldApplyPlaybackState,
              mediaMatches,
              shouldAcceptMediaState
        else {
            return
        }

        let acceptedVideoId = mediaVideoId
        let previousAcceptedVideoId = self.lastAcceptedObservedVideoId
        let acceptedObservedVideoIdChanged = acceptedVideoId != nil
            && acceptedVideoId != previousAcceptedVideoId
        let confirmedTrackTransition = WebPlaybackIdentityTransition.isConfirmed(
            observedVideoId: acceptedVideoId,
            lastAcceptedObservedVideoId: previousAcceptedVideoId,
            expectedVideoIdBeforeReconciliation: expectedVideoIdBeforeReconciliation
        )
        if let acceptedVideoId {
            self.lastAcceptedObservedVideoId = acceptedVideoId
        }

        self.playerService.updatePlaybackState(
            isPlaying: isPlaying,
            progress: progress,
            duration: duration,
            observedVideoId: mediaVideoId
        )
        self.lastAcceptedObserverEpoch = observerEpoch
        self.lastAcceptedMediaGeneration = mediaGeneration
        self.lastAcceptedQueueEntryID = currentQueueEntryID
        self.hasAcceptedQueueEntryBaseline = true

        // Apply per-track state only after video identity has reconciled.
        self.playerService.updateVideoAvailability(hasVideo: hasVideo)
        let logicalMatchesMedia = observedVideoId != nil && observedVideoId == mediaVideoId
        if logicalMatchesMedia, acceptedObservedVideoIdChanged || trackChanged {
            self.playerService.updateLikeStatus(likeStatus)
        }

        self.closeVideoWindowAfterConfirmedTransitionIfNeeded(
            confirmedTrackTransition: confirmedTrackTransition,
            observedVideoId: acceptedVideoId
        )
    }

    private func closeVideoWindowAfterConfirmedTransitionIfNeeded(
        confirmedTrackTransition: Bool,
        observedVideoId: String?
    ) {
        guard self.playerService.showVideo,
              confirmedTrackTransition,
              !self.playerService.isVideoGracePeriodActive
        else {
            return
        }

        DiagnosticsLogger.player.info(
            "trackChanged to videoId '\(observedVideoId ?? "unknown")' while video shown - closing video window"
        )
        self.playerService.showVideo = false
    }

    private static func nonEmptyVideoId(_ value: Any?) -> String? {
        guard let videoId = value as? String, !videoId.isEmpty else { return nil }
        return videoId
    }

    private static func likeStatus(from rawValue: String?) -> LikeStatus {
        switch rawValue {
        case "LIKE":
            .like
        case "DISLIKE":
            .dislike
        default:
            .indifferent
        }
    }
}
