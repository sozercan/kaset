import Foundation
import Testing
@testable import Kaset

@Suite("App Intents bridge", .serialized, .tags(.service))
@MainActor
struct AppIntentsBridgeTests {
    /// Mutable flags the bridge reads through its closures.
    @MainActor
    private final class Environment {
        var isAuthInitializing = false
        var isSignedIn = false
        var acceptsTransport = true
        var transportPayloads: [RemoteMusicCommandPayload] = []
        var showMainWindowCount = 0
        var publishedLibraries: [AppIntentsLibrary] = []
    }

    init() {
        // Like requests run through the shared status manager; keep tests from leaking into each other.
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
    }

    private func makeBridge(
        playerService: PlayerService = PlayerService(),
        client: MockYTMusicClient = MockYTMusicClient(),
        environment: Environment = Environment(),
        startupComplete: Bool = true
    ) -> AppIntentsBridge {
        let bridge = AppIntentsBridge()
        bridge.startupTimeout = .milliseconds(300)
        bridge.configure(
            playerService: playerService,
            client: client,
            isAuthInitializing: { environment.isAuthInitializing },
            hasPersonalAccount: { environment.isSignedIn },
            transportHandler: { payload in
                environment.transportPayloads.append(payload)
                return environment.acceptsTransport
            },
            libraryDidChange: { environment.publishedLibraries.append($0) }
        )
        bridge.setShowMainWindowHandler { environment.showMainWindowCount += 1 }
        if startupComplete {
            bridge.markStartupComplete()
        }
        return bridge
    }

    private func signedInPlayer(client: MockYTMusicClient = MockYTMusicClient()) -> PlayerService {
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.completeLogin(sapisid: "test-sapisid")
        let player = PlayerService()
        player.setAuthService(authService)
        player.setYTMusicClient(client)
        return player
    }

    private func resetSingletonPlayer() {
        SingletonPlayerWebView.shared.tearDown()
        SingletonPlayerWebView.shared.currentVideoId = nil
    }

    // MARK: - Readiness

    @Test("Not ready before configuration, startup, or while auth initializes")
    func readinessGate() {
        #expect(!AppIntentsBridge().isReady)

        let environment = Environment()
        let bridge = self.makeBridge(environment: environment, startupComplete: false)
        #expect(!bridge.isReady)

        bridge.markStartupComplete()
        #expect(bridge.isReady)

        environment.isAuthInitializing = true
        #expect(!bridge.isReady)
    }

    @Test("Waiting returns once startup completes")
    func waitResumesWhenStartupCompletes() async {
        let bridge = self.makeBridge(startupComplete: false)
        // Generous: the full suite runs many async tests concurrently.
        bridge.startupTimeout = .seconds(10)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            bridge.markStartupComplete()
        }

        #expect(await bridge.waitUntilReady())
        #expect(bridge.isReady)
    }

    @Test("Waiting gives up after the startup timeout")
    func waitTimesOut() async {
        let bridge = self.makeBridge(startupComplete: false)
        #expect(await !bridge.waitUntilReady())
    }

    // MARK: - Transport

    @Test("Transport commands report nothing playing before startup completes")
    func transportBeforeStartup() {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment, startupComplete: false)

        #expect(throws: AppIntentsError.nothingPlaying) {
            try bridge.sendTransportCommand(.pause)
        }
        #expect(environment.transportPayloads.isEmpty)
    }

    @Test("Transport commands go through the media-key handler")
    func transportUsesHandler() throws {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment)

        try bridge.sendTransportCommand(.togglePlayPause)
        try bridge.sendTransportCommand(.trackNavigation(direction: .forward))

        #expect(environment.transportPayloads == [.togglePlayPause, .trackNavigation(direction: .forward)])
    }

    @Test("A transport handler that cannot route reports nothing playing")
    func transportHandlerRejects() {
        let environment = Environment()
        environment.acceptsTransport = false
        let bridge = self.makeBridge(environment: environment)

        #expect(throws: AppIntentsError.nothingPlaying) {
            try bridge.sendTransportCommand(.play)
        }
    }

    @Test("Media keys only accept intent commands when there is something to control")
    func transportTargetRequiresMedia() {
        let empty = PlayerService()
        #expect(!NowPlayingManager.hasTransportTarget(player: empty, routesToYouTubeVideo: false))
        #expect(NowPlayingManager.hasTransportTarget(player: empty, routesToYouTubeVideo: true))

        let loaded = PlayerService()
        loaded.currentTrack = TestFixtures.makeSong(id: "loaded")
        #expect(NowPlayingManager.hasTransportTarget(player: loaded, routesToYouTubeVideo: false))

        let restored = PlayerService()
        restored.pendingPlayVideoId = "restored"
        #expect(NowPlayingManager.hasTransportTarget(player: restored, routesToYouTubeVideo: false))
    }

    // MARK: - Rating

    @Test("Rating without a current track reports nothing playing")
    func ratingWithoutTrack() async {
        let bridge = self.makeBridge(playerService: self.signedInPlayer())

        await #expect(throws: AppIntentsError.nothingPlaying) {
            try await bridge.rateCurrentSong(.like)
        }
    }

    @Test("Rating requires a personal account")
    func ratingRequiresSignIn() async {
        let player = PlayerService()
        player.currentTrack = TestFixtures.makeSong(id: "guest-track")
        let bridge = self.makeBridge(playerService: player)

        await #expect(throws: AppIntentsError.signInRequired) {
            try await bridge.rateCurrentSong(.like)
        }
    }

    @Test("Liking an already-liked song leaves it liked")
    func likeIsIdempotent() async throws {
        let client = MockYTMusicClient()
        let player = self.signedInPlayer(client: client)
        player.currentTrack = TestFixtures.makeSong(id: "liked-track")
        player.currentTrackLikeStatus = .like
        let bridge = self.makeBridge(playerService: player, client: client)

        let song = try await bridge.rateCurrentSong(.like)

        #expect(song.videoId == "liked-track")
        #expect(player.currentTrackLikeStatus == .like)
        #expect(client.rateSongRatings.isEmpty)
    }

    @Test("Liking an unrated song likes it, and disliking replaces the like")
    func ratingSetsRequestedStatus() async throws {
        let client = MockYTMusicClient()
        let player = self.signedInPlayer(client: client)
        player.currentTrack = TestFixtures.makeSong(id: "rated-track")
        player.currentTrackLikeStatus = .indifferent
        let bridge = self.makeBridge(playerService: player, client: client)

        try await bridge.rateCurrentSong(.like)
        #expect(player.currentTrackLikeStatus == .like)

        try await bridge.rateCurrentSong(.dislike)
        #expect(player.currentTrackLikeStatus == .dislike)
        #expect(client.appliedRateSongRatings == [.like, .dislike])
    }

    @Test("A rating YouTube Music rejects reports failure and rolls back")
    func rejectedRatingIsReported() async {
        let client = MockYTMusicClient()
        client.rateSongErrors = [URLError(.notConnectedToInternet)]
        let player = self.signedInPlayer(client: client)
        player.currentTrack = TestFixtures.makeSong(id: "rejected-track", title: "Rejected")
        player.currentTrackLikeStatus = .indifferent
        let bridge = self.makeBridge(playerService: player, client: client)

        await #expect(throws: AppIntentsError.ratingFailed(title: "Rejected")) {
            try await bridge.rateCurrentSong(.like)
        }
        #expect(player.currentTrackLikeStatus == .indifferent)
    }

    @Test("A repeated rating waits for the pending one instead of trusting the optimistic status")
    func repeatedRatingWaitsForPendingRequest() async {
        let client = MockYTMusicClient()
        client.rateSongDelay = .milliseconds(20)
        client.rateSongErrors = [URLError(.notConnectedToInternet), URLError(.notConnectedToInternet)]
        let player = self.signedInPlayer(client: client)
        player.currentTrack = TestFixtures.makeSong(id: "pending-track", title: "Pending")
        player.currentTrackLikeStatus = .indifferent
        let bridge = self.makeBridge(playerService: player, client: client)

        // The player-bar like is still in flight when the intent asks for the same rating.
        player.likeCurrentTrack()
        await #expect(throws: AppIntentsError.ratingFailed(title: "Pending")) {
            try await bridge.rateCurrentSong(.like)
        }
        #expect(client.rateSongRatings == [.like, .like])
        #expect(player.currentTrackLikeStatus == .indifferent)
    }

    // MARK: - Playback

    @Test("The best song is the first playable result")
    func bestSongSkipsUnplayable() {
        let unplayable = Song(id: "blocked", title: "Blocked", artists: [], videoId: "blocked", isPlayable: false)
        let playable = TestFixtures.makeSong(id: "playable")

        #expect(AppIntentsBridge.bestSong(in: [unplayable, playable])?.videoId == "playable")
        #expect(AppIntentsBridge.bestSong(in: [unplayable]) == nil)
    }

    @Test("Playing a search result shows the window and plays the best match")
    func playSearchResultPlaysBestMatch() async throws {
        self.resetSingletonPlayer()
        defer { self.resetSingletonPlayer() }
        let client = MockYTMusicClient()
        let match = TestFixtures.makeSong(id: "match", title: "Get Lucky")
        client.songsSearchResponse = SearchResponse(songs: [match])
        let player = PlayerService()
        player.setYTMusicClient(client)
        let environment = Environment()
        let bridge = self.makeBridge(playerService: player, client: client, environment: environment)

        let song = try await bridge.playSearchResult(for: "  get lucky  ")

        #expect(song.videoId == "match")
        #expect(client.searchQueries.last == "get lucky")
        #expect(environment.showMainWindowCount == 1)
        #expect(player.currentTrack?.videoId == "match")
    }

    @Test("Playback started during a search wins over the search result")
    func newerPlaybackSupersedesSearchResult() async {
        self.resetSingletonPlayer()
        defer { self.resetSingletonPlayer() }
        let client = MockYTMusicClient()
        client.songsSearchResponse = SearchResponse(songs: [TestFixtures.makeSong(id: "match", title: "Get Lucky")])
        let searchStarted = AsyncGate()
        let releaseSearch = AsyncGate()
        client.beforeSearchReturn = { _, _ in
            await searchStarted.open()
            await releaseSearch.wait()
        }
        let player = PlayerService()
        player.setYTMusicClient(client)
        let bridge = self.makeBridge(playerService: player, client: client)

        let request = Task { try await bridge.playSearchResult(for: "get lucky") }
        await searchStarted.wait()
        await player.playQueue([TestFixtures.makeSong(id: "chosen")], startingAt: 0)
        await releaseSearch.open()

        await #expect(throws: AppIntentsError.playbackFailed(title: "Get Lucky")) {
            try await request.value
        }
        #expect(player.currentTrack?.videoId == "chosen")
    }

    @Test("A search with nothing playable reports no results")
    func playSearchResultWithoutMatches() async {
        let client = MockYTMusicClient()
        client.songsSearchResponse = .empty
        let bridge = self.makeBridge(client: client)

        await #expect(throws: AppIntentsError.noResults(query: "nothing")) {
            try await bridge.playSearchResult(for: "nothing")
        }
    }

    @Test("A blank query reports no results without searching")
    func playSearchResultWithBlankQuery() async {
        let client = MockYTMusicClient()
        let bridge = self.makeBridge(client: client)

        await #expect(throws: AppIntentsError.noResults(query: "   ")) {
            try await bridge.playSearchResult(for: "   ")
        }
        #expect(client.searchQueries.isEmpty)
    }

    @Test("Playback fails with not ready when a cold launch does not finish startup")
    func playbackTimesOutBeforeStartup() async {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment, startupComplete: false)

        await #expect(throws: AppIntentsError.notReady) {
            try await bridge.play(song: TestFixtures.makeSong(id: "cold"))
        }
        #expect(environment.showMainWindowCount == 0)
    }

    @Test("Liked Music requires a personal account and does not bring the window forward")
    func likedMusicRequiresSignIn() async {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment)

        await #expect(throws: AppIntentsError.signInRequired) {
            try await bridge.play(playlist: LikedMusicPlaylist.playlist)
        }
        #expect(environment.showMainWindowCount == 0)
    }

    @Test("Playing a playlist returns once it starts, while the rest pages in")
    func playlistReturnsBeforePaging() async throws {
        self.resetSingletonPlayer()
        defer { self.resetSingletonPlayer() }
        let client = MockYTMusicClient()
        let playlist = TestFixtures.makePlaylist(id: "VL-long", title: "Long")
        client.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: TestFixtures.makeSongs(count: 2),
            duration: nil
        )
        client.playlistContinuationTracks[playlist.id] = [["more-1", "more-2"].map { TestFixtures.makeSong(id: $0) }]
        let releaseContinuation = AsyncGate()
        client.beforePlaylistContinuationReturn = { _ in await releaseContinuation.wait() }
        // Lets a regression that waits for paging finish, and fail, instead of hanging.
        let safetyRelease = Task {
            try? await Task.sleep(for: .seconds(2))
            await releaseContinuation.open()
        }
        defer { safetyRelease.cancel() }
        let player = PlayerService()
        let bridge = self.makeBridge(playerService: player, client: client)

        try await bridge.play(playlist: playlist)

        #expect(player.queue.map(\.videoId) == ["video-0", "video-1"])
        await releaseContinuation.open()
    }

    @Test("A playlist that fails to load reports failure")
    func playlistLoadFailureIsReported() async {
        let client = MockYTMusicClient()
        client.getPlaylistError = URLError(.notConnectedToInternet)
        let bridge = self.makeBridge(client: client)

        await #expect(throws: AppIntentsError.playbackFailed(title: "Offline Mix")) {
            try await bridge.play(playlist: TestFixtures.makePlaylist(id: "VL-offline", title: "Offline Mix"))
        }
    }

    @Test("An album with nothing playable reports failure")
    func unavailableAlbumIsReported() async {
        let client = MockYTMusicClient()
        let album = TestFixtures.makeAlbum(id: "MPREb_unavailable", title: "Unavailable")
        client.playlistDetails[album.id] = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: album.id, title: album.title),
            tracks: [Song(id: "blocked", title: "Blocked", artists: [], videoId: "blocked", isPlayable: false)],
            duration: nil
        )
        let player = PlayerService()
        let bridge = self.makeBridge(playerService: player, client: client)

        await #expect(throws: AppIntentsError.playbackFailed(title: "Unavailable")) {
            try await bridge.play(album: album)
        }
        #expect(player.queue.isEmpty)
    }

    @Test("An album starts at its first playable track")
    func albumStartsAtFirstPlayableTrack() async throws {
        self.resetSingletonPlayer()
        defer { self.resetSingletonPlayer() }
        let client = MockYTMusicClient()
        let album = TestFixtures.makeAlbum(id: "MPREb_partial", title: "Partial")
        client.playlistDetails[album.id] = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: album.id, title: album.title),
            tracks: [
                Song(id: "blocked", title: "Blocked", artists: [], videoId: "blocked", isPlayable: false),
                TestFixtures.makeSong(id: "playable"),
            ],
            duration: nil
        )
        let player = PlayerService()
        let bridge = self.makeBridge(playerService: player, client: client)

        try await bridge.play(album: album)

        #expect(player.queue.map(\.videoId) == ["blocked", "playable"])
        #expect(player.currentTrack?.videoId == "playable")
    }

    @Test("A song known to be unavailable keeps that through its entity and is not played")
    func unavailableSongIsRejected() async {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment)
        let blocked = Song(id: "blocked", title: "Blocked", artists: [], videoId: "blocked", isPlayable: false)
        let entitySong = SongEntity(song: blocked).song
        #expect(!entitySong.isPlayable)

        await #expect(throws: AppIntentsError.playbackFailed(title: "Blocked")) {
            try await bridge.play(song: entitySong)
        }
        #expect(environment.showMainWindowCount == 0)
    }

    @Test("A saved song outside the queue is looked up on YouTube Music")
    func savedSongLookup() async {
        let client = MockYTMusicClient()
        client.songResponses["saved"] = TestFixtures.makeSong(id: "saved", title: "Saved Song")
        let bridge = self.makeBridge(client: client)

        #expect(await bridge.song(videoId: "saved")?.title == "Saved Song")

        client.getSongErrors = [URLError(.notConnectedToInternet)]
        #expect(await bridge.song(videoId: "offline") == nil)
    }

    // MARK: - Library

    @Test("Library changes are published once per distinct snapshot")
    func libraryPublishesChanges() {
        let environment = Environment()
        let bridge = self.makeBridge(environment: environment)
        let library = AppIntentsLibrary(playlists: [TestFixtures.makePlaylist()], albums: [])

        // The first snapshot always publishes, even when empty, so a stale index gets cleared.
        bridge.updateLibrary(.empty)
        bridge.updateLibrary(library)
        bridge.updateLibrary(library)

        #expect(environment.publishedLibraries == [.empty, library])
        #expect(bridge.library == library)
    }

    @Test("Only playable Library items are offered")
    func libraryFiltersUnplayableItems() {
        let uploads = TestFixtures.makePlaylist(id: Playlist.uploadedSongsBrowseID, title: "Uploads")
        let playlist = TestFixtures.makePlaylist(id: "PL-mix", title: "Mix")
        let album = TestFixtures.makeAlbum(id: "MPREb_album")
        let inlineAlbum = TestFixtures.makeAlbum(id: UUID().uuidString)
        let library = AppIntentsLibrary(playlists: [uploads, playlist], albums: [album, inlineAlbum])

        #expect(library.playablePlaylists.map(\.id) == ["PL-mix"])
        #expect(library.playableAlbums.map(\.id) == ["MPREb_album"])
    }
}
