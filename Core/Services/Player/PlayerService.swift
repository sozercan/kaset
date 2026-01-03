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
    var showLyrics: Bool = false {
        didSet {
            // Mutual exclusivity: opening lyrics closes queue
            if self.showLyrics, self.showQueue {
                self.showQueue = false
            }
        }
    }

    /// Whether the queue panel is visible.
    var showQueue: Bool = false {
        didSet {
            // Mutual exclusivity: opening queue closes lyrics
            if self.showQueue, self.showLyrics {
                self.showLyrics = false
            }
        }
    }

    // MARK: - Private Properties

    private let logger = DiagnosticsLogger.player
    private var ytMusicClient: (any YTMusicClientProtocol)?

    /// Continuation token for loading more songs in infinite mix/radio.
    private var mixContinuationToken: String?

    /// Whether we're currently fetching more mix songs.
    private var isFetchingMoreMixSongs: Bool = false

    /// UserDefaults key for persisting volume.
    private static let volumeKey = "playerVolume"
    /// UserDefaults key for persisting volume before mute.
    private static let volumeBeforeMuteKey = "playerVolumeBeforeMute"

    // MARK: - Initialization

    override init() {
        super.init()
        // Restore saved volume from UserDefaults
        if UserDefaults.standard.object(forKey: Self.volumeKey) != nil {
            let savedVolume = UserDefaults.standard.double(forKey: Self.volumeKey)
            self.volume = max(0, min(1, savedVolume))
            self.logger.info("Restored saved volume: \(self.volume)")
        }
        // Restore volumeBeforeMute for proper unmute behavior
        if UserDefaults.standard.object(forKey: Self.volumeBeforeMuteKey) != nil {
            let savedVolumeBeforeMute = UserDefaults.standard.double(forKey: Self.volumeBeforeMuteKey)
            self.volumeBeforeMute = savedVolumeBeforeMute > 0 ? savedVolumeBeforeMute : 1.0
            self.logger.info("Restored volumeBeforeMute: \(self.volumeBeforeMute)")
        } else {
            self.volumeBeforeMute = self.volume > 0 ? self.volume : 1.0
        }
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
        let previousProgress = self.progress
        self.progress = progress
        self.duration = duration
        if isPlaying {
            self.state = .playing
        } else if self.state == .playing {
            self.state = .paused
        }

        // Detect when song is about to end (within last 2 seconds)
        // This helps us prepare to play the next track from our queue
        if duration > 0, progress >= duration - 2, previousProgress < duration - 2 {
            self.songNearingEnd = true
        }
    }

    /// Flag to track when a song is nearing its end.
    private var songNearingEnd: Bool = false

    /// Updates track metadata when track changes (e.g., via next/previous).
    /// Also handles enforcing our queue when YouTube autoplay kicks in.
    func updateTrackMetadata(title: String, artist: String, thumbnailUrl: String) {
        self.logger.debug("Track metadata updated: \(title) - \(artist)")

        let thumbnailURL = URL(string: thumbnailUrl)
        let artistObj = Artist(id: "unknown", name: artist)

        // Preserve videoId if we have it
        let videoId = self.currentTrack?.videoId ?? self.pendingPlayVideoId ?? "unknown"

        // Check if track actually changed
        let trackChanged = self.currentTrack?.title != title || self.currentTrack?.artistsDisplay != artist

        // If track changed and we have a queue, check if YouTube autoplay kicked in
        if trackChanged, !self.queue.isEmpty, self.songNearingEnd {
            self.songNearingEnd = false

            // Check if the new track matches our expected next track in queue
            let expectedNextIndex = self.currentIndex + 1
            if expectedNextIndex < self.queue.count {
                let expectedNextTrack = self.queue[expectedNextIndex]
                // If title doesn't match expected next track, YouTube autoplay overrode our queue
                if title != expectedNextTrack.title {
                    self.logger.info("YouTube autoplay detected, overriding with queue track")
                    // Play our queue's next track instead
                    Task {
                        await self.next()
                    }
                    return
                } else {
                    // Track matches our queue, update the index
                    self.currentIndex = expectedNextIndex
                    self.logger.info("Track advanced to queue index \(expectedNextIndex)")
                }
            }
        }

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
                // Check if we should fetch more songs
                await self.fetchMoreMixSongsIfNeeded()
                return
            }

            // Normal next behavior
            if self.currentIndex < self.queue.count - 1 {
                self.currentIndex += 1
                if let nextSong = queue[safe: currentIndex] {
                    await self.play(song: nextSong)
                }
                // Check if we should fetch more songs
                await self.fetchMoreMixSongsIfNeeded()
            } else if self.repeatMode == .all {
                // Loop back to start if repeat all is enabled
                self.currentIndex = 0
                if let firstSong = queue.first {
                    await self.play(song: firstSong)
                }
            } else if self.mixContinuationToken != nil {
                // At end of queue but have continuation - fetch more and continue
                await self.fetchMoreMixSongsIfNeeded()
                if self.currentIndex < self.queue.count - 1 {
                    self.currentIndex += 1
                    if let nextSong = queue[safe: currentIndex] {
                        await self.play(song: nextSong)
                    }
                }
            }
            // At end of queue with repeat off and no continuation, don't do anything
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

        // Persist volume to UserDefaults (including mute state of 0)
        UserDefaults.standard.set(clampedValue, forKey: Self.volumeKey)

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
            // Persist volumeBeforeMute so we can restore after app restart
            UserDefaults.standard.set(self.volumeBeforeMute, forKey: Self.volumeBeforeMuteKey)
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
        // Clear mix continuation since this is not a mix queue
        self.mixContinuationToken = nil
        if let song = songs[safe: safeIndex] {
            await self.play(song: song)
        }
    }

    /// Plays a song and fetches similar songs (radio queue) in the background.
    /// The queue will be populated with similar songs from YouTube Music's radio feature.
    func playWithRadio(song: Song) async {
        self.logger.info("Playing with radio: \(song.title)")

        // Clear mix continuation since this is a song radio, not a mix
        self.mixContinuationToken = nil

        // Start with just this song in the queue
        self.queue = [song]
        self.currentIndex = 0
        await self.play(song: song)

        // Fetch radio queue in background
        await self.fetchAndApplyRadioQueue(for: song.videoId)
    }

    /// Plays an artist mix from a mix playlist ID.
    /// Fetches a fresh randomized queue from the API each time.
    /// Supports infinite mix - automatically fetches more songs as you approach the end.
    /// - Parameters:
    ///   - playlistId: The mix playlist ID (e.g., "RDEM..." for artist mix)
    ///   - startVideoId: Optional video ID to start with. If nil, API picks a random starting point.
    func playWithMix(playlistId: String, startVideoId: String?) async {
        self.logger.info("Playing mix playlist: \(playlistId), startVideoId: \(startVideoId ?? "nil (random)")")

        guard let client = self.ytMusicClient else {
            self.logger.warning("No YTMusicClient available for playing mix")
            return
        }

        do {
            // Fetch mix queue from API
            let result = try await client.getMixQueue(playlistId: playlistId, startVideoId: startVideoId)
            guard !result.songs.isEmpty else {
                self.logger.warning("Mix queue returned empty")
                return
            }

            // Store continuation token for infinite mix
            self.mixContinuationToken = result.continuationToken

            // Shuffle the queue to get a different order each time
            // YouTube's API returns a personalized but consistent order per session,
            // so we shuffle to give the user variety on each Mix button click
            let shuffledSongs = result.songs.shuffled()

            // Set up the queue and play the first song
            self.queue = shuffledSongs
            self.currentIndex = 0
            self.currentTrack = shuffledSongs[0]

            // Start playback
            await self.play(videoId: shuffledSongs[0].videoId)

            self.logger.info("Mix queue loaded with \(shuffledSongs.count) songs, hasContinuation: \(result.continuationToken != nil)")
        } catch {
            self.logger.warning("Failed to fetch mix queue: \(error.localizedDescription)")
        }
    }

    /// Fetches more songs for the current mix when approaching the end of the queue.
    /// This enables "infinite mix" behavior like YouTube Music web.
    private func fetchMoreMixSongsIfNeeded() async {
        let songsRemaining = self.queue.count - self.currentIndex - 1
        self.logger.debug("Infinite mix check: \(songsRemaining) songs remaining, hasContinuation: \(self.mixContinuationToken != nil)")

        // Only fetch if we have a continuation token and we're near the end
        guard let token = mixContinuationToken,
              !isFetchingMoreMixSongs,
              let client = ytMusicClient
        else {
            return
        }

        // Fetch more when we're within 10 songs of the end
        guard songsRemaining <= 10 else {
            return
        }

        self.logger.info("Fetching more mix songs, \(songsRemaining) remaining in queue")
        self.isFetchingMoreMixSongs = true

        do {
            let result = try await client.getMixQueueContinuation(continuationToken: token)
            self.logger.debug("Continuation returned \(result.songs.count) songs, hasNextToken: \(result.continuationToken != nil)")

            // Filter out songs already in queue to avoid duplicates
            let existingIds = Set(queue.map(\.videoId))
            let newSongs = result.songs.filter { !existingIds.contains($0.videoId) }

            if !newSongs.isEmpty {
                // Create a new array to ensure @Observable triggers UI update
                var updatedQueue = self.queue
                updatedQueue.append(contentsOf: newSongs)
                self.queue = updatedQueue
                self.logger.info("Added \(newSongs.count) new songs to queue, total: \(self.queue.count)")
            }

            // Update continuation token for next batch
            self.mixContinuationToken = result.continuationToken
        } catch {
            self.logger.warning("Failed to fetch more mix songs: \(error.localizedDescription)")
        }

        self.isFetchingMoreMixSongs = false
    }

    /// Fetches radio queue and applies it, keeping the current song at the front.
    private func fetchAndApplyRadioQueue(for videoId: String) async {
        guard let client = ytMusicClient else {
            self.logger.warning("No YTMusicClient available for fetching radio queue")
            return
        }

        do {
            let radioSongs = try await client.getRadioQueue(videoId: videoId)
            guard !radioSongs.isEmpty else {
                self.logger.info("No radio songs returned")
                return
            }

            // Only update if we're still playing the same song
            guard let currentSong = self.currentTrack, currentSong.videoId == videoId else {
                self.logger.info("Track changed, discarding radio queue")
                return
            }

            // Ensure the current song is at the front of the queue
            // The radio queue may or may not include the seed song
            var newQueue: [Song] = []

            // Check if the current song is already in the radio queue
            let radioContainsCurrentSong = radioSongs.contains { $0.videoId == videoId }

            if radioContainsCurrentSong {
                // Find the index of current song and reorder queue to start from it
                if let currentSongIndex = radioSongs.firstIndex(where: { $0.videoId == videoId }) {
                    // Put current song first, then the rest
                    newQueue.append(currentSong)
                    for (index, song) in radioSongs.enumerated() where index != currentSongIndex {
                        newQueue.append(song)
                    }
                } else {
                    newQueue = radioSongs
                }
            } else {
                // Current song not in radio queue - prepend it
                newQueue.append(currentSong)
                newQueue.append(contentsOf: radioSongs)
            }

            self.queue = newQueue
            self.currentIndex = 0
            self.logger.info("Radio queue updated with \(newQueue.count) songs (current song at front)")
        } catch {
            self.logger.warning("Failed to fetch radio queue: \(error.localizedDescription)")
        }
    }

    /// Clears the playback queue except for the currently playing track.
    func clearQueue() {
        // Clear mix continuation since queue is being manually cleared
        self.mixContinuationToken = nil

        guard let currentTrack else {
            self.queue = []
            self.currentIndex = 0
            return
        }
        // Keep only the current track
        self.queue = [currentTrack]
        self.currentIndex = 0
        self.logger.info("Queue cleared, keeping current track")
    }

    /// Plays a song from the queue at the specified index.
    func playFromQueue(at index: Int) async {
        guard index >= 0, index < self.queue.count else { return }
        self.currentIndex = index
        if let song = queue[safe: index] {
            await self.play(song: song)
        }
        // Check if we need to fetch more songs for infinite mix
        await self.fetchMoreMixSongsIfNeeded()
    }

    /// Inserts songs immediately after the current track.
    /// - Parameter songs: The songs to insert into the queue.
    func insertNextInQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let insertIndex = min(self.currentIndex + 1, self.queue.count)
        self.queue.insert(contentsOf: songs, at: insertIndex)
        self.logger.info("Inserted \(songs.count) songs at position \(insertIndex)")
    }

    /// Removes songs from the queue by video ID.
    /// - Parameter videoIds: Set of video IDs to remove.
    func removeFromQueue(videoIds: Set<String>) {
        let previousCount = self.queue.count
        self.queue.removeAll { videoIds.contains($0.videoId) }

        // Adjust currentIndex if needed
        if let current = currentTrack,
           let newIndex = queue.firstIndex(where: { $0.videoId == current.videoId })
        {
            self.currentIndex = newIndex
        } else if self.currentIndex >= self.queue.count {
            self.currentIndex = max(0, self.queue.count - 1)
        }

        self.logger.info("Removed \(previousCount - self.queue.count) songs from queue")
    }

    /// Reorders the queue based on a new order of video IDs.
    /// - Parameter videoIds: The new order of video IDs.
    func reorderQueue(videoIds: [String]) {
        var reordered: [Song] = []
        var videoIdToSong: [String: Song] = [:]

        for song in self.queue {
            videoIdToSong[song.videoId] = song
        }

        for videoId in videoIds {
            if let song = videoIdToSong[videoId] {
                reordered.append(song)
            }
        }

        self.queue = reordered

        // Update currentIndex to match current track's new position
        if let current = currentTrack,
           let newIndex = queue.firstIndex(where: { $0.videoId == current.videoId })
        {
            self.currentIndex = newIndex
        }

        self.logger.info("Queue reordered with \(reordered.count) songs")
    }

    /// Shuffles the queue, keeping the current track in place at the front.
    func shuffleQueue() {
        guard self.queue.count > 1 else { return }

        // Remove current track, shuffle the rest, put current track at front
        if let currentSong = queue[safe: currentIndex] {
            var shuffled = self.queue
            shuffled.remove(at: self.currentIndex)
            shuffled.shuffle()
            shuffled.insert(currentSong, at: 0)
            self.queue = shuffled
            self.currentIndex = 0
        } else {
            self.queue.shuffle()
            self.currentIndex = 0
        }

        self.logger.info("Queue shuffled")
    }

    /// Adds songs to the end of the queue.
    /// - Parameter songs: The songs to append to the queue.
    func appendToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        self.queue.append(contentsOf: songs)
        self.logger.info("Appended \(songs.count) songs to queue")
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
