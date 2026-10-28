import Foundation

// MARK: - AppIntentsError

/// Failures App Intents report back to Shortcuts and Siri.
enum AppIntentsError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    /// A cold launch did not finish restoring sign-in state in time.
    case notReady
    /// A control intent ran while nothing was loaded in the player.
    case nothingPlaying
    /// The action needs a signed-in YouTube Music account.
    case signInRequired
    /// A search returned nothing playable.
    case noResults(query: String)
    /// Content failed to load, had nothing playable, or newer playback replaced it first.
    case playbackFailed(title: String)
    /// YouTube Music did not accept the rating.
    case ratingFailed(title: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            "Kaset is still starting up. Try again in a moment."
        case .nothingPlaying:
            "Nothing is playing in Kaset."
        case .signInRequired:
            "Sign in to YouTube Music in Kaset first."
        case let .noResults(query):
            "No songs found for “\(query)”."
        case let .playbackFailed(title):
            "Couldn't play “\(title)”."
        case let .ratingFailed(title):
            "Couldn't rate “\(title)”."
        }
    }
}

// MARK: - AppIntentsLibrary

/// The signed-in account's Library playlists and saved albums, as published by `MainWindow`.
struct AppIntentsLibrary: Equatable {
    static let empty = AppIntentsLibrary(playlists: [], albums: [])

    let playlists: [Playlist]
    let albums: [Album]

    /// Playlists that can be played by ID. The uploads shelf is a browse page, not a playlist.
    var playablePlaylists: [Playlist] {
        self.playlists.filter { !$0.isUploadedSongs }
    }

    /// Albums whose ID can be fetched as a playlist.
    var playableAlbums: [Album] {
        self.albums.filter(\.hasNavigableId)
    }
}

// MARK: - AppIntentsBridge

/// Gives App Intents (Shortcuts, Siri, Spotlight) access to the running app's services.
///
/// The system creates intents and entity queries itself, so they cannot receive SwiftUI
/// environment values. `KasetApp` configures this bridge at launch, the same way
/// `PlayerService.shared` is exposed to AppleScript, and intents stay thin wrappers over it.
@MainActor
final class AppIntentsBridge {
    static let shared = AppIntentsBridge()

    /// How long a playback intent waits for a cold launch to finish startup.
    var startupTimeout: Duration = .seconds(30)

    private(set) var playerService: PlayerService?
    private(set) var client: (any YTMusicClientProtocol)?

    /// Nil until `MainWindow` publishes the first snapshot, so that snapshot always propagates.
    private var publishedLibrary: AppIntentsLibrary?

    var library: AppIntentsLibrary {
        self.publishedLibrary ?? .empty
    }

    private var isAuthInitializing: () -> Bool = { true }
    private var hasPersonalAccount: () -> Bool = { false }
    private var isStartupComplete = false
    private var showMainWindowHandler: (() -> Void)?
    private var transportHandler: (RemoteMusicCommandPayload) -> Bool = { _ in false }
    private var libraryDidChange: (AppIntentsLibrary) -> Void = { _ in }
    private let logger = DiagnosticsLogger.appIntents

    func configure(
        playerService: PlayerService,
        client: any YTMusicClientProtocol,
        isAuthInitializing: @escaping () -> Bool,
        hasPersonalAccount: @escaping () -> Bool,
        transportHandler: @escaping (RemoteMusicCommandPayload) -> Bool,
        libraryDidChange: @escaping (AppIntentsLibrary) -> Void = { _ in }
    ) {
        self.playerService = playerService
        self.client = client
        self.isAuthInitializing = isAuthInitializing
        self.hasPersonalAccount = hasPersonalAccount
        self.transportHandler = transportHandler
        self.libraryDidChange = libraryDidChange
    }

    /// Wires the bridge to the app's services at launch.
    func configureForLaunch(
        playerService: PlayerService,
        client: any YTMusicClientProtocol,
        authService: AuthService
    ) {
        // UI tests run against mock data that must never reach the user's Spotlight index.
        let spotlightIndexer = UITestConfig.isUITestMode || UITestConfig.isRunningUnitTests
            ? nil
            : SpotlightLibraryIndexer()
        self.configure(
            playerService: playerService,
            client: client,
            isAuthInitializing: { [authService] in authService.state.isInitializing },
            hasPersonalAccount: { [authService] in authService.hasPersonalAccount },
            transportHandler: { NowPlayingManager.shared.handleAppIntentCommand($0) },
            libraryDidChange: { library in
                spotlightIndexer?.update(library)
                // Siri matches "Play <playlist> in Kaset" against the current Library.
                KasetShortcuts.updateAppShortcutParameters()
            }
        )
    }

    /// Set once the main window can be shown, mirroring how deep links open it.
    func setShowMainWindowHandler(_ handler: @escaping () -> Void) {
        self.showMainWindowHandler = handler
    }

    // MARK: Readiness

    /// Called when startup has restored sign-in state and cleared stale playback,
    /// the same point at which deferred deep links are replayed.
    func markStartupComplete() {
        self.isStartupComplete = true
    }

    /// Whether playback can start: the same gate `kaset://` deep links wait for.
    var isReady: Bool {
        self.playerService != nil && self.isStartupComplete && !self.isAuthInitializing()
    }

    /// Whether a personal YouTube Music account is signed in (not guest mode).
    var isSignedIn: Bool {
        self.hasPersonalAccount()
    }

    /// Waits for a cold launch to reach `isReady`. Returns false on timeout or cancellation.
    func waitUntilReady() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: self.startupTimeout)
        while !self.isReady {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    // MARK: Library

    func updateLibrary(_ library: AppIntentsLibrary) {
        guard library != self.publishedLibrary else { return }
        self.publishedLibrary = library
        self.libraryDidChange(library)
    }

    // MARK: Transport

    /// Sends play/pause/skip through the media-key path. Throws when the player is not up yet or
    /// has nothing loaded to control.
    func sendTransportCommand(_ payload: RemoteMusicCommandPayload) throws {
        guard self.isReady, self.transportHandler(payload) else {
            throw AppIntentsError.nothingPlaying
        }
    }

    // MARK: Now Playing

    /// The track loaded in the music player, if any.
    var currentSong: Song? {
        guard self.isReady else { return nil }
        return self.playerService?.currentTrack
    }

    /// Rates the current track once YouTube Music accepts it. Rating is idempotent here, unlike
    /// the player-bar toggle: asking to like an already-liked song leaves it liked.
    @discardableResult
    func rateCurrentSong(_ status: LikeStatus) async throws -> Song {
        guard self.isReady, let playerService, let track = playerService.currentTrack else {
            throw AppIntentsError.nothingPlaying
        }
        guard playerService.canPerformAccountMutation else {
            throw AppIntentsError.signInRequired
        }
        // A pending rating already shows optimistically, so wait on the serialized path instead of trusting it.
        let isPending = playerService.songLikeStatusManager.hasPendingRating(for: track.videoId)
        guard playerService.currentTrackLikeStatus != status || isPending else { return track }

        // A rejected rating rolls back to the previous status.
        guard let rating = playerService.rateCurrentTrack(status), await rating.value == status else {
            throw AppIntentsError.ratingFailed(title: track.title)
        }
        return track
    }

    // MARK: Playback

    /// Waits for startup, then shows the main window the way a deep link does.
    /// The playback WebView lives in that window's hierarchy.
    private func preparePlayback() async throws -> (PlayerService, any YTMusicClientProtocol) {
        guard await self.waitUntilReady(), let playerService, let client else {
            throw AppIntentsError.notReady
        }
        self.showMainWindowHandler?()
        return (playerService, client)
    }

    /// Plays a song and continues with its radio, like `kaset://play` and AppleScript `play video`.
    func play(song: Song) async throws {
        // A known-unavailable song would replace the queue without anything to play.
        guard song.isPlayable else { throw AppIntentsError.playbackFailed(title: song.title) }
        let (playerService, _) = try await self.preparePlayback()
        let intent = playerService.beginMusicPlaybackIntent()
        await self.startRadio(from: song, playerService: playerService, intent: intent)
    }

    /// Plays the best song match for a free-text query.
    @discardableResult
    func playSearchResult(for query: String) async throws -> Song {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { throw AppIntentsError.noResults(query: query) }
        let (playerService, client) = try await self.preparePlayback()
        // Playback the user starts while the search is in flight wins over its result.
        let reservation = playerService.reserveMusicPlaybackIntent()
        guard let song = try await Self.bestSong(in: client.searchSongs(query: trimmedQuery)) else {
            throw AppIntentsError.noResults(query: trimmedQuery)
        }
        guard let intent = playerService.claimMusicPlaybackIntent(reservation) else {
            throw AppIntentsError.playbackFailed(title: song.title)
        }
        await self.startRadio(from: song, playerService: playerService, intent: intent)
        return song
    }

    private func startRadio(from song: Song, playerService: PlayerService, intent: MusicPlaybackIntent) async {
        self.logger.info("Playing song \(song.videoId)")
        await playerService.playWithRadio(song: song, intent: intent)
    }

    /// Returns once the playlist starts; a long playlist keeps paging in afterward.
    func play(playlist: Playlist) async throws {
        // Checked once startup has restored sign-in state, but before the window comes forward.
        if LikedMusicPlaylist.matches(id: playlist.id) {
            guard await self.waitUntilReady() else { throw AppIntentsError.notReady }
            guard self.isSignedIn else { throw AppIntentsError.signInRequired }
        }
        let (playerService, client) = try await self.preparePlayback()
        self.logger.info("Playing playlist \(playlist.id)")
        let started = await withCheckedContinuation { continuation in
            PlaylistPlaybackActions.playPlaylist(playlist, client: client, playerService: playerService) { started in
                continuation.resume(returning: started)
            }
        }
        guard started else { throw AppIntentsError.playbackFailed(title: playlist.title) }
    }

    func play(album: Album) async throws {
        let (playerService, client) = try await self.preparePlayback()
        self.logger.info("Playing album \(album.id)")
        let started = await withCheckedContinuation { continuation in
            AlbumPlaybackActions.playAlbum(album, client: client, playerService: playerService) { started in
                continuation.resume(returning: started)
            }
        }
        guard started else { throw AppIntentsError.playbackFailed(title: album.title) }
    }

    /// The first result that can actually be played.
    static func bestSong(in songs: [Song]) -> Song? {
        songs.first { $0.isPlayable && !$0.videoId.isEmpty }
    }

    // MARK: Search

    /// Song search for entity pickers. Works before startup completes: it needs only the client.
    func searchSongs(matching query: String) async throws -> [Song] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, let client else { return [] }
        return try await client.searchSongs(query: trimmedQuery).filter(\.isPlayable)
    }

    func searchPlaylists(matching query: String) async throws -> [Playlist] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, let client else { return [] }
        return try await client.searchPlaylists(query: trimmedQuery).playlists
    }

    func searchAlbums(matching query: String) async throws -> [Album] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, let client else { return [] }
        return try await client.searchAlbums(query: trimmedQuery).albums.filter(\.hasNavigableId)
    }

    /// Looks up a song by video ID for a saved Shortcuts parameter.
    func song(videoId: String) async -> Song? {
        if let queued = self.playerService?.queue.first(where: { $0.videoId == videoId }) {
            return queued
        }
        return try? await self.client?.getSong(videoId: videoId)
    }
}
