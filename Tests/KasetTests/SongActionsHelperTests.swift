import Foundation
import Testing
@testable import Kaset

private let realWorldArtistIdMismatchCases = [
    (
        artistName: "EBEN",
        libraryBrowseId: "UCOml1XnMezHWWe0qy8vdFRA",
        subscriptionChannelId: "UCvIhrQ9BRWUxBNsDJQi8V5A"
    ),
]

// MARK: - SongActionsHelperTests

/// Tests for SongActionsHelper library mutation flows.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct SongActionsHelperTests {
    var mockClient: MockYTMusicClient
    var libraryViewModel: LibraryViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.libraryViewModel = LibraryViewModel(client: self.mockClient)
        APICache.shared.invalidateAll()
        URLCache.shared.removeAllCachedResponses()
        SongActionsHelper.artistLibraryReconciliationRetryDelays = [.milliseconds(1), .milliseconds(1)]
    }

    private func awaitArtistReconciliation(refreshes expectedRefreshCount: Int = 1) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while self.mockClient.getLibraryContentCallCount < expectedRefreshCount {
            guard clock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func awaitQueueCount(_ expectedCount: Int, in playerService: PlayerService) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while playerService.queue.count != expectedCount {
            guard clock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func awaitPlaylistContinuationReturns(_ expectedCount: Int = 1) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while self.mockClient.getPlaylistContinuationReturnCount < expectedCount {
            guard clock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Add to Library cannot toggle a newer track")
    func addToLibraryCannotMutateNewerTrack() async {
        let playerService = PlayerService()
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.completeLogin(sapisid: "REDACTED")
        playerService.setAuthService(authService)
        playerService.setYTMusicClient(self.mockClient)
        let songA = TestFixtures.makeSong(id: "library-a")
        let songB = TestFixtures.makeSong(id: "library-b")
        self.mockClient.songResponses[songA.videoId] = Song(
            id: songA.id,
            title: songA.title,
            artists: songA.artists,
            videoId: songA.videoId,
            feedbackTokens: FeedbackTokens(add: "a-add", remove: "a-remove")
        )
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        self.mockClient.beforeGetSongReturn = { videoID in
            guard videoID == songA.videoId else { return }
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        let addTask = SongActionsHelper.addToLibrary(songA, playerService: playerService)
        await metadataStarted.wait()
        await playerService.play(song: songB)
        await releaseMetadata.open()
        await addTask.value

        #expect(playerService.currentTrack?.videoId == songB.videoId)
        #expect(!playerService.currentTrackInLibrary)
        #expect(!self.mockClient.editSongLibraryStatusCalled)
    }

    @Test("Add to Library waits for tokens on an already-loading song")
    func addToLibraryWaitsForLoadingMetadata() async {
        let playerService = PlayerService()
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.completeLogin(sapisid: "REDACTED")
        playerService.setAuthService(authService)
        playerService.setYTMusicClient(self.mockClient)
        let song = TestFixtures.makeSong(id: "loading-library")
        self.mockClient.songResponses[song.videoId] = Song(
            id: song.id,
            title: song.title,
            artists: song.artists,
            videoId: song.videoId,
            feedbackTokens: FeedbackTokens(add: "mock-token", remove: "test-cookie")
        )
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        self.mockClient.beforeGetSongReturn = { videoID in
            guard videoID == song.videoId else { return }
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        let initialPlay = Task { @MainActor in
            await playerService.play(song: song)
        }
        await metadataStarted.wait()
        let addTask = SongActionsHelper.addToLibrary(song, playerService: playerService)
        await releaseMetadata.open()
        await initialPlay.value
        await addTask.value
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while !self.mockClient.editSongLibraryStatusCalled, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(self.mockClient.editSongLibraryStatusCalled)
    }

    @Test("Add to Library does not remove an already-saved song")
    func addToLibraryDoesNotToggleSavedSong() async {
        let playerService = PlayerService()
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.completeLogin(sapisid: "REDACTED")
        playerService.setAuthService(authService)
        playerService.setYTMusicClient(self.mockClient)
        let song = Song(
            id: "already-saved",
            title: "Already Saved",
            artists: [],
            videoId: "already-saved",
            isInLibrary: true,
            feedbackTokens: FeedbackTokens(add: nil, remove: "mock-token")
        )

        let task = SongActionsHelper.addToLibrary(song, playerService: playerService)
        await task.value
        try? await Task.sleep(for: .milliseconds(25))

        #expect(playerService.currentTrackInLibrary)
        #expect(!self.mockClient.editSongLibraryStatusCalled)
    }

    @Test("canQuickPlayPlaylist rejects mood category browse IDs")
    func canQuickPlayPlaylistRejectsMoodCategories() {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist")
        let moodCategory = TestFixtures.makePlaylist(id: "FEmusic_moods_and_genres_category_test")

        #expect(SongActionsHelper.canQuickPlayPlaylist(playlist))
        #expect(!SongActionsHelper.canQuickPlayPlaylist(moodCategory))
    }

    @Test("playPlaylist filters unavailable initial and continuation tracks before queueing")
    func playPlaylistFiltersUnavailableTracks() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        let unavailableFirst = Song(
            id: "unavailable-first",
            title: "Unavailable First",
            artists: [],
            videoId: "unavailable-first",
            isPlayable: false
        )
        let playable = Song(
            id: "playable",
            title: "Playable",
            artists: [],
            videoId: "playable"
        )
        let unavailableContinuation = Song(
            id: "unavailable-continuation",
            title: "Unavailable Continuation",
            artists: [],
            videoId: "unavailable-continuation",
            isPlayable: false
        )
        let playableContinuation = Song(
            id: "playable-continuation",
            title: "Playable Continuation",
            artists: [],
            videoId: "playable-continuation"
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [unavailableFirst, playable],
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlist.id] = [
            [unavailableContinuation, playableContinuation],
        ]
        self.mockClient.playlistAllTracks[playlist.id] = [
            Song(
                id: "unavailable-first",
                title: "Unavailable First",
                artists: [],
                videoId: "unavailable-first"
            ),
            playable,
            Song(
                id: "unavailable-continuation",
                title: "Unavailable Continuation",
                artists: [],
                videoId: "unavailable-continuation"
            ),
            playableContinuation,
        ]
        let playerService = PlayerService()

        SongActionsHelper.playPlaylist(
            playlist,
            client: self.mockClient,
            playerService: playerService
        )
        await self.awaitQueueCount(2, in: playerService)

        #expect(playerService.queue.map(\.videoId) == ["playable", "playable-continuation"])
        #expect(playerService.currentTrack?.videoId == "playable")
        #expect(playerService.queue.first?.thumbnailURL == playlist.thumbnailURL)
    }

    @Test("playPlaylist starts playback before loading continuations")
    func playPlaylistStartsBeforeContinuations() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        let initial = Song(
            id: "initial",
            title: "Initial",
            artists: [],
            videoId: "initial"
        )
        let continuation = Song(
            id: "continuation",
            title: "Continuation",
            artists: [],
            videoId: "continuation"
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [initial],
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlist.id] = [[continuation]]
        self.mockClient.playlistContinuationDelay = .milliseconds(250)
        let playerService = PlayerService()

        SongActionsHelper.playPlaylist(
            playlist,
            client: self.mockClient,
            playerService: playerService
        )
        await self.awaitQueueCount(1, in: playerService)

        #expect(playerService.currentTrack?.videoId == "initial")
        #expect(playerService.queue.map(\.videoId) == ["initial"])

        await self.awaitQueueCount(2, in: playerService)
        #expect(playerService.queue.map(\.videoId) == ["initial", "continuation"])
    }

    @Test("playPlaylist discards continuations after queue replacement")
    func playPlaylistDiscardsContinuationsAfterQueueReplacement() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        let initial = Song(
            id: "initial",
            title: "Initial",
            artists: [],
            videoId: "initial"
        )
        let continuation = Song(
            id: "continuation",
            title: "Continuation",
            artists: [],
            videoId: "continuation"
        )
        let replacement = Song(
            id: "replacement",
            title: "Replacement",
            artists: [],
            videoId: "replacement"
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [initial],
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlist.id] = [[continuation]]
        self.mockClient.playlistContinuationDelay = .milliseconds(250)
        let playerService = PlayerService()

        SongActionsHelper.playPlaylist(
            playlist,
            client: self.mockClient,
            playerService: playerService
        )
        await self.awaitQueueCount(1, in: playerService)

        await playerService.playQueue([replacement], startingAt: 0)
        await self.awaitPlaylistContinuationReturns()

        #expect(playerService.queue.map(\.videoId) == ["replacement"])
    }

    @Test("addPlaylistToLibrary keeps optimistic playlist when refresh response is stale")
    func addPlaylistToLibraryPreservesOptimisticPlaylist() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        await SongActionsHelper.addPlaylistToLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.mockClient.subscribeToPlaylistCalled == true)
        #expect(self.mockClient.getLibraryContentCalled == true)
        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id) == true)
        #expect(self.libraryViewModel.playlists.first?.id == playlist.id)
    }

    @Test("removePlaylistFromLibrary keeps optimistic removal when refresh response is stale")
    func removePlaylistFromLibraryPreservesOptimisticRemoval() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        self.mockClient.libraryPlaylists = [playlist]
        self.mockClient.shouldAutoUpdatePlaylistLibraryOnMutation = false

        await self.libraryViewModel.load()
        self.mockClient.reset()

        await SongActionsHelper.removePlaylistFromLibrary(
            playlist,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.mockClient.unsubscribeFromPlaylistCalled == true)
        #expect(self.mockClient.getLibraryContentCalled == true)
        #expect(self.libraryViewModel.isInLibrary(playlistId: playlist.id) == false)
        #expect(self.libraryViewModel.playlists.isEmpty)
    }

    @Test("subscribeToPodcast keeps optimistic show when refresh response is stale")
    func subscribeToPodcastPreservesOptimisticShow() async throws {
        let show = TestFixtures.makePodcastShow(id: "MPSPPL-test-podcast", title: "Test Podcast")
        self.mockClient.shouldAutoUpdatePodcastLibraryOnMutation = false

        try await SongActionsHelper.subscribeToPodcast(
            show,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.mockClient.getLibraryContentCalled == true)
        #expect(self.libraryViewModel.isInLibrary(podcastId: show.id) == true)
        #expect(self.libraryViewModel.podcastShows.first?.id == show.id)
    }

    @Test("unsubscribeFromPodcast keeps optimistic removal when refresh response is stale")
    func unsubscribeFromPodcastPreservesOptimisticRemoval() async throws {
        let show = TestFixtures.makePodcastShow(id: "MPSPPL-test-podcast", title: "Test Podcast")
        self.mockClient.libraryPodcastShows = [show]
        self.mockClient.shouldAutoUpdatePodcastLibraryOnMutation = false

        await self.libraryViewModel.load()
        self.mockClient.reset()

        try await SongActionsHelper.unsubscribeFromPodcast(
            show,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.mockClient.getLibraryContentCalled == true)
        #expect(self.libraryViewModel.isInLibrary(podcastId: show.id) == false)
        #expect(self.libraryViewModel.podcastShows.isEmpty)
    }

    @Test("unsubscribeFromArtist keeps optimistic removal when refresh response is stale")
    func unsubscribeFromArtistPreservesOptimisticRemoval() async throws {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-123", name: "Test Artist")
        self.mockClient.libraryArtists = [artist]
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false
        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(playlists: [], artists: [artist], podcastShows: []),
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
        ]

        await self.libraryViewModel.load()
        self.mockClient.reset()
        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(playlists: [], artists: [artist], podcastShows: []),
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
        ]

        try await SongActionsHelper.unsubscribeFromArtist(
            artist,
            channelId: "UC-channel-123",
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )
        await self.awaitArtistReconciliation(refreshes: 2)

        #expect(self.mockClient.unsubscribeFromArtistCalled == true)
        #expect(self.mockClient.getLibraryContentCallCount == 2)
        #expect(self.libraryViewModel.isInLibrary(artistId: "UC-channel-123") == false)
        #expect(self.libraryViewModel.artists.isEmpty)
    }

    @Test("unsubscribeFromArtist clears stale browse cache after stale refresh")
    func unsubscribeFromArtistClearsStaleBrowseCache() async throws {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-123", name: "Test Artist")
        self.mockClient.libraryArtists = [artist]
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false
        self.mockClient.onGetLibraryContent = {
            APICache.shared.set(key: "browse:stale-library", data: ["stale": true], ttl: 300)
        }

        await self.libraryViewModel.load()
        self.mockClient.reset()
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false
        self.mockClient.onGetLibraryContent = {
            APICache.shared.set(key: "browse:stale-library", data: ["stale": true], ttl: 300)
        }

        try await SongActionsHelper.unsubscribeFromArtist(
            artist,
            channelId: "UC-channel-123",
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )
        await self.awaitArtistReconciliation()

        #expect(APICache.shared.get(key: "browse:stale-library") == nil)
    }

    @Test("unsubscribeFromArtist clears URL cache before refreshing library")
    func unsubscribeFromArtistClearsURLCache() async throws {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-123", name: "Test Artist")
        self.mockClient.libraryArtists = [artist]

        let url = try #require(URL(string: "https://music.youtube.com/library-artists-test"))
        let request = URLRequest(url: url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Cache-Control": "max-age=300"]
            )
        )
        URLCache.shared.storeCachedResponse(
            CachedURLResponse(response: response, data: Data("cached-library".utf8)),
            for: request
        )
        #expect(URLCache.shared.cachedResponse(for: request) != nil)

        await self.libraryViewModel.load()
        self.mockClient.reset()

        try await SongActionsHelper.unsubscribeFromArtist(
            artist,
            channelId: "UC-channel-123",
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )
        await self.awaitArtistReconciliation()

        #expect(URLCache.shared.cachedResponse(for: request) == nil)
    }

    @Test("unsubscribeFromArtist discards an older in-flight library load")
    func unsubscribeFromArtistDiscardsInflightLibraryLoad() async throws {
        let staleArtist = TestFixtures.makeArtist(id: "MPLAUC-channel-123", name: "Test Artist")
        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(playlists: [], artists: [staleArtist], podcastShows: []),
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
        ]
        self.mockClient.libraryContentResponseDelays = [.milliseconds(700)]

        var initialLoadTask: Task<Void, Never>!
        await withCheckedContinuation { continuation in
            self.mockClient.onGetLibraryContent = {
                self.mockClient.onGetLibraryContent = nil
                continuation.resume()
            }
            initialLoadTask = Task {
                await self.libraryViewModel.load()
            }
        }

        try await SongActionsHelper.unsubscribeFromArtist(
            staleArtist,
            channelId: "UC-channel-123",
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        await initialLoadTask.value
        let didDiscardStaleLoad = await self.waitUntil {
            self.mockClient.getLibraryContentCallCount >= 2
                && !self.libraryViewModel.isInLibrary(artistId: "UC-channel-123")
                && self.libraryViewModel.artists.isEmpty
        }

        #expect(didDiscardStaleLoad)
        #expect(self.mockClient.getLibraryContentCallCount >= 2)
        #expect(self.libraryViewModel.isInLibrary(artistId: "UC-channel-123") == false)
        #expect(self.libraryViewModel.artists.isEmpty)
    }

    @Test("unsubscribeFromArtist removes artist from library immediately while request is in flight")
    func unsubscribeFromArtistRemovesArtistOptimistically() async throws {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-123", name: "Test Artist")
        self.mockClient.libraryArtists = [artist]
        self.mockClient.unsubscribeFromArtistDelay = .milliseconds(700)

        await self.libraryViewModel.load()
        self.mockClient.reset()
        self.mockClient.unsubscribeFromArtistDelay = .milliseconds(700)

        let unsubscribeTask = Task {
            try await SongActionsHelper.unsubscribeFromArtist(
                artist,
                channelId: "UC-channel-123",
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel
            )
        }

        try await Task.sleep(for: .milliseconds(100))

        #expect(self.libraryViewModel.isInLibrary(artistId: "UC-channel-123") == false)
        #expect(self.libraryViewModel.artists.isEmpty)

        try await unsubscribeTask.value
        await self.awaitArtistReconciliation()
    }

    @Test("unsubscribeFromArtist suppresses stale artist when library browse ID differs from channel ID")
    func unsubscribeFromArtistSuppressesArtistWithDifferentBrowseId() async throws {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-library-browse-123", name: "Test Artist")
        self.mockClient.libraryArtists = [artist]
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false

        await self.libraryViewModel.load()
        self.mockClient.reset()
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false

        try await SongActionsHelper.unsubscribeFromArtist(
            artist,
            channelId: "UC-channel-123",
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.libraryViewModel.artists.isEmpty)
    }

    @Test(
        "Real-world mismatched artist IDs remove the library artist on unsubscribe",
        arguments: realWorldArtistIdMismatchCases
    )
    func unsubscribeFromArtistHandlesRealWorldMismatchedIds(
        artistName: String,
        libraryBrowseId: String,
        subscriptionChannelId: String
    ) async throws {
        let artist = TestFixtures.makeArtist(id: libraryBrowseId, name: artistName)
        self.mockClient.libraryArtists = [artist]
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false

        await self.libraryViewModel.load()
        self.mockClient.reset()
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false

        try await SongActionsHelper.unsubscribeFromArtist(
            artist,
            channelId: subscriptionChannelId,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        #expect(self.libraryViewModel.artists.isEmpty)
        #expect(self.libraryViewModel.isInLibrary(artistId: libraryBrowseId) == false)
        #expect(self.libraryViewModel.isInLibrary(artistId: subscriptionChannelId) == false)
    }

    @Test("subscribeToArtist adds artist to library immediately while request is in flight")
    func subscribeToArtistAddsArtistOptimistically() async throws {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-123", name: "Test Artist")
        self.mockClient.subscribeToArtistDelay = .milliseconds(700)

        let subscribeTask = Task {
            try await SongActionsHelper.subscribeToArtist(
                artist,
                channelId: "UC-channel-123",
                client: self.mockClient,
                libraryViewModel: self.libraryViewModel
            )
        }

        try await Task.sleep(for: .milliseconds(100))

        #expect(self.libraryViewModel.isInLibrary(artistId: "UC-channel-123") == true)
        #expect(self.libraryViewModel.artists.first?.id == "UC-channel-123")

        try await subscribeTask.value
        await self.awaitArtistReconciliation()
    }

    @Test("subscribeToArtist does not duplicate artist when library browse ID differs from subscription channel ID")
    func subscribeToArtistDoesNotDuplicateArtistWithDifferentBrowseId() async throws {
        let artist = TestFixtures.makeArtist(id: "UC-library-browse-123", name: "Test Artist")
        let libraryContent = PlaylistParser.LibraryContent(
            playlists: [],
            artists: [artist],
            podcastShows: []
        )
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false
        self.mockClient.libraryContentResponses = [libraryContent, libraryContent]

        try await SongActionsHelper.subscribeToArtist(
            artist,
            channelId: "UC-subscribe-channel-456",
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )
        await self.awaitArtistReconciliation(refreshes: 2)

        #expect(self.libraryViewModel.artists.count == 1)
        #expect(self.libraryViewModel.artists.first?.id == "UC-library-browse-123")
    }

    @Test(
        "Real-world mismatched artist IDs do not duplicate on subscribe",
        arguments: realWorldArtistIdMismatchCases
    )
    func subscribeToArtistDoesNotDuplicateRealWorldMismatchedIds(
        artistName: String,
        libraryBrowseId: String,
        subscriptionChannelId: String
    ) async throws {
        let artist = TestFixtures.makeArtist(id: libraryBrowseId, name: artistName)
        let libraryContent = PlaylistParser.LibraryContent(
            playlists: [],
            artists: [artist],
            podcastShows: []
        )
        self.mockClient.shouldAutoUpdateArtistLibraryOnMutation = false
        self.mockClient.libraryContentResponses = [libraryContent, libraryContent]

        try await SongActionsHelper.subscribeToArtist(
            artist,
            channelId: subscriptionChannelId,
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )
        await self.awaitArtistReconciliation(refreshes: 2)

        #expect(self.libraryViewModel.artists.count == 1)
        #expect(self.libraryViewModel.artists.first?.id == libraryBrowseId)
        #expect(self.libraryViewModel.isInLibrary(artistId: libraryBrowseId) == true)
        #expect(self.libraryViewModel.isInLibrary(artistId: subscriptionChannelId) == true)
    }
}
