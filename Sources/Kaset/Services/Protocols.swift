import Foundation

@MainActor
protocol WebKitManagerProtocol: AnyObject, Sendable {
    func getAllCookies() async -> [HTTPCookie]

    func getCookies(for domain: String) async -> [HTTPCookie]

    func cookieHeader(for domain: String) async -> String?

    func getSAPISID() async -> String?

    func hasAuthCookies() async -> Bool

    @discardableResult
    func invalidateAuthCookieRestoration() -> Bool

    @discardableResult
    func clearAuthCookies() async -> Bool

    @discardableResult
    func clearAllData() async -> Bool

    func forceBackupCookies() async -> Bool

    var loginCookieBackupSetupRequiresCleanup: Bool { get }

    func beginLoginCookieBackup() async -> CookieBackupTransaction?

    func clearLiveLoginCookies(for transaction: CookieBackupTransaction) async -> Bool

    func refreshLoginCookieBackup(_ transaction: CookieBackupTransaction) async -> Bool

    func isLoginCookieBackupActive(_ transaction: CookieBackupTransaction) async -> Bool

    func hasLoginCookieSnapshotChanged(_ transaction: CookieBackupTransaction) async -> Bool

    @discardableResult
    func commitLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async -> String?

    @discardableResult
    func finalizeLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async -> String?

    func prepareLoginCookieBackupRollback(
        _ transaction: CookieBackupTransaction
    ) async -> Bool

    func rollbackLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async -> CookieBackupRollbackResult

    func waitForInitialCookieRestore() async -> CookieRestoreResult

    func logAuthCookies() async

    func switchSessionIdentity(to signinURL: URL, expectedBrandId: String?) async throws
}

@MainActor
protocol YTMusicClientProtocol: Sendable {
    func getHome(forceRefresh: Bool) async throws -> HomeResponse

    func getHomeContinuation() async throws -> [HomeSection]?

    var hasMoreHomeSections: Bool { get }

    func getPersonalizedRecommendations() async throws -> HomeResponse

    func getPersonalizedRecommendationsContinuation() async throws -> [HomeSection]?

    var hasMorePersonalizedRecommendationSections: Bool { get }

    func getExplore() async throws -> HomeResponse

    func getExploreContinuation() async throws -> [HomeSection]?

    var hasMoreExploreSections: Bool { get }

    func getCharts() async throws -> HomeResponse

    func getChartsContinuation() async throws -> [HomeSection]?

    var hasMoreChartsSections: Bool { get }

    func getMoodsAndGenres() async throws -> HomeResponse

    func getMoodsAndGenresContinuation() async throws -> [HomeSection]?

    var hasMoreMoodsAndGenresSections: Bool { get }

    func getNewReleases() async throws -> HomeResponse

    func getNewReleasesContinuation() async throws -> [HomeSection]?

    var hasMoreNewReleasesSections: Bool { get }

    func getHistory() async throws -> HomeResponse

    func getHistoryContinuation() async throws -> [HomeSection]?

    var hasMoreHistorySections: Bool { get }

    func getPodcasts() async throws -> [PodcastSection]

    func getPodcastsContinuation() async throws -> [PodcastSection]?

    var hasMorePodcastsSections: Bool { get }

    func getPodcastShow(browseId: String) async throws -> PodcastShowDetail

    func getPodcastEpisodesContinuation(token: String) async throws -> PodcastEpisodesContinuation

    func search(query: String) async throws -> SearchResponse

    func searchSongs(query: String) async throws -> [Song]

    func searchSongsWithPagination(query: String) async throws -> SearchResponse

    func searchVideos(query: String) async throws -> SearchResponse

    func searchAlbums(query: String) async throws -> SearchResponse

    func searchArtists(query: String) async throws -> SearchResponse

    func searchProfiles(query: String) async throws -> SearchResponse

    func searchPlaylists(query: String) async throws -> SearchResponse

    func searchFeaturedPlaylists(query: String) async throws -> SearchResponse

    func searchCommunityPlaylists(query: String) async throws -> SearchResponse

    func searchPodcasts(query: String) async throws -> SearchResponse

    func searchEpisodes(query: String) async throws -> SearchResponse

    func getSearchContinuation(token: String) async throws -> SearchResponse

    func resetSessionStateForAccountSwitch()

    func getSearchSuggestions(query: String) async throws -> [SearchSuggestion]

    func getLibraryPlaylists() async throws -> [Playlist]

    func getLibraryContent() async throws -> PlaylistParser.LibraryContent

    func getLikedSongs() async throws -> LikedSongsResponse

    func getLikedSongsContinuation() async throws -> LikedSongsResponse?

    var hasMoreLikedSongs: Bool { get }

    func getPlaylist(id: String) async throws -> PlaylistTracksResponse

    func getPlaylistAllTracks(playlistId: String) async throws -> [Song]

    func getPlaylistContinuation(token: String, requiresAuth: Bool) async throws -> PlaylistContinuationResponse

    func getArtist(id: String) async throws -> ArtistDetail

    func getArtistSongs(browseId: String, params: String?) async throws -> [Song]

    func getArtistDiscography(browseId: String, params: String?) async throws -> [Album]

    func getArtistEpisodesList(browseId: String, params: String?) async throws -> [ArtistEpisode]

    func rateSong(videoId: String, rating: LikeStatus) async throws

    func editSongLibraryStatus(feedbackTokens: [String]) async throws

    func subscribeToPlaylist(playlistId: String) async throws

    func deletePlaylist(playlistId: String) async throws

    func getAddToPlaylistOptions(videoId: String) async throws -> AddToPlaylistMenu

    func addSongToPlaylist(videoId: String, playlistId: String) async throws

    func removeSongFromPlaylist(videoId: String, setVideoId: String, playlistId: String) async throws

    func createPlaylist(
        title: String,
        description: String?,
        privacyStatus: PlaylistPrivacyStatus,
        videoIds: [String]
    ) async throws -> String

    func unsubscribeFromPlaylist(playlistId: String) async throws

    func subscribeToPodcast(showId: String) async throws

    func unsubscribeFromPodcast(showId: String) async throws

    func subscribeToArtist(channelId: String) async throws

    func unsubscribeFromArtist(channelId: String) async throws

    func getLyrics(videoId: String) async throws -> Lyrics

    func getTimedLyrics(videoId: String) async throws -> LyricResult

    func getSong(videoId: String) async throws -> Song

    func getRadioQueue(videoId: String) async throws -> [Song]

    func getMixQueue(playlistId: String, startVideoId: String?) async throws -> RadioQueueResult

    func getMixQueueContinuation(continuationToken: String) async throws -> RadioQueueResult

    func getMoodCategory(browseId: String, params: String?) async throws -> HomeResponse

    func fetchAccountsList(allowGuestMode: Bool) async throws -> AccountsListResponse
}

extension YTMusicClientProtocol {
    func fetchAccountsList() async throws -> AccountsListResponse {
        try await self.fetchAccountsList(allowGuestMode: false)
    }

    func getPlaylistContinuation(token: String) async throws -> PlaylistContinuationResponse {
        try await self.getPlaylistContinuation(token: token, requiresAuth: false)
    }
}

struct LoginAttemptID: Equatable, Sendable {
    let rawValue: UInt64
}

@MainActor
protocol AuthServiceProtocol: AnyObject, Sendable {
    var state: AuthService.State { get }

    var needsReauth: Bool { get set }

    var activeLoginAttemptID: LoginAttemptID? { get }

    var loginCleanupRequired: Bool { get }

    var isLoginCleanupInProgress: Bool { get }

    var signOutSequence: UInt64 { get }

    func setLoginCleanupRequired(_ required: Bool)

    func startLogin()

    func checkLoginStatus() async

    func sessionExpired()

    @discardableResult
    func signOut() async -> Bool

    func completeLoginAfterDraining(
        expectedAttemptID: LoginAttemptID,
        persistBeforeCommit: @escaping @MainActor @Sendable () async -> String?,
        persistFinalSession: @escaping @MainActor @Sendable () async -> String?,
        willPublishLogin: @escaping @MainActor @Sendable () -> Void
    ) async -> Bool

    func resolveLoginRollbackAfterDraining(
        expectedAttemptID: LoginAttemptID?,
        prepareRollback: @escaping @MainActor @Sendable () async -> Bool,
        rollback: @escaping @MainActor @Sendable (_ forceCleanup: Bool) async -> CookieBackupRollbackResult
    ) async -> CookieBackupRollbackResult

    func clearFailedLoginAfterDraining(
        expectedAttemptID: LoginAttemptID,
        expectedSignOutSequence: UInt64,
        clearCookies: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Bool?
}

@MainActor
protocol PlayerServiceProtocol: AnyObject, Sendable {
    var state: PlayerService.PlaybackState { get }

    var currentTrack: Song? { get }

    var isPlaying: Bool { get }

    var progress: TimeInterval { get }

    var duration: TimeInterval { get }

    var volume: Double { get }

    var isMuted: Bool { get }

    var shuffleEnabled: Bool { get }

    var repeatMode: PlayerService.RepeatMode { get }

    var queue: [Song] { get }

    var currentIndex: Int { get }

    var activePlaybackQueueIndex: Int? { get }

    var showMiniPlayer: Bool { get set }

    var isMiniPlayerVisible: Bool { get set }

    var miniPlayerMode: PlayerService.MiniPlayerMode { get set }

    var miniPlayerPanel: PlayerService.MiniPlayerPanel { get set }

    var shouldRestoreMainWindowWhenMiniPlayerCloses: Bool { get set }

    var currentTrackLikeStatus: LikeStatus { get }

    var currentTrackInLibrary: Bool { get }

    func play(videoId: String) async

    func play(song: Song) async

    func playPause() async

    func pause() async

    func resume() async

    func next() async

    func previous() async

    func seek(to time: TimeInterval) async

    func setVolume(_ value: Double) async

    func toggleMute() async

    func toggleShuffle()

    func cycleRepeatMode()

    func openMiniPlayer(mode: PlayerService.MiniPlayerMode)

    @discardableResult
    func toggleMiniPlayer(mode: PlayerService.MiniPlayerMode) -> Bool

    @discardableResult
    func closeMiniPlayer() -> Bool

    func consumeMiniPlayerMainWindowRestoreRequest() -> Bool

    func toggleMiniPlayerPanel()

    func stop() async

    func reserveMusicPlaybackIntent() -> MusicPlaybackReservation

    func claimMusicPlaybackIntent(_ reservation: MusicPlaybackReservation) -> MusicPlaybackIntent?

    func acceptsMusicPlaybackReservation(_ reservation: MusicPlaybackReservation) -> Bool

    func reserveQueueMutation() -> Int

    func acceptsQueueMutation(_ generation: Int) -> Bool

    func acceptsMusicPlaybackIntent(_ intent: MusicPlaybackIntent) -> Bool

    func playQueue(_ songs: [Song], startingAt index: Int) async

    @discardableResult
    func playQueue(
        _ songs: [Song],
        startingAt index: Int,
        deferringSmartShuffleFill: Bool,
        intent: MusicPlaybackIntent
    ) async -> Int?

    func playWithRadio(song: Song) async

    func playWithMix(
        playlistId: String,
        startVideoId: String?,
        intent: MusicPlaybackIntent?
    ) async

    func clearQueue()

    func shuffleQueue()

    func appendToQueue(_ songs: [Song])

    func likeCurrentTrack()

    func dislikeCurrentTrack()

    func toggleLibraryStatus()

    func confirmPlaybackStarted()

    func miniPlayerDismissed()

    func updatePlaybackState(isPlaying: Bool, progress: Double, duration: Double)

    func updateTrackMetadata(title: String, artist: String, thumbnailUrl: String, videoId: String?)

    func updateLikeStatus(_ status: LikeStatus)
}

extension PlayerServiceProtocol {
    func playWithMix(playlistId: String, startVideoId: String?) async {
        await self.playWithMix(
            playlistId: playlistId,
            startVideoId: startVideoId,
            intent: nil
        )
    }
}
