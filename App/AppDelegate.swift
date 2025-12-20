import AppKit
import WebKit

/// App delegate to control application lifecycle behavior.
/// Keeps the app running when windows are closed so audio playback continues.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Persistent WebView for background audio playback.
    /// Kept at app level so it survives window close.
    private var playerWebView: WKWebView?
    private var coordinator: PlayerWebViewCoordinator?

    /// The current video ID being played.
    private(set) var currentVideoId: String?

    func applicationDidFinishLaunching(_: Notification) {
        // Set up window delegate to intercept close and hide instead
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.setupWindowDelegate()
        }
    }

    private func setupWindowDelegate() {
        for window in NSApplication.shared.windows {
            if window.canBecomeMain {
                window.delegate = self
            }
        }
    }

    /// Keep app running when the window is closed (for background audio).
    /// Use Cmd+Q to fully quit.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Handle reopen (clicking dock icon) when all windows are closed.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Reopen the main window if it was closed
            for window in NSApplication.shared.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }

    /// Load a video in the persistent player.
    func loadVideo(videoId: String, webKitManager: WebKitManager, playerService: PlayerService) {
        // Create WebView if needed
        if playerWebView == nil {
            let configuration = webKitManager.createWebViewConfiguration()

            coordinator = PlayerWebViewCoordinator(playerService: playerService)

            // Add script message handler for state updates
            configuration.userContentController.add(coordinator!, name: "persistentPlayer")

            // Inject observer script
            let script = WKUserScript(
                source: Self.observerScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(script)

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            webView.navigationDelegate = coordinator
            webView.customUserAgent = WebKitManager.userAgent

            #if DEBUG
                webView.isInspectable = true
            #endif

            playerWebView = webView
        }

        // Load the video if different
        if currentVideoId != videoId {
            currentVideoId = videoId
            let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)")!
            playerWebView?.load(URLRequest(url: url))
        }
    }

    /// Get the current player WebView (for display in UI).
    var webView: WKWebView? {
        playerWebView
    }

    /// Store a WebView created by MiniPlayerWebView for persistence.
    func storeWebView(_ webView: WKWebView, videoId: String) {
        playerWebView = webView
        currentVideoId = videoId
    }

    // Script to observe playback state
    private static var observerScript: String {
        """
        (function() {
            'use strict';
            const bridge = window.webkit.messageHandlers.persistentPlayer;

            function waitForPlayerBar() {
                const playerBar = document.querySelector('ytmusic-player-bar');
                if (playerBar) {
                    setupObserver(playerBar);
                    return;
                }
                setTimeout(waitForPlayerBar, 500);
            }

            function setupObserver(playerBar) {
                const observer = new MutationObserver(sendUpdate);
                observer.observe(playerBar, {
                    attributes: true, characterData: true,
                    childList: true, subtree: true
                });
                sendUpdate();
                setInterval(sendUpdate, 1000);
            }

            function sendUpdate() {
                try {
                    const titleEl = document.querySelector('.ytmusic-player-bar.title');
                    const artistEl = document.querySelector('.ytmusic-player-bar.byline');
                    const progressBar = document.querySelector('#progress-bar');
                    const playPauseBtn = document.querySelector('.play-pause-button.ytmusic-player-bar');

                    const isPlaying = playPauseBtn ?
                        (playPauseBtn.getAttribute('title') === 'Pause' ||
                         playPauseBtn.getAttribute('aria-label') === 'Pause') : false;

                    bridge.postMessage({
                        type: 'STATE_UPDATE',
                        title: titleEl ? titleEl.textContent : '',
                        artist: artistEl ? artistEl.textContent : '',
                        progress: progressBar ? parseInt(progressBar.getAttribute('value') || '0') : 0,
                        duration: progressBar ? parseInt(progressBar.getAttribute('aria-valuemax') || '0') : 0,
                        isPlaying: isPlaying
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
}

// MARK: - Player WebView Coordinator

final class PlayerWebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var webView: WKWebView?
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

        Task { @MainActor in
            self.playerService.updatePlaybackState(
                isPlaying: isPlaying,
                progress: Double(progress),
                duration: Double(duration)
            )
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    /// Intercept window close and hide instead, keeping WebView alive for background audio.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide the window instead of closing it
        sender.orderOut(nil)
        return false // Don't actually close
    }
}
