import Foundation
import Observation

// MARK: - YouTubeWatchPlaybackControlling

/// Playback command surface backing `YouTubePlayerService`.
/// The real implementation is `YouTubeWatchWebView`; tests inject a recorder.
@MainActor
protocol YouTubeWatchPlaybackControlling: AnyObject {
    func prepare(webKitManager: WebKitManager, playerService: YouTubePlayerService)
    func loadVideo(videoId: String)
    func playPause()
    func play()
    func pause()
    func seek(to time: Double)
    func setVolume(_ volume: Double)
    func tearDown()
}

// MARK: - YouTubeWatchWebView + YouTubeWatchPlaybackControlling

extension YouTubeWatchWebView: YouTubeWatchPlaybackControlling {
    func prepare(webKitManager: WebKitManager, playerService: YouTubePlayerService) {
        _ = self.getWebView(webKitManager: webKitManager, playerService: playerService)
    }
}

// MARK: - YouTubePlayerService

/// Playback state and control for regular YouTube videos.
///
/// Parallel to `PlayerService` (music) — that service is untouched. The
/// actual playback happens in `YouTubeWatchWebView`; this service owns the
/// observable state, command surface, and the docked/floating placement of
/// the extracted video surface.
@MainActor
@Observable
final class YouTubePlayerService {
    // MARK: - State

    /// The video currently loaded for playback (nil when playback is closed).
    private(set) var currentVideo: YouTubeVideo?

    /// Whether the video is currently playing.
    private(set) var isPlaying = false

    /// Current position in seconds.
    private(set) var progress: Double = 0

    /// Video length in seconds.
    private(set) var duration: Double = 0

    /// Whether an ad is currently showing on the watch page.
    private(set) var isShowingAd = false

    /// Playback volume (0...1).
    var volume: Double = 1.0 {
        didSet {
            guard oldValue != self.volume else { return }
            self.playbackController.setVolume(self.volume)
        }
    }

    /// Where the extracted video surface currently lives.
    enum SurfaceLocation: Equatable {
        case none
        case inline
        case floating
    }

    /// Current surface placement. KasetApp observes this to open/close the
    /// floating window.
    private(set) var surfaceLocation: SurfaceLocation = .none

    /// The videoId of the WatchView that currently owns the inline surface.
    var activeInlineVideoId: String?

    // MARK: - Hooks

    /// Called right before video playback starts (PlaybackArbiter pauses music).
    var playbackWillStart: (() -> Void)?

    /// Called when the current video finishes (WatchView advances to related).
    var onVideoEnded: ((String?) -> Void)?

    // MARK: - Dependencies

    private let webKitManager: WebKitManager
    private let playbackController: any YouTubeWatchPlaybackControlling
    private let logger = DiagnosticsLogger.player

    init(
        webKitManager: WebKitManager = .shared,
        playbackController: (any YouTubeWatchPlaybackControlling)? = nil
    ) {
        self.webKitManager = webKitManager
        self.playbackController = playbackController ?? YouTubeWatchWebView.shared
    }

    // MARK: - Commands

    /// Starts playback of a video, docked inline.
    func play(video: YouTubeVideo) {
        self.logger.info("YouTubePlayer: play video")
        self.playbackWillStart?()

        self.currentVideo = video
        self.progress = 0
        self.duration = 0
        self.surfaceLocation = .inline

        // Create the WebView on demand; containers reparent it on appear.
        self.playbackController.prepare(webKitManager: self.webKitManager, playerService: self)
        self.playbackController.loadVideo(videoId: video.videoId)
    }

    /// Toggles play/pause.
    func playPause() {
        if !self.isPlaying {
            self.playbackWillStart?()
        }
        self.playbackController.playPause()
    }

    /// Resumes playback.
    func resume() {
        self.playbackWillStart?()
        self.playbackController.play()
    }

    /// Pauses playback.
    func pause() {
        self.playbackController.pause()
    }

    /// Seeks to a position in seconds.
    func seek(to time: Double) {
        self.progress = time
        self.playbackController.seek(to: time)
    }

    /// Stops playback entirely and releases the surface.
    func stop() {
        self.logger.info("YouTubePlayer: stop")
        self.currentVideo = nil
        self.isPlaying = false
        self.progress = 0
        self.duration = 0
        self.isShowingAd = false
        self.surfaceLocation = .none
        self.activeInlineVideoId = nil
        self.playbackController.tearDown()
    }

    // MARK: - Surface Placement

    /// Moves the surface to the floating video window.
    func popOutToWindow() {
        guard self.currentVideo != nil else { return }
        self.logger.info("YouTubePlayer: pop out to floating window")
        self.surfaceLocation = .floating
    }

    /// Docks the surface back into the inline watch view.
    func dockInline() {
        guard self.currentVideo != nil else { return }
        self.logger.info("YouTubePlayer: dock inline")
        self.surfaceLocation = .inline
    }

    /// A WatchView for `videoId` is disappearing. If it owns the inline
    /// surface, hand off: keep playing in the floating window, or stop if
    /// paused.
    func inlineSurfaceWillDisappear(videoId: String) {
        guard self.activeInlineVideoId == videoId else { return }
        self.activeInlineVideoId = nil

        guard self.currentVideo?.videoId == videoId, self.surfaceLocation == .inline else { return }

        if self.isPlaying {
            self.popOutToWindow()
        } else {
            self.stop()
        }
    }

    // MARK: - Bridge Callbacks

    /// A `STATE_UPDATE` payload from the watch page observer script.
    struct PlaybackUpdate {
        let isPlaying: Bool
        let progress: Double
        let duration: Double
        var videoId: String?
        var title: String?
        var isAd = false
    }

    /// Applies a `STATE_UPDATE` from the watch page observer script.
    func updatePlaybackState(_ update: PlaybackUpdate) {
        // YouTube can start the next video on its own (SPA navigation);
        // make sure music yields whenever video audio actually starts.
        if update.isPlaying, !self.isPlaying {
            self.playbackWillStart?()
        }

        self.isPlaying = update.isPlaying
        self.progress = update.progress
        self.duration = update.duration
        self.isShowingAd = update.isAd

        // Track SPA drift: if the page moved to a different video, follow it
        // so the controls stay truthful.
        if let videoId = update.videoId, let current = self.currentVideo,
           videoId != current.videoId
        {
            self.logger.info("YouTubePlayer: page drifted to a different video, following")
            self.currentVideo = YouTubeVideo(
                videoId: videoId,
                title: update.title ?? current.title,
                channelName: current.channelName,
                channelId: current.channelId
            )
            YouTubeWatchWebView.shared.currentVideoId = videoId
        }
    }

    /// Handles natural video completion.
    func handleVideoEnded(videoId: String?) {
        self.logger.info("YouTubePlayer: video ended")
        self.isPlaying = false
        self.onVideoEnded?(videoId)
    }
}
