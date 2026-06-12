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
    var currentVideoId: String?
    var coordinator: Coordinator?
    let logger = DiagnosticsLogger.player

    private init() {}

    /// Get or create the watch WebView.
    func getWebView(
        webKitManager: WebKitManager,
        playerService: YouTubePlayerService
    ) -> WKWebView {
        if let existing = webView {
            return existing
        }

        self.logger.info("Creating YouTube watch WebView")

        self.coordinator = Coordinator(playerService: playerService)

        let configuration = webKitManager.createWebViewConfiguration()
        configuration.userContentController.add(self.coordinator!, name: "youtubePlayer")
        self.installUserScripts(
            on: configuration.userContentController,
            targetVolume: playerService.volume
        )

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = self.coordinator
        newWebView.customUserAgent = WebKitManager.userAgent

        // Kill the white flash between page navigations.
        newWebView.underPageBackgroundColor = .black

        #if DEBUG
            newWebView.isInspectable = true
        #endif

        self.webView = newWebView
        return newWebView
    }

    /// Ensures the WebView fills the given container (reparenting if needed).
    func ensureInHierarchy(container: NSView) {
        guard let webView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
    }

    /// Loads a watch page for the given video.
    func loadVideo(videoId: String) {
        guard let webView else {
            self.logger.error("YouTube watch loadVideo called but webView is nil")
            return
        }

        guard videoId != self.currentVideoId else {
            self.logger.debug("YouTube video \(videoId) already loaded, skipping")
            return
        }

        self.logger.info("Loading YouTube video: \(videoId) (was: \(self.currentVideoId ?? "none"))")
        self.currentVideoId = videoId

        let targetVolume = self.coordinator?.playerService.volume ?? 1.0
        self.installUserScripts(
            on: webView.configuration.userContentController,
            targetVolume: targetVolume
        )

        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return }
        webView.evaluateJavaScript("document.querySelector('video')?.pause()") { [weak self] _, _ in
            guard let self, let webView = self.webView else { return }
            webView.evaluateJavaScript("window.__kasetTargetVolume = \(targetVolume);", completionHandler: nil)
            webView.load(URLRequest(url: url))
        }
    }

    /// Stops playback and blanks the page (called when video playback is closed).
    func tearDown() {
        guard let webView else { return }
        self.logger.info("Tearing down YouTube watch WebView")
        self.currentVideoId = nil
        webView.evaluateJavaScript("document.querySelector('video')?.pause()") { _, _ in }
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }

    // MARK: - User Scripts

    private func installUserScripts(
        on contentController: WKUserContentController,
        targetVolume: Double
    ) {
        contentController.removeAllUserScripts()

        let bootstrap = WKUserScript(
            source: Self.pageBootstrapScript(targetVolume: targetVolume),
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

    /// Document-start state handed to each new watch page.
    nonisolated static func pageBootstrapScript(targetVolume: Double) -> String {
        let clamped = targetVolume.isFinite ? min(max(targetVolume, 0), 1) : 1.0
        return "window.__kasetTargetVolume = \(clamped);"
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let playerService: YouTubePlayerService

        init(playerService: YouTubePlayerService) {
            self.playerService = playerService
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            switch type {
            case "STATE_UPDATE":
                let update = YouTubePlayerService.PlaybackUpdate(
                    isPlaying: body["isPlaying"] as? Bool ?? false,
                    progress: body["progress"] as? Double ?? 0,
                    duration: body["duration"] as? Double ?? 0,
                    videoId: (body["videoId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    title: body["title"] as? String,
                    isAd: body["isAd"] as? Bool ?? false
                )
                Task { @MainActor in
                    self.playerService.updatePlaybackState(update)
                }
            case "VIDEO_ENDED":
                let videoId = body["videoId"] as? String
                Task { @MainActor in
                    self.playerService.handleVideoEnded(videoId: videoId)
                }
            default:
                return
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            DiagnosticsLogger.player.info(
                "YouTube watch WebView finished loading: \(webView.url?.absoluteString ?? "nil")"
            )

            let savedVolume = self.playerService.volume
            webView.evaluateJavaScript(
                """
                (function() {
                    window.__kasetTargetVolume = \(savedVolume);
                    const video = document.querySelector('video');
                    if (video) { video.volume = \(savedVolume); }
                    if (window.__kasetExtractVideo) { window.__kasetExtractVideo(); }
                })();
                """,
                completionHandler: nil
            )
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            DiagnosticsLogger.player.error("YouTube watch WebView content process terminated, recovering")
            let videoId = YouTubeWatchWebView.shared.currentVideoId
            webView.reload()
            if let videoId {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    YouTubeWatchWebView.shared.currentVideoId = nil
                    YouTubeWatchWebView.shared.loadVideo(videoId: videoId)
                }
            }
        }
    }
}
