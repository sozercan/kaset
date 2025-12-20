import SwiftUI
import WebKit

/// A visible WebView that displays the YouTube Music player.
/// This is required because YouTube Music won't initialize the video player
/// without user interaction - autoplay is blocked in hidden WebViews.
/// The WebView is stored in AppDelegate for persistence after the view is dismissed.
struct MiniPlayerWebView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager

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
        Coordinator(onStateChange: onStateChange, onMetadataChange: onMetadataChange)
    }

    func makeNSView(context: Context) -> NSView {
        // Create a container view - this will be destroyed when toast is dismissed,
        // but the WebView inside will be reparented to the persistent container
        let container = NSView(frame: .zero)
        container.wantsLayer = true

        // Get or create the WebView
        let webView: WKWebView
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let existingWebView = appDelegate.webView
        {
            // Reuse existing WebView - just reparent it
            existingWebView.removeFromSuperview()
            webView = existingWebView

            // Load new video if different
            if appDelegate.currentVideoId != videoId {
                let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)")!
                webView.load(URLRequest(url: url))
                appDelegate.storeWebView(webView, videoId: videoId)
            }
        } else {
            // Create new WebView
            let configuration = webKitManager.createWebViewConfiguration()

            // Add script message handler
            configuration.userContentController.add(context.coordinator, name: "miniPlayer")

            // Inject our observer script
            let script = WKUserScript(
                source: Self.observerScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(script)

            webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = context.coordinator
            webView.customUserAgent = WebKitManager.userAgent

            #if DEBUG
                webView.isInspectable = true
            #endif

            // Store in AppDelegate for persistence
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.storeWebView(webView, videoId: videoId)
            }

            // Load the watch page
            let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)")!
            webView.load(URLRequest(url: url))
        }

        // Add WebView to container
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        // Update WebView frame if needed
        if let webView = container.subviews.first as? WKWebView {
            webView.frame = container.bounds
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator _: Coordinator) {
        // When this container is removed, the WebView needs to be reparented
        // to the persistent container. Just remove it from this container -
        // PersistentWebViewContainer will reclaim it.
        if let webView = container.subviews.first as? WKWebView {
            webView.removeFromSuperview()
            // The WebView is still held by AppDelegate, so it won't be deallocated
        }
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
            onStateChange?(.error(error.localizedDescription))
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
                    onMetadataChange?(title, artist, duration)
                }

                onStateChange?(isPlaying ? .playing : .paused)
            }
        }
    }
}

// MARK: - Persistent Player WebView

/// A WebView that stays in the view hierarchy to keep audio playing.
/// This is hidden (1x1 pixel, opacity 0) but remains active.
struct PersistentPlayerWebView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    let videoId: String

    func makeCoordinator() -> Coordinator {
        Coordinator(playerService: playerService)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = webKitManager.createWebViewConfiguration()

        // Add script message handler for state updates
        configuration.userContentController.add(context.coordinator, name: "persistentPlayer")

        // Inject observer script
        let script = WKUserScript(
            source: Self.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = WebKitManager.userAgent

        // Store reference in coordinator for later use
        context.coordinator.webView = webView

        // Load the watch page
        let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)")!
        webView.load(URLRequest(url: url))

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Check if we need to load a new video
        if let currentURL = webView.url,
           !currentURL.absoluteString.contains(videoId)
        {
            let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)")!
            webView.load(URLRequest(url: url))
        }
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

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let playerService: PlayerService

        init(playerService: PlayerService) {
            self.playerService = playerService
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String,
                  type == "STATE_UPDATE"
            else { return }

            let isPlaying = body["isPlaying"] as? Bool ?? false
            let progress = body["progress"] as? Int ?? 0
            let duration = body["duration"] as? Int ?? 0

            Task { @MainActor in
                if isPlaying {
                    self.playerService.updatePlaybackState(isPlaying: true, progress: Double(progress), duration: Double(duration))
                } else {
                    self.playerService.updatePlaybackState(isPlaying: false, progress: Double(progress), duration: Double(duration))
                }
            }
        }
    }
}

// MARK: - Compact Play Toast

/// A very small, unobtrusive toast that appears to let the user start playback.
/// YouTube Music requires a user gesture, so we show this minimal popup.
struct CompactPlayToast: View {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    let videoId: String

    @State private var playbackStarted = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Show the WebView for user to click play
            MiniPlayerWebView(
                videoId: videoId,
                onStateChange: { state in
                    if case .playing = state {
                        if !playbackStarted {
                            playbackStarted = true
                            // Transfer WebView to AppDelegate and dismiss
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                playerService.confirmPlaybackStarted()
                            }
                        }
                    }
                }
            )
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Small dismiss button
            Button {
                playerService.confirmPlaybackStarted()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(4)
        }
        .frame(width: 160, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

// MARK: - AppDelegate WebView Wrapper

/// Wraps the AppDelegate's persistent WebView for display in SwiftUI.
/// Used in the toast popup to show the WebView for user interaction.
struct AppDelegateWebViewWrapper: NSViewRepresentable {
    let videoId: String
    let playerService: PlayerService
    let webKitManager: WebKitManager

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        // Get the WebView from AppDelegate (should already exist from PersistentWebViewContainer)
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let webView = appDelegate.webView
        {
            // Temporarily reparent the webView to this container for display
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Update WebView frame if needed
        if let webView = nsView.subviews.first {
            webView.frame = nsView.bounds
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // When this view is removed, move the WebView back to the persistent container
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let webView = appDelegate.webView
        {
            // The PersistentWebViewContainer will reclaim it
            webView.removeFromSuperview()
        }
    }
}

// MARK: - Persistent WebView Container

/// A hidden container that keeps the AppDelegate's WebView in the view hierarchy.
/// The WebView must stay in a window's view hierarchy for audio playback to work.
struct PersistentWebViewContainer: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        context.coordinator.container = container

        // Claim the WebView if it exists and isn't shown elsewhere
        reclaimWebViewIfNeeded(into: container)

        // Start a timer to periodically check if we need to reclaim the WebView
        context.coordinator.startTimer()

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        reclaimWebViewIfNeeded(into: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopTimer()
    }

    private func reclaimWebViewIfNeeded(into container: NSView) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let webView = appDelegate.webView,
           webView.superview == nil
        {
            webView.frame = container.bounds
            container.addSubview(webView)
        }
    }

    @MainActor
    class Coordinator {
        weak var container: NSView?
        private var timer: Timer?

        func startTimer() {
            // Check every 100ms if we need to reclaim the WebView
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.checkAndReclaim()
                }
            }
        }

        func stopTimer() {
            timer?.invalidate()
            timer = nil
        }

        private func checkAndReclaim() {
            guard let container else { return }

            if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
               let webView = appDelegate.webView,
               webView.superview == nil
            {
                webView.frame = container.bounds
                container.addSubview(webView)
            }
        }
    }
}

// MARK: - Singleton WebView Manager

/// Manages a single WebView instance for the entire app lifetime.
/// This ensures there's only ever ONE WebView playing audio.
@MainActor
final class SingletonPlayerWebView {
    static let shared = SingletonPlayerWebView()

    private(set) var webView: WKWebView?
    var currentVideoId: String?
    private var coordinator: Coordinator?
    private let logger = DiagnosticsLogger.player

    private init() {}

    /// Get or create the singleton WebView.
    func getWebView(
        webKitManager: WebKitManager,
        playerService: PlayerService
    ) -> WKWebView {
        if let existing = webView {
            return existing
        }

        logger.info("Creating singleton WebView")

        // Create coordinator
        coordinator = Coordinator(playerService: playerService)

        let configuration = webKitManager.createWebViewConfiguration()

        // Add script message handler
        configuration.userContentController.add(coordinator!, name: "singletonPlayer")

        // Inject observer script
        let script = WKUserScript(
            source: Self.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = coordinator
        newWebView.customUserAgent = WebKitManager.userAgent

        #if DEBUG
            newWebView.isInspectable = true
        #endif

        webView = newWebView
        return newWebView
    }

    /// Load a video, stopping any currently playing audio first.
    func loadVideo(videoId: String) {
        guard let webView = webView else {
            logger.error("loadVideo called but webView is nil")
            return
        }

        let previousVideoId = currentVideoId
        guard videoId != previousVideoId else {
            logger.info("Video \(videoId) already loaded, skipping")
            return
        }

        logger.info("Loading video: \(videoId) (was: \(previousVideoId ?? "none"))")

        // Update currentVideoId immediately to prevent duplicate loads
        currentVideoId = videoId

        // Stop current playback first, then load new video
        let urlToLoad = URL(string: "https://music.youtube.com/watch?v=\(videoId)")!
        webView.evaluateJavaScript("document.querySelector('video')?.pause()") { [weak self] _, _ in
            self?.webView?.load(URLRequest(url: urlToLoad))
        }
    }

    // Observer script for playback state
    private static var observerScript: String {
        """
        (function() {
            'use strict';
            const bridge = window.webkit.messageHandlers.singletonPlayer;

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
                    const playPauseBtn = document.querySelector('.play-pause-button.ytmusic-player-bar');
                    const isPlaying = playPauseBtn ?
                        (playPauseBtn.getAttribute('title') === 'Pause' ||
                         playPauseBtn.getAttribute('aria-label') === 'Pause') : false;

                    const progressBar = document.querySelector('#progress-bar');

                    bridge.postMessage({
                        type: 'STATE_UPDATE',
                        isPlaying: isPlaying,
                        progress: progressBar ? parseInt(progressBar.getAttribute('value') || '0') : 0,
                        duration: progressBar ? parseInt(progressBar.getAttribute('aria-valuemax') || '0') : 0
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

            Task { @MainActor in
                self.playerService.updatePlaybackState(
                    isPlaying: isPlaying,
                    progress: Double(progress),
                    duration: Double(duration)
                )
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            DiagnosticsLogger.player.info("Singleton WebView finished loading: \(webView.url?.absoluteString ?? "nil")")
        }
    }
}

// MARK: - Persistent Player View

/// A SwiftUI view that displays the singleton WebView.
/// The WebView is created once and reused for all playback.
struct PersistentPlayerView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    let videoId: String
    let isExpanded: Bool

    private let logger = DiagnosticsLogger.player

    func makeNSView(context: Context) -> NSView {
        logger.info("PersistentPlayerView.makeNSView for videoId: \(videoId)")

        let container = NSView(frame: .zero)
        container.wantsLayer = true

        // Get or create the singleton WebView
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: webKitManager,
            playerService: playerService
        )

        // Remove from any previous superview and add to this container
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        // Load the video if needed
        if SingletonPlayerWebView.shared.currentVideoId != videoId {
            let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)")!
            logger.info("Initial load: \(url.absoluteString)")
            webView.load(URLRequest(url: url))
            SingletonPlayerWebView.shared.currentVideoId = videoId
        }

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        logger.info("PersistentPlayerView.updateNSView for videoId: \(videoId)")

        // Ensure WebView is in this container
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: webKitManager,
            playerService: playerService
        )

        if webView.superview !== container {
            logger.info("Re-parenting WebView to current container")
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }

        webView.frame = container.bounds

        // Load new video if changed
        SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
    }
}

// MARK: - Mini Player Popup

/// A small popup overlay prompting user to click play.
struct MiniPlayerPopup: View {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    let videoId: String
    let songTitle: String

    @State private var playbackDetected = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("🎵 \(songTitle)")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button {
                    playerService.miniPlayerDismissed()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Visible mini WebView for user interaction
            MiniPlayerWebView(
                videoId: videoId,
                onStateChange: { state in
                    if case .playing = state {
                        if !playbackDetected {
                            playbackDetected = true
                            // Auto-dismiss after playback starts
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                playerService.confirmPlaybackStarted()
                            }
                        }
                    }
                }
            )
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Click play above to start music")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 350)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
    }
}

// MARK: - Mini Player Sheet View (Legacy - kept for reference)

/// A compact sheet that shows the YouTube Music player for a specific video.
/// Auto-dismisses once playback starts.
struct MiniPlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    let videoId: String
    let songTitle: String

    @State private var isPlaying = false
    @State private var playbackStarted = false

    var body: some View {
        VStack(spacing: 8) {
            // Compact header
            HStack {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                Text("Click play to start")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    playerService.miniPlayerDismissed()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Compact WebView - just show the player controls
            MiniPlayerWebView(
                videoId: videoId,
                onStateChange: { state in
                    if case .playing = state {
                        if !playbackStarted {
                            playbackStarted = true
                            // Auto-dismiss after a short delay once playing
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                playerService.confirmPlaybackStarted()
                                dismiss()
                            }
                        }
                        isPlaying = true
                    }
                }
            )
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(8)
        .frame(width: 320, height: 180)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    MiniPlayerSheet(videoId: "dQw4w9WgXcQ", songTitle: "Test Song")
        .environment(WebKitManager.shared)
        .environment(PlayerService())
}
