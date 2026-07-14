import os
import SwiftUI
import WebKit

// MARK: - YouTubeWatchWebView

/// Manages the single WebView used for regular YouTube video playback.
///
/// Parallel to `SingletonPlayerWebView` (music) but tuned to youtube.com
/// watch pages: its own observer script (`#movie_player` instead of
/// `ytmusic-*` selectors), its own message handler name (`youtubePlayer`),
/// and a chrome-hiding extraction that leaves only the video surface
/// visible so the page can dock into native Kaset views.
///
/// Exactly one of music/video produces audio at a time — `PlaybackArbiter`
/// enforces the handoff.
@MainActor
final class YouTubeWatchWebView {
    static let shared = YouTubeWatchWebView()

    private(set) var webView: WKWebView?
    weak var webKitManager: WebKitManager?
    private weak var currentContainer: NSView?
    private var usesCookieFreeDataStore: Bool?
    var currentVideoId: String?
    var coordinator: Coordinator?
    let logger = DiagnosticsLogger.player

    /// Seek position (seconds) to apply once the next page finishes loading.
    /// Used to resume a video at its prior position after a forced reload (e.g.
    /// an account/session-identity switch), since the `<video>` element does not
    /// exist until the new document loads. Cleared on apply.
    var pendingSeek: Double?

    /// Monotonic counter for `load(videoId:)` calls. The pre-navigation pause is
    /// async, so a newer load can be requested before an older one's callback
    /// issues `webView.load`. The callback captures the generation and bails if
    /// superseded, so a stale reload can't navigate over a newer selection.
    private var loadGeneration = 0

    /// Tracks which full-page watch document may publish playback bridge events.
    private(set) var documentGeneration = WebPlaybackDocumentGeneration()
    var documentNavigations: [ObjectIdentifier: WebPlaybackTrackedNavigation] = [:]
    private var cancelledDocumentNavigations: [ObjectIdentifier: WebPlaybackCancelledNavigation] = [:]
    var continuationGenerationsAwaitingStart: Set<UInt64> = []
    var pendingSeeksByGeneration: [UInt64: Double] = [:]
    var pendingSeekVideoIdsByGeneration: [UInt64: String] = [:]
    var pendingSeekAttemptIDsByGeneration: [UInt64: UInt64] = [:]
    var nextPendingSeekAttemptID: UInt64 = 0
    var cancelledPendingSeekGenerations: Set<UInt64> = []
    var directSeekGenerations: Set<UInt64> = []
    var pendingSeekRetryCounts: [UInt64: Int] = [:]

    private init() {}

    /// Get or create the watch WebView.
    func getWebView(
        webKitManager: WebKitManager,
        playerService: YouTubePlayerService,
        usesCookieFreeDataStore: Bool = false
    ) -> WKWebView {
        if let existing = webView, self.usesCookieFreeDataStore == usesCookieFreeDataStore {
            return existing
        }
        let previousContainer = self.currentContainer
        if self.webView != nil {
            self.logger.info("Recreating YouTube watch WebView for auth data-store boundary")
            self.tearDown()
        }

        self.logger.info("Creating YouTube watch WebView")
        self.usesCookieFreeDataStore = usesCookieFreeDataStore

        self.coordinator = Coordinator(playerService: playerService)

        let configuration = webKitManager.createWebViewConfiguration(
            websiteDataStore: usesCookieFreeDataStore ? .nonPersistent() : nil
        )
        configuration.userContentController.add(self.coordinator!, name: "youtubePlayer")
        self.installUserScripts(
            on: configuration.userContentController,
            targetVolume: playerService.volume,
            documentGeneration: Self.userScriptDocumentGeneration(from: self.documentGeneration)
        )

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = self.coordinator
        newWebView.customUserAgent = WebKitManager.userAgent
        self.webKitManager = webKitManager
        webKitManager.registerExtensionHostWebView(newWebView, role: .youtubeWatch)

        // Kill the white flash between page navigations.
        newWebView.underPageBackgroundColor = .black

        #if DEBUG
            newWebView.isInspectable = true
        #endif

        self.webView = newWebView
        if let previousContainer {
            self.ensureInHierarchy(container: previousContainer)
        }
        return newWebView
    }

    /// Ensures the WebView fills the given container (reparenting if needed).
    func ensureInHierarchy(container: NSView) {
        guard let webView else { return }
        self.currentContainer = container
        self.webKitManager?.extensionHostWebViewDidBecomeActive(webView)
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
    }

    /// Loads a watch page for the given video, skipping if it is already current.
    func loadVideo(videoId: String) {
        guard videoId != self.currentVideoId else {
            self.logger.debug("YouTube video \(videoId) already loaded, skipping")
            return
        }
        // A normal (non-reload) load starts a fresh video: drop any pending
        // resume-seek left over from an interrupted identity-switch reload, so it
        // cannot be injected into a different video's document.
        self.pendingSeek = nil
        self.load(videoId: videoId)
    }

    /// Forces a full reload of the given video even when it is already current,
    /// optionally resuming at `resumeAt` seconds once the new page loads.
    ///
    /// Used after an account/session-identity switch: the page identity lives in
    /// the served document, so the in-flight watch page must be re-fetched under
    /// the new session for subsequent watch-history pings to attribute correctly.
    func reloadVideo(videoId: String, resumeAt seconds: Double? = nil) {
        self.logger.info("Force-reloading YouTube video under new session identity: \(videoId)")
        self.pendingSeek = seconds
        self.load(videoId: videoId)
    }

    @discardableResult
    func cancelPendingLoad() -> Bool {
        self.loadGeneration += 1
        var didCancelDocumentNavigation = false
        var cancelledResumeAt = self.pendingSeek
        var cancelledSelectedGeneration = false
        if let generation = self.documentGeneration.pendingGeneration {
            cancelledSelectedGeneration = true
            cancelledResumeAt = self.pendingSeeksByGeneration[generation] ?? cancelledResumeAt
            self.pendingSeeksByGeneration.removeValue(forKey: generation)
            self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
            self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
            self.pendingSeekRetryCounts.removeValue(forKey: generation)
            self.directSeekGenerations.remove(generation)
            self.documentGeneration.cancelPendingNavigation()
            didCancelDocumentNavigation = true
        }
        if let generation = self.documentGeneration.inFlightGeneration,
           self.documentGeneration.cancelInFlightNavigation(generation)
        {
            cancelledSelectedGeneration = true
            cancelledResumeAt = self.pendingSeeksByGeneration[generation] ?? cancelledResumeAt
            for (identifier, navigation) in self.documentNavigations
                where navigation.generation == generation
            {
                self.cancelledDocumentNavigations[identifier] = WebPlaybackCancelledNavigation(
                    generation: generation,
                    shouldReportFailure: true
                )
            }
            self.documentNavigations = self.documentNavigations.filter {
                $0.value.generation != generation
            }
            self.pendingSeeksByGeneration.removeValue(forKey: generation)
            self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
            self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
            self.pendingSeekRetryCounts.removeValue(forKey: generation)
            self.directSeekGenerations.remove(generation)
            didCancelDocumentNavigation = true
        }
        let committedLoadingGenerations = self.documentNavigations.values.compactMap { navigation in
            navigation.didCommit && navigation.generation == self.documentGeneration.currentGeneration
                ? navigation.generation
                : nil
        }
        if !committedLoadingGenerations.isEmpty {
            self.documentNavigations = self.documentNavigations.filter { _, navigation in
                !committedLoadingGenerations.contains(navigation.generation)
            }
            for generation in committedLoadingGenerations {
                if !cancelledSelectedGeneration {
                    cancelledResumeAt = self.pendingSeeksByGeneration[generation] ?? cancelledResumeAt
                }
                self.pendingSeeksByGeneration.removeValue(forKey: generation)
                self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
                self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
                self.pendingSeekRetryCounts.removeValue(forKey: generation)
                self.directSeekGenerations.remove(generation)
            }
            didCancelDocumentNavigation = true
        }
        if didCancelDocumentNavigation, let webView = self.webView {
            // PlayerService already owns the newly selected video. Re-authorizing
            // the outgoing document would split native/WebView identity, so keep
            // the selected video as a deferred reload for explicit resume.
            self.pauseSurvivingDocument(webView)
            self.currentVideoId = nil
            self.pendingSeek = nil
            self.documentGeneration.invalidate()
            self.coordinator?.playerService.handleWebNavigationCancellation(
                resumeAtOverride: cancelledResumeAt
            )
            self.refreshDocumentUserScripts(on: webView)
        }
        self.webView?.stopLoading()
        return didCancelDocumentNavigation
    }

    private func load(videoId: String) {
        guard let webView else {
            self.logger.error("YouTube watch load called but webView is nil")
            return
        }

        self.logger.info("Loading YouTube video: \(videoId) (was: \(self.currentVideoId ?? "none"))")
        self.cancelActiveDocumentNavigation(on: webView)
        self.currentVideoId = videoId

        self.loadGeneration += 1
        let navigationPendingSeek = self.pendingSeek
        let replacedGeneration = self.documentGeneration.currentGeneration
        if let replacedAttemptID = self.pendingSeekAttemptIDsByGeneration[replacedGeneration] {
            self.completePendingSeek(
                generation: replacedGeneration,
                attemptID: replacedAttemptID
            )
        }
        self.pendingSeek = navigationPendingSeek
        if let supersededGeneration = self.documentGeneration.pendingGeneration {
            self.pendingSeeksByGeneration.removeValue(forKey: supersededGeneration)
            self.pendingSeekVideoIdsByGeneration.removeValue(forKey: supersededGeneration)
            self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: supersededGeneration)
            self.pendingSeekRetryCounts.removeValue(forKey: supersededGeneration)
            self.directSeekGenerations.remove(supersededGeneration)
        }
        let navigationGeneration = self.documentGeneration.beginNavigation()
        if let navigationPendingSeek {
            self.pendingSeeksByGeneration[navigationGeneration] = navigationPendingSeek
            self.pendingSeekVideoIdsByGeneration[navigationGeneration] = videoId
            self.pendingSeekRetryCounts[navigationGeneration] = 0
            self.beginPendingSeekAttempt(generation: navigationGeneration)
        }
        let targetVolume = self.coordinator?.playerService.volume ?? 1.0
        self.installUserScripts(
            on: webView.configuration.userContentController,
            targetVolume: targetVolume,
            documentGeneration: navigationGeneration,
            pendingSeek: navigationPendingSeek,
            pendingSeekVideoId: navigationPendingSeek == nil ? nil : videoId,
            pendingSeekAttemptID: self.pendingSeekAttemptIDsByGeneration[navigationGeneration]
        )

        guard let url = Self.watchURL(
            videoId: videoId,
            documentGeneration: navigationGeneration
        ) else {
            self.handlePendingDocumentNavigationFailure(webView: webView)
            return
        }
        // Do not wait for WebContent to acknowledge suppression. A provisional
        // process can defer the callback for seconds during rapid replacement;
        // document-generation gates reject stale bridge events and the immediate
        // navigation tears down outgoing media.
        webView.evaluateJavaScript(
            WebPlaybackDocumentGeneration.mediaSuppressionScript,
            completionHandler: nil
        )
        webView.evaluateJavaScript(
            "window.__kasetTargetVolume = \(targetVolume);",
            completionHandler: nil
        )
        self.startDocumentNavigation(
            on: webView,
            request: URLRequest(url: url),
            generation: navigationGeneration,
            pendingSeek: navigationPendingSeek,
            url: url
        )
    }

    /// Stops playback and blanks the page (called when video playback is closed).
    func tearDown() {
        let blankURL = self.beginBlankDocumentNavigation()
        guard let webView else { return }
        self.logger.info("Tearing down YouTube watch WebView")
        self.loadGeneration += 1
        self.currentVideoId = nil
        webView.evaluateJavaScript(
            "window.__kasetStopYTExtraction?.(); document.querySelector('video')?.pause()"
        ) { _, _ in }
        if let blankURL {
            webView.load(URLRequest(url: blankURL))
        }
        webView.removeFromSuperview()
        self.webKitManager?.extensionHostWebViewDidDeactivate(role: .youtubeWatch)
        self.webView = nil
        self.coordinator = nil
        self.currentContainer = nil
        self.usesCookieFreeDataStore = nil
    }
}

extension YouTubeWatchWebView {
    // MARK: - User Scripts

    private func beginBlankDocumentNavigation() -> URL? {
        self.documentNavigations.removeAll()
        self.cancelledDocumentNavigations.removeAll()
        self.continuationGenerationsAwaitingStart.removeAll()
        self.pendingSeeksByGeneration.removeAll()
        self.pendingSeekVideoIdsByGeneration.removeAll()
        self.pendingSeekAttemptIDsByGeneration.removeAll()
        self.cancelledPendingSeekGenerations.removeAll()
        self.directSeekGenerations.removeAll()
        self.pendingSeekRetryCounts.removeAll()
        let generation = self.documentGeneration.beginBlankNavigation()
        return WebPlaybackDocumentGeneration.blankURL(generation: generation)
    }

    func recordAcceptedMainFrameResponse(_ response: URLResponse) {
        guard let currentVideoId = self.currentVideoId else { return }
        _ = self.documentGeneration.recordSuccessfulPlaybackResponse(
            url: response.url,
            host: "www.youtube.com",
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
                playbackHost: "www.youtube.com",
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

    private func refreshDocumentUserScripts(on webView: WKWebView) {
        let targetVolume = self.coordinator?.playerService.volume ?? 1.0
        let scriptGeneration = self.documentGeneration.userScriptGeneration
        let pendingSeek: Double? = if self.documentGeneration.pendingGeneration != nil
            || self.documentGeneration.inFlightGeneration != nil
        {
            self.pendingSeek
        } else {
            nil
        }
        self.installUserScripts(
            on: webView.configuration.userContentController,
            targetVolume: targetVolume,
            documentGeneration: scriptGeneration,
            pendingSeek: pendingSeek,
            pendingSeekVideoId: pendingSeek == nil ? nil : self.currentVideoId,
            pendingSeekAttemptID: pendingSeek == nil
                ? nil
                : self.pendingSeekAttemptIDsByGeneration[scriptGeneration]
        )
    }

    private func startDocumentNavigation(
        on webView: WKWebView,
        request: URLRequest,
        generation: UInt64,
        pendingSeek: Double?,
        url: URL
    ) {
        guard webView === self.webView else {
            if self.documentGeneration.pendingGeneration == generation {
                self.handlePendingDocumentNavigationFailure(webView: webView)
            }
            return
        }
        guard self.documentGeneration.startNavigation(generation) else {
            self.logger.debug("YouTube load superseded before navigation; skipping stale \(url.absoluteString)")
            return
        }
        guard let navigation = webView.load(request) else {
            self.handleCurrentDocumentNavigationFailure(generation, webView: webView)
            return
        }
        self.documentNavigations[ObjectIdentifier(navigation)] = WebPlaybackTrackedNavigation(
            generation: generation,
            pendingSeek: self.pendingSeeksByGeneration[generation] ?? pendingSeek
        )
    }

    private func startBoundNavigationContinuation(
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
            generation: generation,
            pendingSeek: self.pendingSeeksByGeneration[generation]
        )
        self.continuationGenerationsAwaitingStart.remove(generation)
    }

    private func cancelActiveDocumentNavigation(on webView: WKWebView) {
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
        self.pendingSeeksByGeneration.removeValue(forKey: generation)
        self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
        self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
        self.directSeekGenerations.remove(generation)
        self.pendingSeekRetryCounts.removeValue(forKey: generation)
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
                      playbackHost: "www.youtube.com"
                  ) ? self.documentGeneration.inFlightGeneration : nil),
              generation == self.documentGeneration.inFlightGeneration
        else { return }
        self.documentNavigations[ObjectIdentifier(navigation)] = WebPlaybackTrackedNavigation(
            generation: generation,
            pendingSeek: self.pendingSeeksByGeneration[generation]
        )
    }

    func handleDocumentNavigationRedirect(_ navigation: WKNavigation?, webView: WKWebView) {
        guard webView === self.webView,
              let navigation,
              let trackedNavigation = self.documentNavigations[ObjectIdentifier(navigation)],
              trackedNavigation.generation == self.documentGeneration.inFlightGeneration,
              self.documentGeneration.pendingGeneration == nil
        else { return }
        let targetVolume = self.coordinator?.playerService.volume ?? 1.0
        self.installUserScripts(
            on: webView.configuration.userContentController,
            targetVolume: targetVolume,
            documentGeneration: trackedNavigation.generation,
            pendingSeek: trackedNavigation.pendingSeek,
            pendingSeekVideoId: self.pendingSeekVideoIdsByGeneration[trackedNavigation.generation],
            pendingSeekAttemptID: self.pendingSeekAttemptIDsByGeneration[trackedNavigation.generation]
        )
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
               host: "www.youtube.com",
               videoID: currentVideoId
           )
        {
            guard self.documentGeneration.commitNavigation(
                trackedNavigation.generation,
                expectedVideoID: currentVideoId
            ) else { return }
            trackedNavigation.didActivatePlaybackOrigin = true
        } else if WebPlaybackDocumentGeneration.isTrustedIntermediaryURL(webView.url) {
            guard self.documentGeneration.commitIntermediaryNavigation(
                trackedNavigation.generation
            ) else { return }
        }
        self.documentNavigations[ObjectIdentifier(navigation)] = trackedNavigation
        if trackedNavigation.didActivatePlaybackOrigin {
            if self.cancelledPendingSeekGenerations.remove(trackedNavigation.generation) != nil {
                webView.evaluateJavaScript(
                    Self.pendingSeekCancellationScript(
                        documentGeneration: trackedNavigation.generation
                    ),
                    completionHandler: nil
                )
            } else {
                self.injectPendingSeekIfNeeded(
                    generation: trackedNavigation.generation,
                    webView: webView
                )
            }
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
                playbackHost: "www.youtube.com"
            ) && trackedNavigation.generation == self.documentGeneration.inFlightGeneration
        }
        guard self.documentGeneration.canFinishNavigation(
            trackedNavigation.generation
        ) else { return false }
        if trackedNavigation.pendingSeek == nil {
            self.pendingSeeksByGeneration.removeValue(forKey: trackedNavigation.generation)
            self.pendingSeekVideoIdsByGeneration.removeValue(forKey: trackedNavigation.generation)
            self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: trackedNavigation.generation)
            self.pendingSeekRetryCounts.removeValue(forKey: trackedNavigation.generation)
            self.directSeekGenerations.remove(trackedNavigation.generation)
        }
        return true
    }

    private func handleUnexpectedBlankDocumentCommit(
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
            let resumeAt = self.pendingSeeksByGeneration[generation]
            self.documentNavigations = self.documentNavigations.filter {
                $0.value.generation != generation
            }
            self.continuationGenerationsAwaitingStart.remove(generation)
            self.handleCurrentDocumentNavigationFailure(
                generation,
                webView: webView,
                resumeAtOverride: resumeAt
            )
        } else if self.documentGeneration.pendingGeneration != nil {
            self.handlePendingDocumentNavigationFailure(webView: webView)
        } else if self.currentVideoId != nil {
            self.handleCommittedDocumentNavigationFailure(
                self.documentGeneration.currentGeneration,
                webView: webView,
                resumeAtOverride: self.pendingSeek
            )
        }
    }

    private func failDocumentNavigation(_ navigation: WKNavigation?, webView: WKWebView) {
        if let navigation {
            self.cancelledDocumentNavigations.removeValue(forKey: ObjectIdentifier(navigation))
        }
        guard webView === self.webView,
              let navigation,
              let trackedNavigation = self.documentNavigations.removeValue(
                  forKey: ObjectIdentifier(navigation)
              )
        else { return }
        let resumeAt = trackedNavigation.pendingSeek
        self.pendingSeeksByGeneration.removeValue(forKey: trackedNavigation.generation)
        self.pendingSeekVideoIdsByGeneration.removeValue(forKey: trackedNavigation.generation)
        self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: trackedNavigation.generation)
        self.pendingSeekRetryCounts.removeValue(forKey: trackedNavigation.generation)
        self.directSeekGenerations.remove(trackedNavigation.generation)
        if trackedNavigation.didActivatePlaybackOrigin {
            self.handleCommittedDocumentNavigationFailure(
                trackedNavigation.generation,
                webView: webView,
                resumeAtOverride: resumeAt
            )
        } else {
            self.handleCurrentDocumentNavigationFailure(
                trackedNavigation.generation,
                webView: webView,
                resumeAtOverride: resumeAt
            )
        }
    }

    private func handleCurrentDocumentNavigationFailure(
        _ generation: UInt64,
        webView: WKWebView,
        resumeAtOverride: Double? = nil
    ) {
        guard self.documentGeneration.cancelInFlightNavigation(generation) else { return }
        self.pendingSeeksByGeneration.removeValue(forKey: generation)
        self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
        self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
        self.pendingSeekRetryCounts.removeValue(forKey: generation)
        self.directSeekGenerations.remove(generation)
        self.pauseSurvivingDocument(webView)
        self.currentVideoId = nil
        self.documentGeneration.invalidate()
        self.coordinator?.playerService.handleWebNavigationFailure(
            resumeAtOverride: resumeAtOverride
        )
        self.refreshDocumentUserScripts(on: webView)
    }

    private func handlePendingDocumentNavigationFailure(webView: WKWebView) {
        let resumeAt = self.pendingSeek
            ?? self.documentGeneration.pendingGeneration.flatMap { self.pendingSeeksByGeneration[$0] }
        self.documentGeneration.cancelPendingNavigation()
        self.pendingSeeksByGeneration.removeAll()
        self.pendingSeekVideoIdsByGeneration.removeAll()
        self.pendingSeekAttemptIDsByGeneration.removeAll()
        self.cancelledPendingSeekGenerations.removeAll()
        self.directSeekGenerations.removeAll()
        self.pauseSurvivingDocument(webView)
        self.currentVideoId = nil
        self.documentGeneration.invalidate()
        self.coordinator?.playerService.handleWebNavigationFailure(resumeAtOverride: resumeAt)
        self.refreshDocumentUserScripts(on: webView)
    }

    private func handleCommittedDocumentNavigationFailure(
        _ generation: UInt64,
        webView: WKWebView,
        resumeAtOverride: Double? = nil
    ) {
        guard self.documentGeneration.currentGeneration == generation,
              self.documentGeneration.pendingGeneration == nil,
              self.documentGeneration.inFlightGeneration == nil
        else { return }
        self.pauseSurvivingDocument(webView)
        self.currentVideoId = nil
        self.documentGeneration.invalidate()
        self.coordinator?.playerService.handleWebNavigationFailure(
            resumeAtOverride: resumeAtOverride
        )
        self.refreshDocumentUserScripts(on: webView)
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

    private func pauseSurvivingDocument(_ webView: WKWebView) {
        webView.stopLoading()
        self.suppressSurvivingDocumentMedia(webView)
    }

    private func suppressSurvivingDocumentMedia(_ webView: WKWebView) {
        webView.evaluateJavaScript(
            WebPlaybackDocumentGeneration.mediaSuppressionScript,
            completionHandler: nil
        )
    }

    func beginContentProcessRecovery(webView: WKWebView) -> Bool {
        guard webView === self.webView else { return false }
        self.documentNavigations.removeAll()
        self.cancelledDocumentNavigations.removeAll()
        self.documentGeneration.invalidate()
        self.pendingSeeksByGeneration.removeAll()
        self.pendingSeekVideoIdsByGeneration.removeAll()
        self.pendingSeekAttemptIDsByGeneration.removeAll()
        self.directSeekGenerations.removeAll()
        self.pendingSeekRetryCounts.removeAll()
        self.currentVideoId = nil
        return true
    }

    func installUserScripts(
        on contentController: WKUserContentController,
        targetVolume: Double,
        documentGeneration: UInt64,
        pendingSeek: Double? = nil,
        pendingSeekVideoId: String? = nil,
        pendingSeekAttemptID: UInt64? = nil
    ) {
        contentController.removeAllUserScripts()

        let bootstrap = WKUserScript(
            source: Self.pageBootstrapScript(
                targetVolume: targetVolume,
                documentGeneration: documentGeneration,
                pendingSeek: pendingSeek,
                pendingSeekVideoId: pendingSeekVideoId,
                pendingSeekAttemptID: pendingSeekAttemptID
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(bootstrap)

        // Black from first paint — no YouTube layout flash before extraction.
        let blackout = WKUserScript(
            source: Self.blackoutScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(blackout)

        let observer = WKUserScript(
            source: Self.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(observer)

        let extraction = WKUserScript(
            source: Self.extractionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(extraction)
    }
}
