import Foundation
import Observation
import os
import WebKit

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - WebViewCoordinator

/// Non-isolated coordinator to handle WebKit delegate callbacks.
/// This avoids Swift 6 concurrency issues with @MainActor and WebKit delegates.
private final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var playerService: PlayerService?
    private let logger = DiagnosticsLogger.player

    init(playerService: PlayerService) {
        self.playerService = playerService
        super.init()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "unknown"
        Task { @MainActor in
            self.logger.info("WebView finished loading: \(url)")
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "unknown"
        Task { @MainActor in
            self.logger.debug("WebView started loading: \(url)")
        }
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.playerService?.handleNavigationError(error)
        }
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.logger.error("WebView provisional navigation failed: \(error.localizedDescription)")
            self?.playerService?.handleNavigationError(error)
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Copy the body synchronously before dispatching
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else {
            Task { @MainActor in
                self.logger.warning("Received invalid bridge message: \(String(describing: message.body))")
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.logger.debug("Received bridge message: \(type)")
            self?.playerService?.handleBridgeMessage(type: type, body: body)
        }
    }
}

// MARK: - PlayerService

/// Controls music playback via a hidden WKWebView.
@MainActor
@Observable
final class PlayerService: NSObject {
    /// Current playback state.
    enum PlaybackState: Equatable, Sendable {
        case idle
        case loading
        case playing
        case paused
        case buffering
        case ended
        case error(String)

        var isPlaying: Bool {
            self == .playing
        }
    }

    // MARK: - Observable State

    /// Current playback state.
    private(set) var state: PlaybackState = .idle

    /// Currently playing track.
    private(set) var currentTrack: Song?

    /// Whether playback is active.
    var isPlaying: Bool { state.isPlaying }

    /// Current playback position in seconds.
    private(set) var progress: TimeInterval = 0

    /// Total duration of current track in seconds.
    private(set) var duration: TimeInterval = 0

    /// Current volume (0.0 - 1.0).
    private(set) var volume: Double = 1.0

    /// Playback queue.
    private(set) var queue: [Song] = []

    /// Index of current track in queue.
    private(set) var currentIndex: Int = 0

    /// Whether the mini player should be shown (user needs to interact to start playback).
    var showMiniPlayer: Bool = false

    /// The video ID that needs to be played in the mini player.
    private(set) var pendingPlayVideoId: String?

    // MARK: - Private Properties

    private var webView: WKWebView?
    private var coordinator: WebViewCoordinator?
    private var isWebViewReady = false
    private var isWebViewSetup = false
    private var pendingVideoId: String?
    private let logger = DiagnosticsLogger.player

    // MARK: - Initialization

    override init() {
        super.init()
        // Setup WebView immediately
        setupWebView()
    }

    private func ensureWebViewSetup() {
        if !isWebViewSetup {
            setupWebView()
        }
    }

    private func setupWebView() {
        guard !isWebViewSetup else { return }
        isWebViewSetup = true

        // Create coordinator first
        let coordinator = WebViewCoordinator(playerService: self)
        self.coordinator = coordinator

        let configuration = WebKitManager.shared.createWebViewConfiguration()

        // Setup user content controller for JS bridge
        let contentController = configuration.userContentController
        contentController.add(coordinator, name: "ytmBridge")

        // Inject our player control script at document end
        let controlScript = WKUserScript(
            source: playerControlScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(controlScript)

        // Create WebView
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = coordinator
        #if DEBUG
            webView.isInspectable = true
        #endif
        self.webView = webView

        // Just mark as ready - we'll navigate when playing
        isWebViewReady = true
        logger.info("WebView setup complete, ready for playback")
    }

    /// Script injected into YouTube Music watch pages to control playback
    private var playerControlScript: String {
        """
        (function() {
            'use strict';

            const bridge = window.webkit.messageHandlers.ytmBridge;
            let videoElement = null;
            let ytPlayer = null;
            let setupComplete = false;
            let retryCount = 0;
            const maxRetries = 30;

            function log(msg) {
                console.log('[YTM Bridge] ' + msg);
                bridge.postMessage({ type: 'LOG', message: msg });
            }

            // Try to get YouTube's player API
            function getYTPlayer() {
                // YouTube Music uses a movie_player element with a player API
                const player = document.getElementById('movie_player');
                if (player && typeof player.getPlayerState === 'function') {
                    return player;
                }
                return null;
            }

            // Wait for video element and player to be available
            function waitForPlayer() {
                retryCount++;
                const video = document.querySelector('video');
                ytPlayer = getYTPlayer();

                log('Waiting for player... attempt ' + retryCount + ', video=' + !!video + ', ytPlayer=' + !!ytPlayer);

                if (video && ytPlayer && !setupComplete) {
                    videoElement = video;
                    setupComplete = true;
                    log('Player and video found!');
                    setupVideoListeners(video);

                    // Check current state
                    const state = ytPlayer.getPlayerState();
                    log('Initial player state: ' + state);

                    // States: -1=unstarted, 0=ended, 1=playing, 2=paused, 3=buffering, 5=cued
                    if (state === -1 || state === 5) {
                        // Try to start playback
                        log('Attempting to start playback...');
                        tryAutoPlay();
                    } else if (state === 2) {
                        log('Player is paused, attempting resume...');
                        tryAutoPlay();
                    }
                    return;
                }

                if (retryCount < maxRetries && !setupComplete) {
                    setTimeout(waitForPlayer, 500);
                } else if (!setupComplete) {
                    log('Max retries reached, player not fully initialized');
                    // Try with just video element
                    if (video) {
                        videoElement = video;
                        setupVideoListeners(video);
                        tryAutoPlay();
                    }
                }
            }

            function tryAutoPlay() {
                log('tryAutoPlay called');

                // Method 1: YouTube's movie_player API
                if (ytPlayer && typeof ytPlayer.playVideo === 'function') {
                    log('Using ytPlayer.playVideo()');
                    try {
                        ytPlayer.playVideo();
                        setTimeout(() => {
                            const state = ytPlayer.getPlayerState ? ytPlayer.getPlayerState() : 'unknown';
                            log('After playVideo, state=' + state);
                        }, 500);
                        return;
                    } catch (e) {
                        log('ytPlayer.playVideo() failed: ' + e);
                    }
                }

                // Method 2: Click play/pause button
                const playButton = document.querySelector('.play-pause-button') ||
                                   document.querySelector('tp-yt-paper-icon-button.play-pause-button') ||
                                   document.querySelector('.ytp-play-button');
                if (playButton) {
                    log('Clicking play button');
                    playButton.click();
                    return;
                }

                // Method 3: Direct video.play()
                if (videoElement) {
                    log('Direct video.play()');
                    const playPromise = videoElement.play();
                    if (playPromise !== undefined) {
                        playPromise.then(() => {
                            log('Video.play() succeeded');
                        }).catch(e => {
                            log('Video.play() failed: ' + e.name + ' - ' + e.message);
                        });
                    }
                }
            }

            function setupVideoListeners(video) {
                bridge.postMessage({ type: 'VIDEO_READY' });

                video.addEventListener('play', () => {
                    log('Event: play');
                    sendState(1);
                });
                video.addEventListener('pause', () => {
                    log('Event: pause');
                    sendState(2);
                });
                video.addEventListener('ended', () => {
                    log('Event: ended');
                    sendState(0);
                });
                video.addEventListener('waiting', () => sendState(3));
                video.addEventListener('playing', () => {
                    log('Event: playing');
                    sendState(1);
                });
                video.addEventListener('error', (e) => {
                    log('Video error: ' + (e.target.error ? e.target.error.message : 'unknown'));
                });

                // Send initial state
                sendState(video.paused ? 2 : 1);

                // Periodic updates
                setInterval(() => sendState(video.paused ? 2 : 1), 1000);
            }

            function sendState(state) {
                if (!videoElement) return;
                bridge.postMessage({
                    type: 'STATE_UPDATE',
                    state: state,
                    currentTime: videoElement.currentTime || 0,
                    duration: videoElement.duration || 0,
                    volume: Math.round(videoElement.volume * 100)
                });
            }

            // Expose control functions globally for Swift to call
            window.ytmControl = {
                play: function() {
                    log('ytmControl.play() called');
                    if (ytPlayer && ytPlayer.playVideo) {
                        ytPlayer.playVideo();
                    } else if (videoElement) {
                        videoElement.play();
                    }
                },
                pause: function() {
                    log('ytmControl.pause() called');
                    if (ytPlayer && ytPlayer.pauseVideo) {
                        ytPlayer.pauseVideo();
                    } else if (videoElement) {
                        videoElement.pause();
                    }
                },
                seek: function(time) {
                    if (ytPlayer && ytPlayer.seekTo) {
                        ytPlayer.seekTo(time, true);
                    } else if (videoElement) {
                        videoElement.currentTime = time;
                    }
                },
                setVolume: function(vol) {
                    if (ytPlayer && ytPlayer.setVolume) {
                        ytPlayer.setVolume(vol);
                    } else if (videoElement) {
                        videoElement.volume = vol / 100;
                    }
                },
                getState: function() {
                    if (ytPlayer && ytPlayer.getPlayerState) {
                        return ytPlayer.getPlayerState();
                    }
                    return videoElement ? (videoElement.paused ? 2 : 1) : -1;
                }
            };

            // Start looking for the player
            log('Script loaded, waiting for player...');
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', waitForPlayer);
            } else {
                waitForPlayer();
            }
        })();
        """
    }

    // MARK: - Internal Methods (called from coordinator)

    func handleNavigationError(_ error: Error) {
        logger.error("WebView navigation failed: \(error.localizedDescription)")
        state = .error(error.localizedDescription)
    }

    func handleBridgeMessage(type: String, body: [String: Any]) {
        switch type {
        case "VIDEO_READY":
            logger.info("Video element ready on watch page")
            // Try to trigger play after video is ready
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await evaluatePlayerCommand("play")
            }

        case "STATE_UPDATE":
            handleStateUpdate(body)

        case "LOG":
            if let message = body["message"] as? String {
                logger.debug("JS: \(message)")
            }

        case "ERROR":
            if let errorCode = body["error"] as? Int {
                logger.error("Player error: \(errorCode)")
                state = .error("Player error: \(errorCode)")
            }

        default:
            logger.debug("Unknown bridge message type: \(type)")
        }
    }

    private func handleStateUpdate(_ body: [String: Any]) {
        // States: 0 = ended, 1 = playing, 2 = paused, 3 = buffering
        guard let playerState = body["state"] as? Int else { return }

        if let currentTime = body["currentTime"] as? Double {
            progress = currentTime
        }
        if let dur = body["duration"] as? Double, dur > 0 {
            duration = dur
        }
        if let vol = body["volume"] as? Int {
            volume = Double(vol) / 100.0
        }

        switch playerState {
        case 0:
            state = .ended
            logger.debug("Playback ended")
        case 1:
            state = .playing
            logger.debug("Playing: \(self.progress)/\(self.duration)")
        case 2:
            state = .paused
            logger.debug("Paused at \(self.progress)")
        case 3:
            state = .buffering
            logger.debug("Buffering")
        default:
            break
        }
    }

    // MARK: - Public Methods

    /// Plays a track by video ID.
    func play(videoId: String) async {
        ensureWebViewSetup()
        logger.info("Playing video: \(videoId)")
        state = .loading

        // Create a minimal Song object for now
        currentTrack = Song(
            id: videoId,
            title: "Loading...",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: videoId
        )

        // Show the mini player for user interaction
        pendingPlayVideoId = videoId
        showMiniPlayer = true
        logger.info("Showing mini player for user to start playback")
    }

    /// Plays a song.
    func play(song: Song) async {
        ensureWebViewSetup()
        logger.info("Playing song: \(song.title)")
        state = .loading
        currentTrack = song

        // Show the mini player for user interaction
        pendingPlayVideoId = song.videoId
        showMiniPlayer = true
        logger.info("Showing mini player for user to start playback")
    }

    /// Called when the mini player confirms playback has started.
    func confirmPlaybackStarted() {
        showMiniPlayer = false
        state = .playing
        logger.info("Playback confirmed started")
    }

    /// Called when the mini player is dismissed.
    func miniPlayerDismissed() {
        showMiniPlayer = false
        if state == .loading {
            state = .idle
        }
    }

    /// Updates playback state from the persistent WebView observer.
    func updatePlaybackState(isPlaying: Bool, progress: Double, duration: Double) {
        self.progress = progress
        self.duration = duration
        if isPlaying {
            state = .playing
        } else if state == .playing {
            state = .paused
        }
    }

    /// Toggles play/pause.
    func playPause() async {
        logger.debug("Toggle play/pause")

        if isPlaying {
            await pause()
        } else {
            await resume()
        }
    }

    /// Pauses playback.
    func pause() async {
        logger.debug("Pausing playback")
        await evaluatePlayerCommand("pause")
    }

    /// Resumes playback.
    func resume() async {
        logger.debug("Resuming playback")
        await evaluatePlayerCommand("play")
    }

    /// Skips to next track.
    func next() async {
        logger.debug("Skipping to next track")
        // IFrame API doesn't have next/previous - we'll need to manage queue ourselves
        if currentIndex < queue.count - 1 {
            currentIndex += 1
            if let nextSong = queue[safe: currentIndex] {
                await play(song: nextSong)
            }
        }
    }

    /// Goes to previous track.
    func previous() async {
        logger.debug("Going to previous track")
        // If more than 3 seconds in, restart. Otherwise go to previous.
        if progress > 3 {
            await seek(to: 0)
        } else if currentIndex > 0 {
            currentIndex -= 1
            if let prevSong = queue[safe: currentIndex] {
                await play(song: prevSong)
            }
        } else {
            await seek(to: 0)
        }
    }

    /// Seeks to a specific time.
    func seek(to time: TimeInterval) async {
        logger.debug("Seeking to \(time)")
        await evaluatePlayerCommand("seekTo(\(time), true)")
    }

    /// Sets the volume.
    func setVolume(_ value: Double) async {
        let clampedValue = max(0, min(1, value))
        logger.debug("Setting volume to \(clampedValue)")
        volume = clampedValue
        await evaluatePlayerCommand("setVolume(\(Int(clampedValue * 100)))")
    }

    /// Stops playback and clears state.
    func stop() async {
        logger.debug("Stopping playback")
        await evaluatePlayerCommand("pauseVideo()")
        state = .idle
        currentTrack = nil
        progress = 0
        duration = 0
    }

    /// Plays a queue of songs starting at the specified index.
    func playQueue(_ songs: [Song], startingAt index: Int = 0) async {
        guard !songs.isEmpty else { return }
        let safeIndex = max(0, min(index, songs.count - 1))
        queue = songs
        currentIndex = safeIndex
        if let song = songs[safe: safeIndex] {
            await play(song: song)
        }
    }

    // MARK: - Private Methods

    private func loadVideo(_ videoId: String) async {
        logger.info("loadVideo called with videoId: \(videoId)")

        if isWebViewReady {
            await loadVideoInPlayer(videoId)
        } else {
            // Queue it up for when player is ready
            pendingVideoId = videoId
            logger.info("Player not ready yet, queuing video: \(videoId)")
        }
    }

    private func loadVideoInPlayer(_ videoId: String) async {
        guard let webView else {
            logger.error("No WebView available")
            return
        }

        // Navigate to the YouTube Music watch page - this uses our authenticated cookies
        let watchURL = URL(string: "https://music.youtube.com/watch?v=\(videoId)")!
        logger.info("Navigating to watch page: \(watchURL.absoluteString)")
        state = .loading

        webView.load(URLRequest(url: watchURL))
        // The injected script will auto-play and send state updates
    }

    private func evaluatePlayerCommand(_ command: String) async {
        guard let webView else { return }

        // Use the ytmControl object we injected, with fallback to direct video control
        let script: String
        switch command {
        case "pause", "pauseVideo()":
            script = """
                if (window.ytmControl) { window.ytmControl.pause(); }
                else { document.querySelector('video')?.pause(); }
            """
        case "play", "playVideo()":
            script = """
                if (window.ytmControl) { window.ytmControl.play(); }
                else { document.querySelector('video')?.play(); }
            """
        default:
            // Handle seekTo and setVolume
            if command.hasPrefix("seekTo(") {
                let timeStr = command.dropFirst(7).prefix(while: { $0 != "," && $0 != ")" })
                script = """
                    if (window.ytmControl) { window.ytmControl.seek(\(timeStr)); }
                    else { document.querySelector('video').currentTime = \(timeStr); }
                """
            } else if command.hasPrefix("setVolume(") {
                let volStr = command.dropFirst(10).dropLast()
                script = """
                    if (window.ytmControl) { window.ytmControl.setVolume(\(volStr)); }
                    else { document.querySelector('video').volume = \(volStr) / 100; }
                """
            } else {
                script = command
            }
        }

        do {
            _ = try await webView.evaluateJavaScript(script)
        } catch {
            logger.error("JavaScript evaluation error for '\(command)': \(error.localizedDescription)")
        }
    }
}
