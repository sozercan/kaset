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
    var isPlaying: Bool { state.isPlaying }

    /// Current playback position in seconds.
    private(set) var progress: TimeInterval = 0

    /// Total duration of current track in seconds.
    private(set) var duration: TimeInterval = 0

    /// Current volume (0.0 - 1.0).
    private(set) var volume: Double = 1.0

    /// Volume before muting, for unmute restoration.
    private var volumeBeforeMute: Double = 1.0

    /// Whether audio is currently muted.
    var isMuted: Bool { volume == 0 }

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
        ytMusicClient = client
    }

    // MARK: - Public Methods

    /// Plays a track by video ID.
    func play(videoId: String) async {
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

        pendingPlayVideoId = videoId

        // If user has already interacted this session, auto-play without popup
        if hasUserInteractedThisSession {
            logger.info("User has interacted before, auto-playing without popup")
            showMiniPlayer = false
            // Load the video directly - WebView session should allow autoplay
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
        } else {
            // First time: show the mini player for user interaction
            showMiniPlayer = true
            logger.info("Showing mini player for first-time user interaction")
        }

        // Fetch full song metadata in the background to get feedbackTokens
        await fetchSongMetadata(videoId: videoId)
    }

    /// Plays a song.
    func play(song: Song) async {
        logger.info("Playing song: \(song.title)")
        state = .loading
        currentTrack = song

        // Use existing feedbackTokens if the song already has them
        if let tokens = song.feedbackTokens {
            currentTrackFeedbackTokens = tokens
            currentTrackInLibrary = song.isInLibrary ?? false
            if let likeStatus = song.likeStatus {
                currentTrackLikeStatus = likeStatus
            }
        }

        pendingPlayVideoId = song.videoId

        // If user has already interacted this session, auto-play without popup
        if hasUserInteractedThisSession {
            logger.info("User has interacted before, auto-playing without popup")
            showMiniPlayer = false
            SingletonPlayerWebView.shared.loadVideo(videoId: song.videoId)
        } else {
            // First time: show the mini player for user interaction
            showMiniPlayer = true
            logger.info("Showing mini player for first-time user interaction")
        }

        // Fetch full song metadata if we don't have feedbackTokens
        if song.feedbackTokens == nil {
            await fetchSongMetadata(videoId: song.videoId)
        }
    }

    /// Called when the mini player confirms playback has started.
    func confirmPlaybackStarted() {
        showMiniPlayer = false
        state = .playing
        hasUserInteractedThisSession = true
        logger.info("Playback confirmed started, user interaction recorded")
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

    /// Updates track metadata when track changes (e.g., via next/previous).
    func updateTrackMetadata(title: String, artist: String, thumbnailUrl: String) {
        logger.debug("Track metadata updated: \(title) - \(artist)")

        let thumbnailURL = URL(string: thumbnailUrl)
        let artistObj = Artist(id: "unknown", name: artist)

        // Preserve videoId if we have it
        let videoId = currentTrack?.videoId ?? pendingPlayVideoId ?? "unknown"

        // Check if track actually changed
        let trackChanged = currentTrack?.title != title || currentTrack?.artistsDisplay != artist

        currentTrack = Song(
            id: videoId,
            title: title,
            artists: [artistObj],
            album: nil,
            duration: duration > 0 ? duration : nil,
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )

        // Reset like/library status when track changes
        if trackChanged {
            resetTrackStatus()
        }
    }

    /// Toggles play/pause.
    func playPause() async {
        logger.debug("Toggle play/pause")

        // Use singleton WebView if we have a pending video
        if pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.playPause()
        } else if isPlaying {
            await pause()
        } else {
            await resume()
        }
    }

    /// Pauses playback.
    func pause() async {
        logger.debug("Pausing playback")
        if pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.pause()
        } else {
            await evaluatePlayerCommand("pause")
        }
    }

    /// Resumes playback.
    func resume() async {
        logger.debug("Resuming playback")
        if pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.play()
        } else {
            await evaluatePlayerCommand("play")
        }
    }

    /// Skips to next track.
    func next() async {
        logger.debug("Skipping to next track")

        // Prioritize local queue if we have one
        if !queue.isEmpty {
            // Handle repeat one mode - replay current track
            if repeatMode == .one {
                await seek(to: 0)
                await resume()
                return
            }

            // Handle shuffle mode - pick random track
            if shuffleEnabled {
                let randomIndex = Int.random(in: 0 ..< queue.count)
                currentIndex = randomIndex
                if let nextSong = queue[safe: currentIndex] {
                    await play(song: nextSong)
                }
                return
            }

            // Normal next behavior
            if currentIndex < queue.count - 1 {
                currentIndex += 1
                if let nextSong = queue[safe: currentIndex] {
                    await play(song: nextSong)
                }
            } else if repeatMode == .all {
                // Loop back to start if repeat all is enabled
                currentIndex = 0
                if let firstSong = queue.first {
                    await play(song: firstSong)
                }
            }
            // At end of queue with repeat off, don't do anything
            return
        }

        // Fall back to YouTube's next if no local queue
        if pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.next()
        }
    }

    /// Goes to previous track.
    func previous() async {
        logger.debug("Going to previous track")

        // Prioritize local queue if we have one
        if !queue.isEmpty {
            if progress > 3 {
                // Restart current track
                if pendingPlayVideoId != nil {
                    SingletonPlayerWebView.shared.seek(to: 0)
                } else {
                    await seek(to: 0)
                }
            } else if currentIndex > 0 {
                currentIndex -= 1
                if let prevSong = queue[safe: currentIndex] {
                    await play(song: prevSong)
                }
            } else {
                // At start of queue, just restart current track
                if pendingPlayVideoId != nil {
                    SingletonPlayerWebView.shared.seek(to: 0)
                } else {
                    await seek(to: 0)
                }
            }
            return
        }

        // Fall back to YouTube's previous if no local queue
        if pendingPlayVideoId != nil {
            if progress > 3 {
                SingletonPlayerWebView.shared.seek(to: 0)
            } else {
                SingletonPlayerWebView.shared.previous()
            }
        } else if progress > 3 {
            await seek(to: 0)
        }
    }

    /// Seeks to a specific time.
    func seek(to time: TimeInterval) async {
        logger.debug("Seeking to \(time)")
        if pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.seek(to: time)
            progress = time
        } else {
            await evaluatePlayerCommand("seekTo(\(time), true)")
        }
    }

    /// Sets the volume.
    func setVolume(_ value: Double) async {
        let clampedValue = max(0, min(1, value))
        logger.debug("Setting volume to \(clampedValue)")
        volume = clampedValue
        if pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.setVolume(clampedValue)
        } else {
            await evaluatePlayerCommand("setVolume(\(Int(clampedValue * 100)))")
        }
    }

    /// Toggles mute state. Remembers previous volume for unmuting.
    func toggleMute() async {
        if isMuted {
            // Unmute - restore previous volume
            let restoredVolume = volumeBeforeMute > 0 ? volumeBeforeMute : 1.0
            await setVolume(restoredVolume)
            logger.info("Unmuted, volume restored to \(restoredVolume)")
        } else {
            // Mute - save current volume and set to 0
            volumeBeforeMute = volume
            await setVolume(0)
            logger.info("Muted")
        }
    }

    /// Toggles shuffle mode.
    func toggleShuffle() {
        shuffleEnabled.toggle()
        let status = shuffleEnabled ? "enabled" : "disabled"
        logger.info("Shuffle mode: \(status)")
    }

    /// Cycles through repeat modes: off -> all -> one -> off.
    func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
        let mode = repeatMode
        logger.info("Repeat mode: \(String(describing: mode))")
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

    // MARK: - Like/Dislike/Library Actions

    /// Likes the current track (thumbs up).
    func likeCurrentTrack() {
        guard let track = currentTrack else { return }
        logger.info("Liking current track: \(track.videoId)")

        // Toggle: if already liked, remove the like
        let newStatus: LikeStatus = currentTrackLikeStatus == .like ? .indifferent : .like
        let previousStatus = currentTrackLikeStatus
        currentTrackLikeStatus = newStatus

        // Use API call for reliable rating
        Task {
            do {
                try await ytMusicClient?.rateSong(videoId: track.videoId, rating: newStatus)
                logger.info("Successfully rated song as \(newStatus.rawValue)")
            } catch {
                logger.error("Failed to rate song: \(error.localizedDescription)")
                // Revert on failure
                currentTrackLikeStatus = previousStatus
            }
        }
    }

    /// Dislikes the current track (thumbs down).
    func dislikeCurrentTrack() {
        guard let track = currentTrack else { return }
        logger.info("Disliking current track: \(track.videoId)")

        // Toggle: if already disliked, remove the dislike
        let newStatus: LikeStatus = currentTrackLikeStatus == .dislike ? .indifferent : .dislike
        let previousStatus = currentTrackLikeStatus
        currentTrackLikeStatus = newStatus

        // Use API call for reliable rating
        Task {
            do {
                try await ytMusicClient?.rateSong(videoId: track.videoId, rating: newStatus)
                logger.info("Successfully rated song as \(newStatus.rawValue)")
            } catch {
                logger.error("Failed to rate song: \(error.localizedDescription)")
                // Revert on failure
                currentTrackLikeStatus = previousStatus
            }
        }
    }

    /// Toggles the library status of the current track.
    func toggleLibraryStatus() {
        guard let track = currentTrack else { return }
        logger.info("Toggling library status for current track: \(track.videoId)")

        // Determine which token to use based on current state
        let isCurrentlyInLibrary = currentTrackInLibrary
        let tokenToUse = isCurrentlyInLibrary
            ? currentTrackFeedbackTokens?.remove
            : currentTrackFeedbackTokens?.add

        guard let token = tokenToUse else {
            logger.warning("No feedback token available for library toggle")
            return
        }

        // Optimistic update
        let previousState = currentTrackInLibrary
        currentTrackInLibrary.toggle()

        // Use API call for reliable library management
        Task {
            do {
                try await ytMusicClient?.editSongLibraryStatus(feedbackTokens: [token])
                let action = isCurrentlyInLibrary ? "removed from" : "added to"
                logger.info("Successfully \(action) library")

                // After successful toggle, we need to swap the tokens
                // The remove token becomes add, and vice versa
                // Re-fetch metadata to get updated tokens
                await fetchSongMetadata(videoId: track.videoId)
            } catch {
                logger.error("Failed to toggle library status: \(error.localizedDescription)")
                // Revert on failure
                currentTrackInLibrary = previousState
            }
        }
    }

    /// Updates the like status from WebView observation.
    func updateLikeStatus(_ status: LikeStatus) {
        currentTrackLikeStatus = status
    }

    /// Resets like/library status when track changes.
    private func resetTrackStatus() {
        currentTrackLikeStatus = .indifferent
        currentTrackInLibrary = false
        currentTrackFeedbackTokens = nil
    }

    /// Fetches full song metadata including feedbackTokens from the API.
    private func fetchSongMetadata(videoId: String) async {
        guard let client = ytMusicClient else {
            logger.warning("No YTMusicClient available for fetching song metadata")
            return
        }

        do {
            let songData = try await client.getSong(videoId: videoId)

            // Update current track with full metadata if it's still the same song
            if currentTrack?.videoId == videoId {
                // Preserve the title/artist from WebView if they're better
                let title = currentTrack?.title == "Loading..." ? songData.title : (currentTrack?.title ?? songData.title)
                let artists = currentTrack?.artists.isEmpty == true ? songData.artists : (currentTrack?.artists ?? songData.artists)

                currentTrack = Song(
                    id: videoId,
                    title: title,
                    artists: artists,
                    album: songData.album ?? currentTrack?.album,
                    duration: songData.duration ?? currentTrack?.duration,
                    thumbnailURL: songData.thumbnailURL ?? currentTrack?.thumbnailURL,
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

                logger.info("Updated track metadata - inLibrary: \(self.currentTrackInLibrary), hasTokens: \(self.currentTrackFeedbackTokens != nil)")
            }
        } catch {
            logger.warning("Failed to fetch song metadata: \(error.localizedDescription)")
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
