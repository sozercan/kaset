import Foundation
import Observation
import os

// MARK: - PlayerService

/// Controls music playback via a hidden WKWebView.
@MainActor
@Observable
final class PlayerService: NSObject, PlayerServiceProtocol {
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

    /// Repeat mode for playback.
    enum RepeatMode: Sendable {
        case off
        case all
        case one
    }

    // MARK: - Observable State

    /// Current playback state.
    private(set) var state: PlaybackState = .idle

    /// Currently playing track.
    private(set) var currentTrack: Song?

    /// Whether playback is active.
    var isPlaying: Bool { self.state.isPlaying }

    /// Current playback position in seconds.
    private(set) var progress: TimeInterval = 0

    /// Total duration of current track in seconds.
    private(set) var duration: TimeInterval = 0

    /// Current volume (0.0 - 1.0).
    private(set) var volume: Double = 1.0

    /// Volume before muting, for unmute restoration.
    private var volumeBeforeMute: Double = 1.0

    /// Whether audio is currently muted.
    var isMuted: Bool { self.volume == 0 }

    /// Whether shuffle mode is enabled.
    private(set) var shuffleEnabled: Bool = false

    /// Current repeat mode.
    private(set) var repeatMode: RepeatMode = .off

    /// Playback queue.
    private(set) var queue: [Song] = []

    /// Index of current track in queue.
    private(set) var currentIndex: Int = 0

    /// Whether the mini player should be shown (user needs to interact to start playback).
    var showMiniPlayer: Bool = false

    /// The video ID that needs to be played in the mini player.
    private(set) var pendingPlayVideoId: String?

    /// Whether the user has successfully interacted at least once this session.
    /// After first successful playback, we can auto-play without showing the popup.
    private(set) var hasUserInteractedThisSession: Bool = false

    /// Like status of the current track.
    private(set) var currentTrackLikeStatus: LikeStatus = .indifferent

    /// Whether the current track is in the user's library.
    private(set) var currentTrackInLibrary: Bool = false

    /// Feedback tokens for the current track (used for library add/remove).
    private(set) var currentTrackFeedbackTokens: FeedbackTokens?

    /// Whether the lyrics panel is visible.
    var showLyrics: Bool = false

    // MARK: - Private Properties

    private let logger = DiagnosticsLogger.player
    private var ytMusicClient: (any YTMusicClientProtocol)?

    // MARK: - Initialization

    override init() {
        super.init()
    }

    /// Sets the YTMusicClient for API calls (dependency injection).
    func setYTMusicClient(_ client: any YTMusicClientProtocol) {
        self.ytMusicClient = client
    }

    // MARK: - Public Methods

    /// Plays a track by video ID.
    func play(videoId: String) async {
        self.logger.info("Playing video: \(videoId)")
        self.state = .loading

        // Create a minimal Song object for now
        self.currentTrack = Song(
            id: videoId,
            title: "Loading...",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: videoId
        )

        self.pendingPlayVideoId = videoId

        // If user has already interacted this session, auto-play without popup
        if self.hasUserInteractedThisSession {
            self.logger.info("User has interacted before, auto-playing without popup")
            self.showMiniPlayer = false
            // Load the video directly - WebView session should allow autoplay
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
        } else {
            // First time: show the mini player for user interaction
            self.showMiniPlayer = true
            self.logger.info("Showing mini player for first-time user interaction")
        }

        // Fetch full song metadata in the background to get feedbackTokens
        await self.fetchSongMetadata(videoId: videoId)
    }

    /// Plays a song.
    func play(song: Song) async {
        self.logger.info("Playing song: \(song.title)")
        self.state = .loading
        self.currentTrack = song

        // Use existing feedbackTokens if the song already has them
        if let tokens = song.feedbackTokens {
            self.currentTrackFeedbackTokens = tokens
            self.currentTrackInLibrary = song.isInLibrary ?? false
            if let likeStatus = song.likeStatus {
                self.currentTrackLikeStatus = likeStatus
            }
        }

        self.pendingPlayVideoId = song.videoId

        // If user has already interacted this session, auto-play without popup
        if self.hasUserInteractedThisSession {
            self.logger.info("User has interacted before, auto-playing without popup")
            self.showMiniPlayer = false
            SingletonPlayerWebView.shared.loadVideo(videoId: song.videoId)
        } else {
            // First time: show the mini player for user interaction
            self.showMiniPlayer = true
            self.logger.info("Showing mini player for first-time user interaction")
        }

        // Fetch full song metadata if we don't have feedbackTokens
        if song.feedbackTokens == nil {
            await self.fetchSongMetadata(videoId: song.videoId)
        }
    }

    /// Called when the mini player confirms playback has started.
    func confirmPlaybackStarted() {
        self.showMiniPlayer = false
        self.state = .playing
        self.hasUserInteractedThisSession = true
        self.logger.info("Playback confirmed started, user interaction recorded")
    }

    /// Called when the mini player is dismissed.
    func miniPlayerDismissed() {
        self.showMiniPlayer = false
        if self.state == .loading {
            self.state = .idle
        }
    }

    /// Updates playback state from the persistent WebView observer.
    func updatePlaybackState(isPlaying: Bool, progress: Double, duration: Double) {
        self.progress = progress
        self.duration = duration
        if isPlaying {
            self.state = .playing
        } else if self.state == .playing {
            self.state = .paused
        }
    }

    /// Updates track metadata when track changes (e.g., via next/previous).
    func updateTrackMetadata(title: String, artist: String, thumbnailUrl: String) {
        self.logger.debug("Track metadata updated: \(title) - \(artist)")

        let thumbnailURL = URL(string: thumbnailUrl)
        let artistObj = Artist(id: "unknown", name: artist)

        // Preserve videoId if we have it
        let videoId = self.currentTrack?.videoId ?? self.pendingPlayVideoId ?? "unknown"

        // Check if track actually changed
        let trackChanged = self.currentTrack?.title != title || self.currentTrack?.artistsDisplay != artist

        self.currentTrack = Song(
            id: videoId,
            title: title,
            artists: [artistObj],
            album: nil,
            duration: self.duration > 0 ? self.duration : nil,
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )

        // Reset like/library status when track changes
        if trackChanged {
            self.resetTrackStatus()
        }
    }

    /// Toggles play/pause.
    func playPause() async {
        self.logger.debug("Toggle play/pause")

        // Use singleton WebView if we have a pending video
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.playPause()
        } else if self.isPlaying {
            await self.pause()
        } else {
            await self.resume()
        }
    }

    /// Pauses playback.
    func pause() async {
        self.logger.debug("Pausing playback")
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.pause()
        } else {
            await self.evaluatePlayerCommand("pause")
        }
    }

    /// Resumes playback.
    func resume() async {
        self.logger.debug("Resuming playback")
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.play()
        } else {
            await self.evaluatePlayerCommand("play")
        }
    }

    /// Skips to next track.
    func next() async {
        self.logger.debug("Skipping to next track")

        // Prioritize local queue if we have one
        if !self.queue.isEmpty {
            // Handle repeat one mode - replay current track
            if self.repeatMode == .one {
                await self.seek(to: 0)
                await self.resume()
                return
            }

            // Handle shuffle mode - pick random track
            if self.shuffleEnabled {
                let randomIndex = Int.random(in: 0 ..< self.queue.count)
                self.currentIndex = randomIndex
                if let nextSong = queue[safe: currentIndex] {
                    await self.play(song: nextSong)
                }
                return
            }

            // Normal next behavior
            if self.currentIndex < self.queue.count - 1 {
                self.currentIndex += 1
                if let nextSong = queue[safe: currentIndex] {
                    await self.play(song: nextSong)
                }
            } else if self.repeatMode == .all {
                // Loop back to start if repeat all is enabled
                self.currentIndex = 0
                if let firstSong = queue.first {
                    await self.play(song: firstSong)
                }
            }
            // At end of queue with repeat off, don't do anything
            return
        }

        // Fall back to YouTube's next if no local queue
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.next()
        }
    }

    /// Goes to previous track.
    func previous() async {
        self.logger.debug("Going to previous track")

        // Prioritize local queue if we have one
        if !self.queue.isEmpty {
            if self.progress > 3 {
                // Restart current track
                if self.pendingPlayVideoId != nil {
                    SingletonPlayerWebView.shared.seek(to: 0)
                } else {
                    await self.seek(to: 0)
                }
            } else if self.currentIndex > 0 {
                self.currentIndex -= 1
                if let prevSong = queue[safe: currentIndex] {
                    await self.play(song: prevSong)
                }
            } else {
                // At start of queue, just restart current track
                if self.pendingPlayVideoId != nil {
                    SingletonPlayerWebView.shared.seek(to: 0)
                } else {
                    await self.seek(to: 0)
                }
            }
            return
        }

        // Fall back to YouTube's previous if no local queue
        if self.pendingPlayVideoId != nil {
            if self.progress > 3 {
                SingletonPlayerWebView.shared.seek(to: 0)
            } else {
                SingletonPlayerWebView.shared.previous()
            }
        } else if self.progress > 3 {
            await self.seek(to: 0)
        }
    }

    /// Seeks to a specific time.
    func seek(to time: TimeInterval) async {
        self.logger.debug("Seeking to \(time)")
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.seek(to: time)
            self.progress = time
        } else {
            await self.evaluatePlayerCommand("seekTo(\(time), true)")
        }
    }

    /// Sets the volume.
    func setVolume(_ value: Double) async {
        let clampedValue = max(0, min(1, value))
        self.logger.debug("Setting volume to \(clampedValue)")
        self.volume = clampedValue
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.setVolume(clampedValue)
        } else {
            await self.evaluatePlayerCommand("setVolume(\(Int(clampedValue * 100)))")
        }
    }

    /// Toggles mute state. Remembers previous volume for unmuting.
    func toggleMute() async {
        if self.isMuted {
            // Unmute - restore previous volume
            let restoredVolume = self.volumeBeforeMute > 0 ? self.volumeBeforeMute : 1.0
            await self.setVolume(restoredVolume)
            self.logger.info("Unmuted, volume restored to \(restoredVolume)")
        } else {
            // Mute - save current volume and set to 0
            self.volumeBeforeMute = self.volume
            await self.setVolume(0)
            self.logger.info("Muted")
        }
    }

    /// Toggles shuffle mode.
    func toggleShuffle() {
        self.shuffleEnabled.toggle()
        let status = self.shuffleEnabled ? "enabled" : "disabled"
        self.logger.info("Shuffle mode: \(status)")
    }

    /// Cycles through repeat modes: off -> all -> one -> off.
    func cycleRepeatMode() {
        switch self.repeatMode {
        case .off:
            self.repeatMode = .all
        case .all:
            self.repeatMode = .one
        case .one:
            self.repeatMode = .off
        }
        let mode = self.repeatMode
        self.logger.info("Repeat mode: \(String(describing: mode))")
    }

    /// Stops playback and clears state.
    func stop() async {
        self.logger.debug("Stopping playback")
        await self.evaluatePlayerCommand("pauseVideo()")
        self.state = .idle
        self.currentTrack = nil
        self.progress = 0
        self.duration = 0
    }

    /// Plays a queue of songs starting at the specified index.
    func playQueue(_ songs: [Song], startingAt index: Int = 0) async {
        guard !songs.isEmpty else { return }
        let safeIndex = max(0, min(index, songs.count - 1))
        self.queue = songs
        self.currentIndex = safeIndex
        if let song = songs[safe: safeIndex] {
            await self.play(song: song)
        }
    }

    // MARK: - Like/Dislike/Library Actions

    /// Likes the current track (thumbs up).
    func likeCurrentTrack() {
        guard let track = currentTrack else { return }
        self.logger.info("Liking current track: \(track.videoId)")

        // Toggle: if already liked, remove the like
        let newStatus: LikeStatus = self.currentTrackLikeStatus == .like ? .indifferent : .like
        let previousStatus = self.currentTrackLikeStatus
        self.currentTrackLikeStatus = newStatus

        // Use API call for reliable rating
        Task {
            do {
                try await self.ytMusicClient?.rateSong(videoId: track.videoId, rating: newStatus)
                self.logger.info("Successfully rated song as \(newStatus.rawValue)")
            } catch {
                self.logger.error("Failed to rate song: \(error.localizedDescription)")
                // Revert on failure
                self.currentTrackLikeStatus = previousStatus
            }
        }
    }

    /// Dislikes the current track (thumbs down).
    func dislikeCurrentTrack() {
        guard let track = currentTrack else { return }
        self.logger.info("Disliking current track: \(track.videoId)")

        // Toggle: if already disliked, remove the dislike
        let newStatus: LikeStatus = self.currentTrackLikeStatus == .dislike ? .indifferent : .dislike
        let previousStatus = self.currentTrackLikeStatus
        self.currentTrackLikeStatus = newStatus

        // Use API call for reliable rating
        Task {
            do {
                try await self.ytMusicClient?.rateSong(videoId: track.videoId, rating: newStatus)
                self.logger.info("Successfully rated song as \(newStatus.rawValue)")
            } catch {
                self.logger.error("Failed to rate song: \(error.localizedDescription)")
                // Revert on failure
                self.currentTrackLikeStatus = previousStatus
            }
        }
    }

    /// Toggles the library status of the current track.
    func toggleLibraryStatus() {
        guard let track = currentTrack else { return }
        self.logger.info("Toggling library status for current track: \(track.videoId)")

        // Determine which token to use based on current state
        let isCurrentlyInLibrary = self.currentTrackInLibrary
        let tokenToUse = isCurrentlyInLibrary
            ? self.currentTrackFeedbackTokens?.remove
            : self.currentTrackFeedbackTokens?.add

        guard let token = tokenToUse else {
            self.logger.warning("No feedback token available for library toggle")
            return
        }

        // Optimistic update
        let previousState = self.currentTrackInLibrary
        self.currentTrackInLibrary.toggle()

        // Use API call for reliable library management
        Task {
            do {
                try await self.ytMusicClient?.editSongLibraryStatus(feedbackTokens: [token])
                let action = isCurrentlyInLibrary ? "removed from" : "added to"
                self.logger.info("Successfully \(action) library")

                // After successful toggle, we need to swap the tokens
                // The remove token becomes add, and vice versa
                // Re-fetch metadata to get updated tokens
                await self.fetchSongMetadata(videoId: track.videoId)
            } catch {
                self.logger.error("Failed to toggle library status: \(error.localizedDescription)")
                // Revert on failure
                self.currentTrackInLibrary = previousState
            }
        }
    }

    /// Updates the like status from WebView observation.
    func updateLikeStatus(_ status: LikeStatus) {
        self.currentTrackLikeStatus = status
    }

    /// Resets like/library status when track changes.
    private func resetTrackStatus() {
        self.currentTrackLikeStatus = .indifferent
        self.currentTrackInLibrary = false
        self.currentTrackFeedbackTokens = nil
    }

    /// Fetches full song metadata including feedbackTokens from the API.
    private func fetchSongMetadata(videoId: String) async {
        guard let client = ytMusicClient else {
            self.logger.warning("No YTMusicClient available for fetching song metadata")
            return
        }

        do {
            let songData = try await client.getSong(videoId: videoId)

            // Update current track with full metadata if it's still the same song
            if self.currentTrack?.videoId == videoId {
                // Preserve the title/artist from WebView if they're better
                let title = self.currentTrack?.title == "Loading..." ? songData.title : (self.currentTrack?.title ?? songData.title)
                let artists = self.currentTrack?.artists.isEmpty == true ? songData.artists : (self.currentTrack?.artists ?? songData.artists)

                self.currentTrack = Song(
                    id: videoId,
                    title: title,
                    artists: artists,
                    album: songData.album ?? self.currentTrack?.album,
                    duration: songData.duration ?? self.currentTrack?.duration,
                    thumbnailURL: songData.thumbnailURL ?? self.currentTrack?.thumbnailURL,
                    videoId: videoId,
                    likeStatus: songData.likeStatus,
                    isInLibrary: songData.isInLibrary,
                    feedbackTokens: songData.feedbackTokens
                )

                // Update service state
                if let likeStatus = songData.likeStatus {
                    self.currentTrackLikeStatus = likeStatus
                }
                self.currentTrackInLibrary = songData.isInLibrary ?? false
                self.currentTrackFeedbackTokens = songData.feedbackTokens

                self.logger.info("Updated track metadata - inLibrary: \(self.currentTrackInLibrary), hasTokens: \(self.currentTrackFeedbackTokens != nil)")
            }
        } catch {
            self.logger.warning("Failed to fetch song metadata: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods

    /// Legacy method for evaluating player commands - now delegates to SingletonPlayerWebView.
    private func evaluatePlayerCommand(_ command: String) async {
        // Commands are now routed through SingletonPlayerWebView
        switch command {
        case "pause", "pauseVideo()":
            SingletonPlayerWebView.shared.pause()
        case "play", "playVideo()":
            SingletonPlayerWebView.shared.play()
        default:
            if command.hasPrefix("seekTo(") {
                let timeStr = command.dropFirst(7).prefix(while: { $0 != "," && $0 != ")" })
                if let time = Double(timeStr) {
                    SingletonPlayerWebView.shared.seek(to: time)
                }
            } else if command.hasPrefix("setVolume(") {
                let volStr = command.dropFirst(10).dropLast()
                if let vol = Int(volStr) {
                    SingletonPlayerWebView.shared.setVolume(Double(vol) / 100.0)
                }
            }
        }
    }
}
