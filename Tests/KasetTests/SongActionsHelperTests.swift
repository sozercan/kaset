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

    private func awaitArtistReconciliation() async {
        try? await Task.sleep(for: .milliseconds(50))
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
        await self.awaitArtistReconciliation()

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

        let initialLoadTask = Task {
            await self.libraryViewModel.load()
        }

        try await Task.sleep(for: .milliseconds(100))

        try await SongActionsHelper.unsubscribeFromArtist(
            staleArtist,
            channelId: "UC-channel-123",
            client: self.mockClient,
            libraryViewModel: self.libraryViewModel
        )

        await initialLoadTask.value
        try await Task.sleep(for: .milliseconds(100))

        #expect(self.mockClient.getLibraryContentCallCount == 2)
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
        await self.awaitArtistReconciliation()

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
        await self.awaitArtistReconciliation()

        #expect(self.libraryViewModel.artists.count == 1)
        #expect(self.libraryViewModel.artists.first?.id == libraryBrowseId)
        #expect(self.libraryViewModel.isInLibrary(artistId: libraryBrowseId) == true)
        #expect(self.libraryViewModel.isInLibrary(artistId: subscriptionChannelId) == true)
    }
}
