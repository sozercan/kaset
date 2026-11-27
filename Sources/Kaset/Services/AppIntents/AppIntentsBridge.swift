import Foundation

enum AppIntentsError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notReady
    case nothingPlaying
    case signInRequired
    case musicDisabled
    case noResults(query: String)
    case playbackFailed(title: String)
    case ratingFailed(title: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            "Kaset is still starting up. Try again in a moment."
        case .nothingPlaying:
            "Nothing is playing in Kaset."
        case .signInRequired:
            "Sign in to YouTube Music in Kaset first."
        case .musicDisabled:
            "YouTube Music is disabled in Kaset's App Mode settings."
        case let .noResults(query):
            "No songs found for “\(query)”."
        case let .playbackFailed(title):
            "Couldn't play “\(title)”."
        case let .ratingFailed(title):
            "Couldn't rate “\(title)”."
        }
    }
}

struct AppIntentsLibrary: Equatable {
    static let empty = AppIntentsLibrary(playlists: [], albums: [])

    let playlists: [Playlist]
    let albums: [Album]

    var playablePlaylists: [Playlist] {
        self.playlists.filter { !$0.isUploadedSongs }
    }

    var playableAlbums: [Album] {
        self.albums.filter(\.hasNavigableId)
    }
}

@MainActor
final class AppIntentsBridge {
    static let shared = AppIntentsBridge()

    var startupTimeout: Duration = .seconds(30)

    private(set) var playerService: PlayerService?
    private(set) var client: (any YTMusicClientProtocol)?

    private var publishedLibrary: AppIntentsLibrary?

    var library: AppIntentsLibrary {
        self.publishedLibrary ?? .empty
    }

    private var isAuthInitializing: () -> Bool = { true }
    private var hasPersonalAccount: () -> Bool = { false }
    private var isMusicEnabled: () -> Bool = { true }
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
        isMusicEnabled: @escaping () -> Bool = { true },
        transportHandler: @escaping (RemoteMusicCommandPayload) -> Bool,
        libraryDidChange: @escaping (AppIntentsLibrary) -> Void = { _ in }
    ) {
        self.playerService = playerService
        self.client = client
        self.isAuthInitializing = isAuthInitializing
        self.hasPersonalAccount = hasPersonalAccount
        self.isMusicEnabled = isMusicEnabled
        self.transportHandler = transportHandler
        self.libraryDidChange = libraryDidChange
    }

    func configureForLaunch(
        playerService: PlayerService,
        client: any YTMusicClientProtocol,
        authService: AuthService
    ) {
        let spotlightIndexer = UITestConfig.isUITestMode || UITestConfig.isRunningUnitTests
            ? nil
            : SpotlightLibraryIndexer()
        self.configure(
            playerService: playerService,
            client: client,
            isAuthInitializing: { [authService] in authService.state.isInitializing },
            hasPersonalAccount: { [authService] in authService.hasPersonalAccount },
            isMusicEnabled: { SettingsManager.shared.appExperience.includesMusic },
            transportHandler: { NowPlayingManager.shared.handleAppIntentCommand($0) },
            libraryDidChange: { library in
                spotlightIndexer?.update(library)
                KasetShortcuts.updateAppShortcutParameters()
            }
        )
    }

    func setShowMainWindowHandler(_ handler: @escaping () -> Void) {
        self.showMainWindowHandler = handler
    }

    func markStartupComplete() {
        self.isStartupComplete = true
    }

    var isReady: Bool {
        self.playerService != nil && self.isStartupComplete && !self.isAuthInitializing()
    }

    var isSignedIn: Bool {
        self.hasPersonalAccount()
    }

    func waitUntilReady() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: self.startupTimeout)
        while !self.isReady {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    func updateLibrary(_ library: AppIntentsLibrary) {
        guard library != self.publishedLibrary else { return }
        self.publishedLibrary = library
        self.libraryDidChange(library)
    }

    func sendTransportCommand(_ payload: RemoteMusicCommandPayload) throws {
        guard self.isReady, self.transportHandler(payload) else {
            throw AppIntentsError.nothingPlaying
        }
    }

    var currentSong: Song? {
        guard self.isReady else { return nil }
        return self.playerService?.currentTrack
    }

    @discardableResult
    func rateCurrentSong(_ status: LikeStatus) async throws -> Song {
        guard self.isReady, let playerService, let track = playerService.currentTrack else {
            throw AppIntentsError.nothingPlaying
        }
        guard playerService.canPerformAccountMutation else {
            throw AppIntentsError.signInRequired
        }
        let isPending = playerService.songLikeStatusManager.hasPendingRating(for: track.videoId)
        guard playerService.currentTrackLikeStatus != status || isPending else { return track }

        guard let rating = playerService.rateCurrentTrack(status), await rating.value == status else {
            throw AppIntentsError.ratingFailed(title: track.title)
        }
        return track
    }

    private func preparePlayback() async throws -> (PlayerService, any YTMusicClientProtocol) {
        guard self.isMusicEnabled() else {
            throw AppIntentsError.musicDisabled
        }
        guard await self.waitUntilReady(), let playerService, let client else {
            throw AppIntentsError.notReady
        }
        guard self.isMusicEnabled() else {
            throw AppIntentsError.musicDisabled
        }
        self.showMainWindowHandler?()
        return (playerService, client)
    }

    func play(song: Song) async throws {
        guard song.isPlayable else { throw AppIntentsError.playbackFailed(title: song.title) }
        let (playerService, _) = try await self.preparePlayback()
        let intent = playerService.beginMusicPlaybackIntent()
        await self.startRadio(from: song, playerService: playerService, intent: intent)
    }

    @discardableResult
    func playSearchResult(for query: String) async throws -> Song {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { throw AppIntentsError.noResults(query: query) }
        let (playerService, client) = try await self.preparePlayback()
        let reservation = playerService.reserveMusicPlaybackIntent()
        guard let song = try await Self.bestSong(in: client.searchSongs(query: trimmedQuery)) else {
            throw AppIntentsError.noResults(query: trimmedQuery)
        }
        guard self.isMusicEnabled() else {
            throw AppIntentsError.musicDisabled
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

    func play(playlist: Playlist) async throws {
        guard self.isMusicEnabled() else { throw AppIntentsError.musicDisabled }
        if LikedMusicPlaylist.matches(id: playlist.id) {
            guard await self.waitUntilReady() else { throw AppIntentsError.notReady }
            guard self.isMusicEnabled() else { throw AppIntentsError.musicDisabled }
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

    static func bestSong(in songs: [Song]) -> Song? {
        songs.first { $0.isPlayable && !$0.videoId.isEmpty }
    }

    func searchSongs(matching query: String) async throws -> [Song] {
        guard self.isMusicEnabled() else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, let client else { return [] }
        return try await client.searchSongs(query: trimmedQuery).filter(\.isPlayable)
    }

    func searchPlaylists(matching query: String) async throws -> [Playlist] {
        guard self.isMusicEnabled() else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, let client else { return [] }
        return try await client.searchPlaylists(query: trimmedQuery).playlists
    }

    func searchAlbums(matching query: String) async throws -> [Album] {
        guard self.isMusicEnabled() else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, let client else { return [] }
        return try await client.searchAlbums(query: trimmedQuery).albums.filter(\.hasNavigableId)
    }

    func song(videoId: String) async -> Song? {
        guard self.isMusicEnabled() else { return nil }
        if let queued = self.playerService?.queue.first(where: { $0.videoId == videoId }) {
            return queued
        }
        return try? await self.client?.getSong(videoId: videoId)
    }
}
