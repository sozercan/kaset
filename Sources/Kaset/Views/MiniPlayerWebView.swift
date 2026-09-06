// swiftlint:disable file_length
import os
import SwiftUI
import WebKit

// MARK: - WebPlaybackIdentityTransition

enum WebPlaybackIdentityTransition {
    struct ObservationOrder {
        let observerEpoch: Double
        let lastAcceptedObserverEpoch: Double?
        let mediaGeneration: Int
        let lastAcceptedMediaGeneration: Int?
    }

    struct TrackEndedIdentityDeadlinePayload {
        let identityDisposition: String?
        let mediaIdentityUncertain: Bool?
        let videoId: String?
        let mediaVideoId: String?
        let observerEpoch: Double?
        let eventIssuedAtMilliseconds: Double?
        let documentGeneration: UInt64?
        let nativePlaybackGeneration: UInt64?
        let mediaGeneration: UInt64?
        let isAd: Bool?
    }

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

    static func shouldAcceptAdvertisementState(
        hasReadyMedia: Bool,
        isShowingAd: Bool,
        observedVideoId: String?,
        pendingSourceVideoId: String?,
        order: ObservationOrder
    ) -> Bool {
        guard hasReadyMedia,
              isShowingAd,
              self.isObservationOrdered(
                  observerEpoch: order.observerEpoch,
                  lastAcceptedObserverEpoch: order.lastAcceptedObserverEpoch,
                  mediaGeneration: order.mediaGeneration,
                  lastAcceptedMediaGeneration: order.lastAcceptedMediaGeneration
              )
        else { return false }
        guard let pendingSourceVideoId,
              let observedVideoId,
              observedVideoId == pendingSourceVideoId
        else { return true }
        guard let lastAcceptedObserverEpoch = order.lastAcceptedObserverEpoch else { return false }
        if order.observerEpoch > lastAcceptedObserverEpoch {
            return true
        }
        guard order.observerEpoch == lastAcceptedObserverEpoch,
              let lastAcceptedMediaGeneration = order.lastAcceptedMediaGeneration
        else { return false }
        return order.mediaGeneration > lastAcceptedMediaGeneration
    }

    static func isValidTrackEndedIdentityDeadlinePayload(
        _ payload: TrackEndedIdentityDeadlinePayload
    ) -> Bool {
        guard payload.identityDisposition == "deadlineFallback",
              payload.mediaIdentityUncertain == true,
              let videoId = payload.videoId,
              videoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mediaVideoId = payload.mediaVideoId,
              mediaVideoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let observerEpoch = payload.observerEpoch,
              observerEpoch.isFinite,
              let eventIssuedAtMilliseconds = payload.eventIssuedAtMilliseconds,
              eventIssuedAtMilliseconds.isFinite,
              payload.documentGeneration != nil,
              payload.nativePlaybackGeneration != nil,
              let mediaGeneration = payload.mediaGeneration,
              mediaGeneration > 0,
              payload.isAd == false
        else { return false }
        return true
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

// MARK: - MusicHomePreloadPolicy

enum MusicHomePreloadPolicy {
    nonisolated static func shouldPreload(
        isRunningUnitTests: Bool,
        isSuppressedForDeferredRestore: Bool,
        hasStartedHomePreload: Bool,
        currentVideoId: String?
    ) -> Bool {
        !isRunningUnitTests
            && !isSuppressedForDeferredRestore
            && !hasStartedHomePreload
            && currentVideoId == nil
    }
}

// MARK: - WebPlaybackTransitionFallbackPolicy

enum WebPlaybackTransitionFallbackPolicy {
    static let advertisementStallGrace: Duration = .seconds(15)
    static let advertisementRetryInterval: Duration = .seconds(1)

    nonisolated static func deadline(
        now: ContinuousClock.Instant,
        initialFallbackDelay: Duration
    ) -> ContinuousClock.Instant {
        now.advanced(by: initialFallbackDelay + self.advertisementStallGrace)
    }

    nonisolated static func retryDelay(
        isShowingAd: Bool,
        now: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant,
        lastAdvertisementProgressAt: ContinuousClock.Instant? = nil
    ) -> Duration? {
        guard isShowingAd else { return nil }
        // A healthy ad can outlast the initial grace. Recover after its media
        // clock stops advancing, rather than reloading in the middle of the ad.
        let progressDeadline = lastAdvertisementProgressAt?.advanced(by: self.advertisementStallGrace)
        let effectiveDeadline = max(deadline, progressDeadline ?? deadline)
        guard now < effectiveDeadline else { return nil }
        return min(self.advertisementRetryInterval, effectiveDeadline - now)
    }

    nonisolated static func shouldDefer(
        isShowingAd: Bool,
        now: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant
    ) -> Bool {
        self.retryDelay(
            isShowingAd: isShowingAd,
            now: now,
            deadline: deadline
        ) != nil
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
// swiftlint:disable:next type_body_length
final class SingletonPlayerWebView {
    /// Media confirmation can take longer than three seconds while AirPlay changes
    /// sources. Keep a bounded recovery window without reloading a healthy handoff.
    private static let routerNavigationFallbackDelay: Duration = .seconds(15)

    private struct PendingRouterNavigation {
        let videoId: String
        let fallbackURL: URL
        let generation: Int
        let fallbackDeadline: ContinuousClock.Instant
    }

    private final class PlaybackBridgeMultiplexer: NSObject, WKScriptMessageHandler {
        private weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let singleton = SingletonPlayerWebView.shared
            guard let coordinator = self.coordinator,
                  singleton.coordinator === coordinator,
                  message.webView === singleton.webView,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String,
                  SingletonPlayerWebView.acceptsBridgeSource(
                      isMainFrame: message.frameInfo.isMainFrame,
                      sourceScheme: message.frameInfo.securityOrigin.protocol,
                      sourceHost: message.frameInfo.securityOrigin.host
                  )
            else { return }

            guard SingletonPlayerWebView.acceptsBridgeDocumentID(
                body["documentID"] as? Int,
                expectedDocumentID: singleton.expectedBridgeDocumentID,
                messageType: type
            ) else { return }

            switch type {
            case "QUEUE_INJECTION_RESULT":
                guard let documentGeneration = WebPlaybackDocumentGeneration.decode(
                    body["documentGeneration"]
                ) else { return }
                self.handleQueueInjectionResult(
                    body: body,
                    coordinator: coordinator,
                    documentGeneration: documentGeneration
                )
                return
            case "TRACK_ENDED":
                // Keep an uncertain occurrence unclaimed so a resolved retry can consume it.
                guard body["mediaIdentityUncertain"] as? Bool != true else { return }
            case "TRACK_ENDED_IDENTITY_DEADLINE":
                guard let expectedDocumentID = singleton.expectedBridgeDocumentID,
                      body["documentID"] as? Int == expectedDocumentID,
                      WebPlaybackIdentityTransition.isValidTrackEndedIdentityDeadlinePayload(
                          .init(
                              identityDisposition: body["identityDisposition"] as? String,
                              mediaIdentityUncertain: body["mediaIdentityUncertain"] as? Bool,
                              videoId: body["videoId"] as? String,
                              mediaVideoId: body["mediaVideoId"] as? String,
                              observerEpoch: SingletonPlayerWebView.finitePlaybackBridgeDouble(
                                  from: body["observerEpoch"]
                              ),
                              eventIssuedAtMilliseconds: SingletonPlayerWebView.finitePlaybackBridgeDouble(
                                  from: body["eventIssuedAtMilliseconds"]
                              ),
                              documentGeneration: WebPlaybackDocumentGeneration.decode(
                                  body["documentGeneration"]
                              ),
                              nativePlaybackGeneration: WebPlaybackDocumentGeneration.decode(
                                  body["nativePlaybackGeneration"]
                              ),
                              mediaGeneration: WebPlaybackDocumentGeneration.decode(
                                  body["mediaGeneration"]
                              ),
                              isAd: body["isAd"] as? Bool
                          )
                      )
                else { return }
            case "STATE_UPDATE":
                break
            default:
                break
            }

            coordinator.userContentController(userContentController, didReceive: message)
        }

        private func handleQueueInjectionResult(
            body: [String: Any],
            coordinator: Coordinator,
            documentGeneration: UInt64
        ) {
            guard let videoID = Self.normalizedVideoID(body["videoId"]),
                  let attemptGeneration = body["attemptGeneration"] as? Int
            else { return }
            coordinator.enqueueWebQueueInjectionResult(
                videoId: videoID,
                attemptGeneration: attemptGeneration,
                success: body["success"] as? Bool ?? false,
                reason: body["reason"] as? String,
                documentGeneration: documentGeneration
            )
        }

        private static func normalizedVideoID(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    static let shared = SingletonPlayerWebView()

    /// Creates an isolated wrapper for tests that exercise WebView lifecycle state.
    static func makeTestInstance(
        webView: WKWebView? = nil,
        documentGeneration: WebPlaybackDocumentGeneration = WebPlaybackDocumentGeneration()
    ) -> SingletonPlayerWebView {
        let instance = SingletonPlayerWebView()
        instance.webView = webView
        instance.documentGeneration = documentGeneration
        return instance
    }

    private(set) var webView: WKWebView?
    weak var webKitManager: WebKitManager?
    private weak var currentContainer: NSView?
    private var usesCookieFreeDataStore: Bool?
    var currentVideoId: String?
    var coordinator: Coordinator?
    let logger = DiagnosticsLogger.player
    private var loadGeneration = 0
    private var pendingRouterNavigation: PendingRouterNavigation?
    private var playbackBridgeMultiplexer: PlaybackBridgeMultiplexer?
    private var documentIDGeneration = 0
    var pendingDocumentID: Int?
    var activeDocumentNavigation: WKNavigation?
    var activeDocumentNavigationID: Int?
    private var committedDocumentID: Int?
    var isDocumentNavigationInProgress = false
    private(set) var documentGeneration = WebPlaybackDocumentGeneration()
    private(set) var documentNavigationStartedAtMilliseconds: Double?
    private var documentNavigations = WebPlaybackNavigationMap<WKNavigation, WebPlaybackTrackedNavigation>()
    private var cancelledDocumentNavigations = WebPlaybackNavigationMap<WKNavigation, WebPlaybackCancelledNavigation>()
    private var continuationGenerationsAwaitingStart: Set<UInt64> = []

    private var expectedBridgeDocumentID: Int? {
        if self.documentGeneration.pendingGeneration != nil
            || self.documentGeneration.inFlightGeneration != nil
        {
            return self.pendingDocumentID
        }
        return self.committedDocumentID ?? self.activeDocumentNavigationID ?? self.pendingDocumentID
    }

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
        /// Restart the tracked song in place. For another song, prefer the SPA router.
        case preferInPlaceWhenSameVideoId
        /// Retry navigation through the SPA router even when Swift already tracks the requested ID.
        case preferRouterWhenSameVideoId
        /// Reload when the tracked ID matches but the media is out of sync. For another song, prefer the SPA router.
        case forceFullPageWhenSameVideoId

        var requiresSameVideoNavigation: Bool {
            self == .preferRouterWhenSameVideoId || self == .forceFullPageWhenSameVideoId
        }
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

    nonisolated static func queueNavigationStrategy(
        currentVideoId: String?,
        targetVideoId: String,
        startsPaused: Bool,
        allowsInPlaceRestart: Bool = true
    ) -> VideoLoadStrategy {
        guard currentVideoId == targetVideoId else { return .standard }
        return startsPaused || !allowsInPlaceRestart
            ? .forceFullPageWhenSameVideoId
            : .preferInPlaceWhenSameVideoId
    }

    var canRestartInPlace: Bool {
        self.documentGeneration.accepts(generation: self.documentGeneration.currentGeneration)
    }

    nonisolated static func freshSameIDPlaybackStrategy(
        isShowingAd: Bool
    ) -> VideoLoadStrategy {
        isShowingAd ? .forceFullPageWhenSameVideoId : .preferInPlaceWhenSameVideoId
    }

    var displayMode: DisplayMode = .hidden
    var mediaControlUsesNextPrev: Bool
    var playbackAudioQuality: SettingsManager.PlaybackAudioQuality
    private var hasStartedHomePreload = false
    private(set) var isHomePreloadSuppressedForDeferredRestore = false

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
        self.releaseDeferredHomePreloadSuppressionIfNeeded(playerService: playerService)
        if let existing = webView, self.usesCookieFreeDataStore == usesCookieFreeDataStore {
            self.preloadHomePageIfNeeded()
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
        let coordinator = Coordinator(playerService: playerService)
        self.coordinator = coordinator

        let configuration = webKitManager.createWebViewConfiguration(
            websiteDataStore: usesCookieFreeDataStore ? .nonPersistent() : nil
        )

        // Preserve feature-specific queue/SPA ingress checks while the main
        // coordinator owns generation-scoped bridge decoding.
        let playbackBridgeMultiplexer = PlaybackBridgeMultiplexer(coordinator: coordinator)
        self.playbackBridgeMultiplexer = playbackBridgeMultiplexer
        configuration.userContentController.add(
            playbackBridgeMultiplexer,
            name: "singletonPlayer"
        )

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
        self.preloadHomePageIfNeeded()
        return newWebView
    }

    private func releaseDeferredHomePreloadSuppressionIfNeeded(playerService: PlayerService) {
        guard self.isHomePreloadSuppressedForDeferredRestore,
              !playerService.isPendingRestoredLoadDeferred,
              !playerService.isRestoringPlaybackSession
        else { return }
        self.isHomePreloadSuppressedForDeferredRestore = false
    }

    private func preloadHomePageIfNeeded() {
        guard MusicHomePreloadPolicy.shouldPreload(
            isRunningUnitTests: UITestConfig.isRunningUnitTests,
            isSuppressedForDeferredRestore: self.isHomePreloadSuppressedForDeferredRestore,
            hasStartedHomePreload: self.hasStartedHomePreload,
            currentVideoId: self.currentVideoId
        ) else { return }
        guard let webView, let playerService = self.coordinator?.playerService else { return }

        self.cancelActiveDocumentNavigation(on: webView)
        if self.documentGeneration.pendingGeneration != nil {
            self.documentGeneration.cancelPendingNavigation()
        }
        self.documentNavigationStartedAtMilliseconds = Date().timeIntervalSince1970 * 1000
        let generation = self.documentGeneration.beginNavigation()
        self.installUserScripts(
            on: webView.configuration.userContentController,
            shouldAutoplay: playerService.shouldAutoplayPlaybackDocument,
            targetVolume: playerService.volume,
            documentGeneration: generation,
            nativePlaybackGeneration: playerService.currentNativeMusicPlaybackGeneration
        )
        guard let homeURL = Self.homePreloadURL(documentGeneration: generation) else {
            self.documentGeneration.cancelPendingNavigation()
            self.logger.error("Unable to construct YT Music home URL")
            return
        }

        self.hasStartedHomePreload = true
        self.logger.info("Preloading YT Music home page")
        self.startDocumentNavigation(
            on: webView,
            request: URLRequest(url: homeURL),
            generation: generation
        )
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
        self.coordinator?.playerService.updateAirPlayStatus(isConnected: false)
        let blankURL = self.beginBlankDocumentNavigation()
        guard let webView else { return }
        self.logger.info("Tearing down singleton music WebView")
        self.loadGeneration += 1
        self.pendingRouterNavigation = nil
        self.pendingDocumentID = nil
        self.activeDocumentNavigation = nil
        self.activeDocumentNavigationID = nil
        self.committedDocumentID = nil
        self.isDocumentNavigationInProgress = false
        self.currentVideoId = nil
        webView.evaluateJavaScript("document.querySelector('video')?.pause()", completionHandler: nil)
        if let blankURL {
            webView.load(URLRequest(url: blankURL))
        }
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "singletonPlayer"
        )
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        self.webKitManager?.unregisterExtensionHostWebView(role: .musicPlayer)
        self.webView = nil
        self.playbackBridgeMultiplexer = nil
        self.coordinator?.cancelPlaybackBridgeTasks()
        self.coordinator = nil
        self.cancelledDocumentNavigations.removeAll()
        self.currentContainer = nil
        self.usesCookieFreeDataStore = nil
        self.hasStartedHomePreload = false
        self.isHomePreloadSuppressedForDeferredRestore = false
    }

    /// Recreates the playback WebView across a cookie-store boundary while preserving only active document identity.
    func rebuildForAuthDataStoreChange(usesCookieFreeDataStore: Bool) {
        guard self.usesCookieFreeDataStore != usesCookieFreeDataStore else { return }
        guard let webKitManager = self.webKitManager,
              let playerService = self.coordinator?.playerService
        else {
            self.usesCookieFreeDataStore = usesCookieFreeDataStore
            return
        }
        // A deferred restored session has not committed its pending watch
        // document. Rebuilding must therefore leave the replacement WebView
        // unlabeled and inert so explicit Resume routes to the persisted video.
        let isDeferredRestoredLoad = playerService.isPendingRestoredLoadDeferred
        let videoId = isDeferredRestoredLoad ? nil : self.currentVideoId
        let previousContainer = self.currentContainer
        self.logger.info("Rebuilding singleton music WebView for auth data-store boundary")
        self.tearDown()
        self.isHomePreloadSuppressedForDeferredRestore = isDeferredRestoredLoad

        // Restore a real active document identity before WebView creation so the
        // ordinary home preload cannot race an immediate identity re-point.
        self.currentVideoId = videoId
        _ = self.getWebView(
            webKitManager: webKitManager,
            playerService: playerService,
            usesCookieFreeDataStore: usesCookieFreeDataStore
        )
        if let previousContainer {
            self.ensureInHierarchy(container: previousContainer)
        }
    }

    /// Load a video, stopping any currently playing audio first.
    /// Note: Full page navigation destroys the video element; same-id restarts use ``restartInPlaceFromBeginning()`` when possible.
    /// Preserve the document through the SPA router when possible to retain the AirPlay route.
    func loadVideo(videoId: String, strategy: VideoLoadStrategy = .standard) {
        guard let webView else {
            self.logger.error("loadVideo called but webView is nil")
            return
        }

        self.isHomePreloadSuppressedForDeferredRestore = false
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
        case .preferRouterWhenSameVideoId:
            break
        }

        guard let fallbackURL = Self.youtubeMusicWatchURL(videoId: videoId) else {
            self.logger.error("Unable to construct YouTube Music watch URL")
            return
        }

        if videoId != previousVideoId {
            self.logger.info("Loading video: \(videoId) (was: \(previousVideoId ?? "none"))")
        }

        self.currentVideoId = videoId
        self.loadGeneration &+= 1
        let generation = self.loadGeneration
        self.pendingRouterNavigation = nil

        let playerService = self.coordinator?.playerService
        let currentVolume = playerService?.volume ?? 1.0
        let shouldAutoplay = playerService?.shouldAutoplayPlaybackDocument ?? false
        let nativePlaybackGeneration = playerService?.currentNativeMusicPlaybackGeneration ?? 0
        self.logger.info("Will apply volume \(currentVolume) after page load")

        let requiresSameVideoReload = strategy == .forceFullPageWhenSameVideoId && videoId == previousVideoId
        let canUseRouter = !requiresSameVideoReload
            && self.committedDocumentID != nil
            && self.documentGeneration.accepts(generation: self.documentGeneration.currentGeneration)
            && WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
                webView.url,
                host: "music.youtube.com"
            )
        guard canUseRouter else {
            self.startFullPageNavigation(
                videoId: videoId,
                on: webView,
                currentVolume: currentVolume,
                shouldAutoplay: shouldAutoplay,
                nativePlaybackGeneration: nativePlaybackGeneration
            )
            return
        }

        // Preserve the committed document generation while YouTube Music's SPA
        // router swaps media in place. The observer's media generation and the
        // native queue occurrence fence the handoff inside that document.
        let prepareScript = """
            (function() {
                const video = document.querySelector('video');
                if (video && !video.paused) video.pause();
                window.__kasetTargetVolume = \(currentVolume);
                window.__kasetNativePlaybackGeneration = \(nativePlaybackGeneration);
                window.__kasetAutoplayPending = \(shouldAutoplay ? "true" : "false");
                window.__kasetBlockAutoplay = \(shouldAutoplay ? "false" : "true");
                window.__kasetPlaybackSuppressed = \(shouldAutoplay ? "false" : "true");
                window.__kasetResumeAdOnly = false;
                window.__kasetAutoplayAttempts = 0;
                window.__kasetAutoplayRetryScheduled = false;
                \(WebPlaybackAudioOutput.prepareScript)
            })();
        """
        webView.evaluateJavaScript(prepareScript, completionHandler: nil)
        self.navigateViaRouter(
            videoId: videoId,
            fallbackURL: fallbackURL,
            generation: generation
        )
    }

    nonisolated static func transitionFallbackDeadline(
        now: ContinuousClock.Instant,
        initialFallbackDelay: Duration
    ) -> ContinuousClock.Instant {
        WebPlaybackTransitionFallbackPolicy.deadline(
            now: now,
            initialFallbackDelay: initialFallbackDelay
        )
    }

    nonisolated static func transitionFallbackRetryDelay(
        isShowingAd: Bool,
        now: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant,
        lastAdvertisementProgressAt: ContinuousClock.Instant? = nil
    ) -> Duration? {
        WebPlaybackTransitionFallbackPolicy.retryDelay(
            isShowingAd: isShowingAd,
            now: now,
            deadline: deadline,
            lastAdvertisementProgressAt: lastAdvertisementProgressAt
        )
    }

    nonisolated static func shouldDeferTransitionFallback(
        isShowingAd: Bool,
        now: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant
    ) -> Bool {
        self.transitionFallbackRetryDelay(
            isShowingAd: isShowingAd,
            now: now,
            deadline: deadline
        ) != nil
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

    private func startFullPageNavigation(
        videoId: String,
        on webView: WKWebView,
        currentVolume: Double,
        shouldAutoplay: Bool,
        nativePlaybackGeneration: UInt64
    ) {
        self.cancelActiveDocumentNavigation(on: webView)
        if self.documentGeneration.pendingGeneration != nil {
            self.documentGeneration.cancelPendingNavigation()
        }
        self.documentNavigationStartedAtMilliseconds = Date().timeIntervalSince1970 * 1000
        let reservedDocumentGeneration = self.documentGeneration.beginNavigation()

        self.installUserScripts(
            on: webView.configuration.userContentController,
            shouldAutoplay: shouldAutoplay,
            targetVolume: currentVolume,
            documentGeneration: reservedDocumentGeneration,
            nativePlaybackGeneration: nativePlaybackGeneration
        )

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
            window.__kasetTargetVolume = \(currentVolume);
        """
        webView.evaluateJavaScript("\(prenavScript)void 0;", completionHandler: nil)
        self.startDocumentNavigation(
            on: webView,
            request: URLRequest(url: urlToLoad),
            generation: reservedDocumentGeneration
        )
    }

    private func navigateViaRouter(videoId: String, fallbackURL: URL, generation: Int) {
        guard let webView else { return }

        let host = webView.url?.host ?? ""
        guard host == "music.youtube.com" || host == "www.music.youtube.com" else {
            self.logger.debug("Router unavailable (host: \(host, privacy: .public)); falling back to full load")
            self.pendingRouterNavigation = nil
            self.startRouterFallbackFullPageNavigation(videoId: videoId, on: webView)
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

        let fallbackStartedAt = ContinuousClock.now
        self.pendingRouterNavigation = PendingRouterNavigation(
            videoId: videoId,
            fallbackURL: fallbackURL,
            generation: generation,
            fallbackDeadline: Self.transitionFallbackDeadline(
                now: fallbackStartedAt,
                initialFallbackDelay: Self.routerNavigationFallbackDelay
            )
        )
        self.scheduleRouterNavigationFallback(
            videoId: videoId,
            fallbackURL: fallbackURL,
            generation: generation,
            delay: Self.routerNavigationFallbackDelay
        )

        webView.evaluateJavaScript(routerScript) { [weak self] result, _ in
            guard let self, let webView = self.webView else { return }
            guard self.loadGeneration == generation,
                  self.currentVideoId == videoId,
                  let pendingRouterNavigation = self.pendingRouterNavigation,
                  pendingRouterNavigation.videoId == videoId,
                  pendingRouterNavigation.fallbackURL == fallbackURL,
                  pendingRouterNavigation.generation == generation
            else { return }
            let didNavigate = result as? Bool ?? false
            if didNavigate {
                self.logger.info("Router navigation started for video: \(videoId)")
            } else {
                self.logger.info("Router navigation failed for video: \(videoId), using full load")
                self.pendingRouterNavigation = nil
                self.startRouterFallbackFullPageNavigation(videoId: videoId, on: webView)
            }
        }
    }

    /// The router owns media confirmation and its bounded full-page fallback.
    /// Stale observations must not restart that recovery while it is in flight.
    func isRouterNavigationPending(for videoId: String) -> Bool {
        guard let pendingRouterNavigation = self.pendingRouterNavigation else { return false }
        return pendingRouterNavigation.videoId == videoId
            && pendingRouterNavigation.generation == self.loadGeneration
            && self.currentVideoId == videoId
            && self.committedDocumentID != nil
            && self.documentGeneration.accepts(generation: self.documentGeneration.currentGeneration)
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
        generation: Int,
        delay: Duration
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
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

            let now = ContinuousClock.now
            if let retryDelay = Self.transitionFallbackRetryDelay(
                isShowingAd: self.coordinator?.playerService.isShowingAd ?? false,
                now: now,
                deadline: pendingRouterNavigation.fallbackDeadline,
                lastAdvertisementProgressAt: self.coordinator?.playerService.lastAdPlaybackProgressAt
            ) {
                self.logger.debug("Deferring router fallback for \(videoId) while an advertisement is active")
                self.scheduleRouterNavigationFallback(
                    videoId: videoId,
                    fallbackURL: fallbackURL,
                    generation: generation,
                    delay: retryDelay
                )
                return
            }

            self.pendingRouterNavigation = nil
            self.logger.warning("Router navigation to \(videoId) was not media-confirmed; using full load")
            self.startRouterFallbackFullPageNavigation(videoId: videoId, on: webView)
        }
    }

    private func startRouterFallbackFullPageNavigation(videoId: String, on webView: WKWebView) {
        let playerService = self.coordinator?.playerService
        self.startFullPageNavigation(
            videoId: videoId,
            on: webView,
            currentVolume: playerService?.volume ?? 1.0,
            shouldAutoplay: playerService?.shouldAutoplayPlaybackDocument ?? false,
            nativePlaybackGeneration: playerService?.currentNativeMusicPlaybackGeneration ?? 0
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
        nativePlaybackGeneration: UInt64 = 0,
        documentID: Int = 0
    ) -> String {
        self.pageBootstrapScript(
            shouldAutoplay: !isRestoringPlaybackSession,
            targetVolume: targetVolume,
            documentGeneration: documentGeneration,
            nativePlaybackGeneration: nativePlaybackGeneration,
            documentID: documentID
        )
    }

    nonisolated static func pageBootstrapScript(
        shouldAutoplay: Bool,
        targetVolume: Double,
        documentGeneration _: UInt64,
        nativePlaybackGeneration: UInt64 = 0,
        documentID: Int = 0
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
            window.__kasetBlockAutoplay = \(shouldAutoplay ? "false" : "true");
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
            window.__kasetDocumentID = \(documentID);
        """
    }

    nonisolated static func homePreloadURL(documentGeneration: UInt64) -> URL? {
        var components = URLComponents(string: "https://music.youtube.com/")
        components?.queryItems = [
            URLQueryItem(
                name: WebPlaybackDocumentGeneration.urlQueryKey,
                value: String(documentGeneration)
            ),
        ]
        components?.fragment = "\(WebPlaybackDocumentGeneration.urlQueryKey)=\(documentGeneration)"
        return components?.url
    }

    nonisolated static func isExpectedHomePreloadURL(_ url: URL?) -> Bool {
        guard let components = url.flatMap({
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "music.youtube.com"
            && (components.path.isEmpty || components.path == "/")
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
        self.documentIDGeneration &+= 1
        let documentID = self.documentIDGeneration
        self.pendingDocumentID = documentID

        // Autoplay intent must exist before media lifecycle events like `canplay`.
        // `didFinish` is too late on fast or cached player loads.
        let pageBootstrapScript = WKUserScript(
            source: Self.pageBootstrapScript(
                shouldAutoplay: shouldAutoplay,
                targetVolume: targetVolume,
                documentGeneration: documentGeneration,
                nativePlaybackGeneration: nativePlaybackGeneration,
                documentID: documentID
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(pageBootstrapScript)

        contentController.addUserScript(WKUserScript(
            source: WebPlaybackAudioOutput.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

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

    nonisolated static func acceptsBridgeDocumentID(
        _ documentID: Int?,
        expectedDocumentID: Int?,
        messageType: String
    ) -> Bool {
        // The coordinator fences media keys by committed generation and command time.
        messageType == "REMOTE_NEXT" || messageType == "REMOTE_PREVIOUS"
            || documentID == nil || documentID == expectedDocumentID
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
        if expectedVideoID == nil,
           let response = response as? HTTPURLResponse,
           (200 ..< 300).contains(response.statusCode),
           let url = response.url,
           url.scheme?.lowercased() == "https",
           url.host?.lowercased() == "music.youtube.com",
           url.path.isEmpty || url.path == "/"
        {
            return true
        }
        return WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
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
        self.coordinator?.cancelPlaybackBridgeTasks()
        for (identifier, navigation) in self.documentNavigations {
            self.cancelledDocumentNavigations[identifier] = WebPlaybackCancelledNavigation(
                generation: navigation.generation,
                shouldReportFailure: true
            )
        }
        self.documentGeneration.invalidate()
        self.documentNavigationStartedAtMilliseconds = nil
        self.pendingDocumentID = nil
        self.activeDocumentNavigation = nil
        self.activeDocumentNavigationID = nil
        self.committedDocumentID = nil
        self.isDocumentNavigationInProgress = false
        self.documentNavigations.removeAll()
        self.continuationGenerationsAwaitingStart.removeAll()
    }

    func beginBlankDocumentNavigation() -> URL? {
        self.coordinator?.cancelPlaybackBridgeTasks()
        self.documentNavigations.removeAll()
        self.continuationGenerationsAwaitingStart.removeAll()
        self.pendingDocumentID = nil
        self.activeDocumentNavigation = nil
        self.activeDocumentNavigationID = nil
        self.committedDocumentID = nil
        self.isDocumentNavigationInProgress = false
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

        if self.currentVideoId == nil,
           self.documentGeneration.pendingGeneration == nil,
           self.documentGeneration.inFlightGeneration == nil,
           let url = navigationAction.request.url,
           url.scheme?.lowercased() == "https",
           url.host?.lowercased() == "music.youtube.com",
           url.path.isEmpty || url.path == "/"
        {
            self.webKitManager?.extensionHostWebViewWillNavigate(webView, to: url)
            decisionHandler(.allow)
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
        if WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
            webView.url,
            host: "music.youtube.com"
        ), let url = request.url {
            webView.evaluateJavaScript(
                WebPlaybackDocumentGeneration.locationReplacementScript(for: url)
            ) { [weak self, weak webView] _, error in
                guard let self,
                      let webView,
                      webView === self.webView,
                      self.documentGeneration.inFlightGeneration == generation,
                      self.documentGeneration.pendingGeneration == nil
                else { return }
                guard error == nil
                    || WebPlaybackDocumentGeneration.generation(from: webView.url) == generation
                else {
                    self.handleCurrentDocumentNavigationFailure(generation, webView: webView)
                    return
                }
            }
            return
        }
        guard let navigation = webView.load(request) else {
            self.handleCurrentDocumentNavigationFailure(generation, webView: webView)
            return
        }
        self.documentNavigations[navigation] = WebPlaybackTrackedNavigation(
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
        self.documentNavigations[navigation] = WebPlaybackTrackedNavigation(
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

    @discardableResult
    func trackDocumentNavigationStart(_ navigation: WKNavigation?, webView: WKWebView) -> Bool {
        guard webView === self.webView else { return false }
        if let navigation {
            let trackedGeneration = self.documentNavigations[navigation]?.generation
            if trackedGeneration != nil {
                return Self.acceptsDocumentNavigationStart(
                    isCancelled: self.cancelledDocumentNavigations[navigation] != nil,
                    trackedGeneration: trackedGeneration,
                    candidateGeneration: nil,
                    inFlightGeneration: self.documentGeneration.inFlightGeneration,
                    hasPendingGeneration: self.documentGeneration.pendingGeneration != nil
                )
            }
            if self.cancelledDocumentNavigations[navigation] != nil {
                return false
            }
        }
        if WebPlaybackDocumentGeneration.isInternalBlankNavigation(webView.url) {
            return self.documentGeneration.ownsBlankNavigation(webView.url)
        }
        guard let navigation else { return false }
        let candidateGeneration = WebPlaybackDocumentGeneration.generation(from: webView.url)
            ?? (self.documentGeneration.committedIntermediaryGeneration
                == self.documentGeneration.inFlightGeneration
                && WebPlaybackDocumentGeneration.isAllowedPlaybackNavigationURL(
                    webView.url,
                    playbackHost: "music.youtube.com"
                ) ? self.documentGeneration.inFlightGeneration : nil)
        guard Self.acceptsDocumentNavigationStart(
            isCancelled: false,
            trackedGeneration: nil,
            candidateGeneration: candidateGeneration,
            inFlightGeneration: self.documentGeneration.inFlightGeneration,
            hasPendingGeneration: self.documentGeneration.pendingGeneration != nil
        ), let candidateGeneration
        else { return false }
        self.documentNavigations[navigation] = WebPlaybackTrackedNavigation(
            generation: candidateGeneration
        )
        return true
    }

    func handleDocumentNavigationStart(_ navigation: WKNavigation?, webView: WKWebView) {
        guard self.trackDocumentNavigationStart(navigation, webView: webView),
              self.beginDocumentNavigation(navigation, in: webView)
        else { return }
        self.webKitManager?.extensionHostWebViewDidStartNavigation(webView)
    }

    func handleDocumentNavigationRedirect(_ navigation: WKNavigation?, webView: WKWebView) {
        guard webView === self.webView,
              let navigation,
              let trackedNavigation = self.documentNavigations[navigation],
              trackedNavigation.generation == self.documentGeneration.inFlightGeneration,
              self.documentGeneration.pendingGeneration == nil,
              self.isActiveDocumentNavigation(navigation, in: webView)
        else { return }
        self.refreshInstalledUserScripts()
        _ = self.adoptPendingDocumentIDForActiveNavigation(navigation, in: webView)
    }

    func commitDocumentNavigation(_ navigation: WKNavigation?, webView: WKWebView) {
        guard webView === self.webView else { return }
        if self.commitDocumentNavigation(navigation, in: webView) {
            self.committedDocumentID = self.activeDocumentNavigationID ?? self.pendingDocumentID
        }
        if let navigation,
           let cancelledNavigation = self.cancelledDocumentNavigations[navigation]
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
              var trackedNavigation = self.documentNavigations[navigation]
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
        } else if self.currentVideoId == nil, Self.isExpectedHomePreloadURL(webView.url) {
            guard self.documentGeneration.commitNavigation(trackedNavigation.generation) else { return }
            self.documentNavigationStartedAtMilliseconds = nil
            trackedNavigation.didActivatePlaybackOrigin = true
        } else if WebPlaybackDocumentGeneration.isTrustedIntermediaryURL(webView.url) {
            guard self.documentGeneration.commitIntermediaryNavigation(
                trackedNavigation.generation
            ) else { return }
        }
        self.documentNavigations[navigation] = trackedNavigation
        if trackedNavigation.didActivatePlaybackOrigin {
            self.syncAutoplayIntent(on: webView)
        }
    }

    func consumeCancelledDocumentNavigation(
        _ navigation: WKNavigation?
    ) -> WebPlaybackCancelledNavigation? {
        guard let navigation else { return nil }
        return self.cancelledDocumentNavigations.removeValue(
            forKey: navigation
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
            window.__kasetBlockAutoplay = \(shouldAutoplay ? "false" : "true");
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
                  forKey: navigation
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
           self.documentNavigations[navigation] != nil
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
        let finishedTrackedNavigation = self.finishDocumentNavigation(
            navigation,
            webView: webView
        )
        _ = self.finishDocumentNavigation(navigation, in: webView)
        let finishedHomePreload = self.currentVideoId == nil
            && self.documentGeneration.pendingGeneration == nil
            && self.documentGeneration.inFlightGeneration == nil
            && WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
                webView.url,
                host: "music.youtube.com"
            )
        guard finishedTrackedNavigation || finishedHomePreload else { return false }
        self.webKitManager?.extensionHostWebViewDidFinishNavigation(webView)
        return true
    }

    func failDocumentNavigation(_ navigation: WKNavigation?, webView: WKWebView) {
        if let navigation {
            self.cancelledDocumentNavigations.removeValue(forKey: navigation)
        }
        guard webView === self.webView,
              let navigation,
              let trackedNavigation = self.documentNavigations.removeValue(
                  forKey: navigation
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
        _ = self.finishDocumentNavigation(navigation, in: webView)
        if WebPlaybackNavigationFailure.isRetryableCancellation(error) {
            guard let navigation,
                  let trackedNavigation = self.documentNavigations[navigation]
            else {
                if let navigation,
                   let cancelledNavigation = self.cancelledDocumentNavigations.removeValue(
                       forKey: navigation
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
                key !== navigation
                    && candidate.generation == trackedNavigation.generation
            }
            if !trackedNavigation.didActivatePlaybackOrigin,
               hasSameGenerationSuccessor
               || self.continuationGenerationsAwaitingStart.contains(trackedNavigation.generation)
            {
                self.documentNavigations.removeValue(forKey: navigation)
                self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                return
            }
        }
        self.failDocumentNavigation(navigation, webView: webView)
        self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
    }

    func recoverFromContentProcessTermination(webView: WKWebView) {
        guard webView === self.webView else { return }
        self.coordinator?.playerService.updateAirPlayStatus(isConnected: false)
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
        if playerService.pendingNativeQueueAdvance != nil {
            let intent = playerService.currentMusicPlaybackIntent
            Task { @MainActor [weak self, weak playerService, weak webView] in
                guard let self, let playerService, let webView else { return }
                let handled = await playerService
                    .recoverPendingNativeQueueAdvanceAfterContentProcessTermination(intent: intent)
                guard !handled, webView === self.webView else { return }
                self.recoverFromContentProcessTermination(webView: webView)
            }
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
