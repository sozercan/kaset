import Foundation

// MARK: - WebKitManagerProtocol

/// Protocol defining the interface for WebKit cookie and data management.
/// Enables dependency injection and mocking for tests.
@MainActor
protocol WebKitManagerProtocol: AnyObject, Sendable {
    /// Retrieves all cookies from the HTTP cookie store.
    func getAllCookies() async -> [HTTPCookie]

    /// Gets cookies for a specific domain.
    func getCookies(for domain: String) async -> [HTTPCookie]

    /// Builds a Cookie header string for the given domain.
    func cookieHeader(for domain: String) async -> String?

    /// Retrieves the SAPISID cookie value used for authentication.
    func getSAPISID() async -> String?

    /// Checks if the required authentication cookies exist.
    func hasAuthCookies() async -> Bool

    /// Clears all website data (cookies, cache, etc.).
    func clearAllData() async

    /// Forces an immediate backup of all YouTube/Google cookies.
    func forceBackupCookies() async

    /// Logs all authentication-related cookies for debugging.
    func logAuthCookies() async
}

// MARK: - YTMusicClientProtocol

/// Protocol defining the interface for YouTube Music API operations.
/// Enables dependency injection and mocking for tests.
@MainActor
protocol YTMusicClientProtocol: Sendable {
    /// Fetches the home page content (initial sections only for fast display).
    func getHome() async throws -> HomeResponse

    /// Fetches the next batch of home sections via continuation.
    func getHomeContinuation() async throws -> [HomeSection]?

    /// Whether more home sections are available to load.
    var hasMoreHomeSections: Bool { get }

    /// Fetches the explore page content (initial sections only for fast display).
    func getExplore() async throws -> HomeResponse

    /// Fetches the next batch of explore sections via continuation.
    func getExploreContinuation() async throws -> [HomeSection]?

    /// Whether more explore sections are available to load.
    var hasMoreExploreSections: Bool { get }

    /// Fetches the charts page content (initial sections only for fast display).
    func getCharts() async throws -> HomeResponse

    /// Fetches the next batch of charts sections via continuation.
    func getChartsContinuation() async throws -> [HomeSection]?

    /// Whether more charts sections are available to load.
    var hasMoreChartsSections: Bool { get }

    /// Fetches the moods and genres page content (initial sections only for fast display).
    func getMoodsAndGenres() async throws -> HomeResponse

    /// Fetches the next batch of moods and genres sections via continuation.
    func getMoodsAndGenresContinuation() async throws -> [HomeSection]?

    /// Whether more moods and genres sections are available to load.
    var hasMoreMoodsAndGenresSections: Bool { get }

    /// Fetches the new releases page content (initial sections only for fast display).
    func getNewReleases() async throws -> HomeResponse

    /// Fetches the next batch of new releases sections via continuation.
    func getNewReleasesContinuation() async throws -> [HomeSection]?

    /// Whether more new releases sections are available to load.
    var hasMoreNewReleasesSections: Bool { get }

    /// Fetches the podcasts page content (initial sections only for fast display).
    func getPodcasts() async throws -> HomeResponse

    /// Fetches the next batch of podcasts sections via continuation.
    func getPodcastsContinuation() async throws -> [HomeSection]?

    /// Whether more podcasts sections are available to load.
    var hasMorePodcastsSections: Bool { get }

    /// Searches for content.
    func search(query: String) async throws -> SearchResponse

    /// Searches for songs only (filtered search, excludes videos/podcasts/episodes).
    func searchSongs(query: String) async throws -> [Song]

    /// Fetches search suggestions for autocomplete.
    func getSearchSuggestions(query: String) async throws -> [SearchSuggestion]

    /// Fetches the user's library playlists.
    func getLibraryPlaylists() async throws -> [Playlist]

    /// Fetches the user's liked songs.
    func getLikedSongs() async throws -> [Song]

    /// Fetches playlist details including tracks.
    func getPlaylist(id: String) async throws -> PlaylistDetail

    /// Fetches artist details including their songs and albums.
    func getArtist(id: String) async throws -> ArtistDetail

    /// Fetches all songs for an artist using the songs browse endpoint.
    func getArtistSongs(browseId: String, params: String?) async throws -> [Song]

    /// Rates a song (like/dislike/indifferent).
    func rateSong(videoId: String, rating: LikeStatus) async throws

    /// Adds or removes a song from the user's library.
    func editSongLibraryStatus(feedbackTokens: [String]) async throws

    /// Adds a playlist to the user's library.
    func subscribeToPlaylist(playlistId: String) async throws

    /// Removes a playlist from the user's library.
    func unsubscribeFromPlaylist(playlistId: String) async throws

    /// Subscribes to an artist (adds to library).
    func subscribeToArtist(channelId: String) async throws

    /// Unsubscribes from an artist (removes from library).
    func unsubscribeFromArtist(channelId: String) async throws

    /// Fetches lyrics for a song.
    func getLyrics(videoId: String) async throws -> Lyrics

    /// Fetches song metadata by video ID.
    func getSong(videoId: String) async throws -> Song

    /// Fetches a radio queue (similar songs) based on a video ID.
    /// Returns an array of songs that form a "radio" playlist based on the seed track.
    func getRadioQueue(videoId: String) async throws -> [Song]

    /// Fetches content for a moods/genres category page.
    /// Returns sections of songs/playlists for the category.
    func getMoodCategory(browseId: String, params: String?) async throws -> HomeResponse
}

// MARK: - AuthServiceProtocol

/// Protocol defining the interface for authentication operations.
/// Enables dependency injection and mocking for tests.
@MainActor
protocol AuthServiceProtocol: AnyObject, Sendable {
    /// Current authentication state.
    var state: AuthService.State { get }

    /// Flag indicating whether re-authentication is needed.
    var needsReauth: Bool { get set }

    /// Starts the login flow by presenting the login sheet.
    func startLogin()

    /// Checks if the user is logged in based on existing cookies.
    func checkLoginStatus() async

    /// Called when a session expires (e.g., 401/403 from API).
    func sessionExpired()

    /// Signs out the user by clearing all cookies and data.
    func signOut() async

    /// Called when login completes successfully.
    func completeLogin(sapisid: String)
}

// MARK: - PlayerServiceProtocol

/// Protocol defining the interface for playback control.
/// Enables dependency injection and mocking for tests.
@MainActor
protocol PlayerServiceProtocol: AnyObject, Sendable {
    /// Current playback state.
    var state: PlayerService.PlaybackState { get }

    /// Currently playing track.
    var currentTrack: Song? { get }

    /// Whether playback is active.
    var isPlaying: Bool { get }

    /// Current playback position in seconds.
    var progress: TimeInterval { get }

    /// Total duration of current track in seconds.
    var duration: TimeInterval { get }

    /// Current volume (0.0 - 1.0).
    var volume: Double { get }

    /// Whether audio is currently muted.
    var isMuted: Bool { get }

    /// Whether shuffle mode is enabled.
    var shuffleEnabled: Bool { get }

    /// Current repeat mode.
    var repeatMode: PlayerService.RepeatMode { get }

    /// Playback queue.
    var queue: [Song] { get }

    /// Index of current track in queue.
    var currentIndex: Int { get }

    /// Whether the mini player should be shown.
    var showMiniPlayer: Bool { get set }

    /// Like status of the current track.
    var currentTrackLikeStatus: LikeStatus { get }

    /// Whether the current track is in the user's library.
    var currentTrackInLibrary: Bool { get }

    // MARK: - Playback Control

    /// Plays a track by video ID.
    func play(videoId: String) async

    /// Plays a song.
    func play(song: Song) async

    /// Toggles play/pause.
    func playPause() async

    /// Pauses playback.
    func pause() async

    /// Resumes playback.
    func resume() async

    /// Skips to next track.
    func next() async

    /// Goes to previous track.
    func previous() async

    /// Seeks to a specific time.
    func seek(to time: TimeInterval) async

    /// Sets the volume.
    func setVolume(_ value: Double) async

    /// Toggles mute state.
    func toggleMute() async

    /// Toggles shuffle mode.
    func toggleShuffle()

    /// Cycles through repeat modes.
    func cycleRepeatMode()

    /// Stops playback and clears state.
    func stop() async

    /// Plays a queue of songs starting at the specified index.
    func playQueue(_ songs: [Song], startingAt index: Int) async

    /// Plays a song and fetches similar songs (radio queue) in the background.
    /// The queue will be populated with similar songs from YouTube Music's radio feature.
    func playWithRadio(song: Song) async

    // MARK: - Like/Library Actions

    /// Likes the current track.
    func likeCurrentTrack()

    /// Dislikes the current track.
    func dislikeCurrentTrack()

    /// Toggles the library status of the current track.
    func toggleLibraryStatus()

    // MARK: - State Updates

    /// Called when the mini player confirms playback has started.
    func confirmPlaybackStarted()

    /// Called when the mini player is dismissed.
    func miniPlayerDismissed()

    /// Updates playback state from the WebView observer.
    func updatePlaybackState(isPlaying: Bool, progress: Double, duration: Double)

    /// Updates track metadata when track changes.
    func updateTrackMetadata(title: String, artist: String, thumbnailUrl: String)

    /// Updates the like status from WebView observation.
    func updateLikeStatus(_ status: LikeStatus)
}
