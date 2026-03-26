import Foundation
import Testing
@testable import Kaset

/// Tests for LibraryViewModel using mock client.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct LibraryViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: LibraryViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = LibraryViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle with empty library content")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.playlists.isEmpty)
        #expect(self.viewModel.artists.isEmpty)
        #expect(self.viewModel.podcastShows.isEmpty)
        #expect(self.viewModel.libraryPlaylistIds.isEmpty)
        #expect(self.viewModel.libraryArtistIds.isEmpty)
        #expect(self.viewModel.libraryPodcastIds.isEmpty)
        #expect(self.viewModel.selectedPlaylistDetail == nil)
    }

    @Test("Load success sets library content and ID sets")
    func loadSuccess() async {
        self.mockClient.libraryPlaylists = [
            TestFixtures.makePlaylist(id: "VL1", title: "Playlist 1"),
            TestFixtures.makePlaylist(id: "VL2", title: "Playlist 2"),
        ]
        self.mockClient.libraryArtists = [
            TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1"),
        ]
        self.mockClient.libraryPodcastShows = [
            TestFixtures.makePodcastShow(id: "MPSPPL1", title: "Podcast 1"),
        ]

        await self.viewModel.load()

        #expect(self.mockClient.getLibraryContentCalled == true)
        #expect(self.mockClient.getLibraryPlaylistsCalled == false)
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.playlists.count == 2)
        #expect(self.viewModel.playlists[0].title == "Playlist 1")
        #expect(self.viewModel.artists.count == 1)
        #expect(self.viewModel.artists[0].name == "Artist 1")
        #expect(self.viewModel.podcastShows.count == 1)
        #expect(self.viewModel.podcastShows[0].title == "Podcast 1")
        #expect(self.viewModel.libraryPlaylistIds == Set(["VL1", "VL2"]))
        #expect(self.viewModel.libraryArtistIds == Set(["UC-channel-1"]))
        #expect(self.viewModel.libraryPodcastIds == Set(["MPSPPL1"]))
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.authExpired

        await self.viewModel.load()

        #expect(self.mockClient.getLibraryContentCalled == true)
        #expect(self.mockClient.getLibraryPlaylistsCalled == false)
        if case .error = self.viewModel.loadingState {
            // Expected
        } else {
            Issue.record("Expected error state")
        }
        #expect(self.viewModel.playlists.isEmpty)
        #expect(self.viewModel.artists.isEmpty)
        #expect(self.viewModel.podcastShows.isEmpty)
        #expect(self.viewModel.libraryPlaylistIds.isEmpty)
        #expect(self.viewModel.libraryArtistIds.isEmpty)
        #expect(self.viewModel.libraryPodcastIds.isEmpty)
    }

    @Test("Load playlist success")
    func loadPlaylistSuccess() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test")
        let playlistDetail = TestFixtures.makePlaylistDetail(playlist: playlist, trackCount: 5)
        self.mockClient.playlistDetails["VL-test"] = playlistDetail

        await self.viewModel.loadPlaylist(id: "VL-test")

        #expect(self.mockClient.getPlaylistCalled == true)
        #expect(self.mockClient.getPlaylistIds.first == "VL-test")
        #expect(self.viewModel.playlistDetailLoadingState == .loaded)
        #expect(self.viewModel.selectedPlaylistDetail != nil)
        #expect(self.viewModel.selectedPlaylistDetail?.tracks.count == 5)
    }

    @Test("Clear selected playlist")
    func clearSelectedPlaylist() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test")
        self.mockClient.playlistDetails["VL-test"] = TestFixtures.makePlaylistDetail(playlist: playlist)
        await self.viewModel.loadPlaylist(id: "VL-test")
        #expect(self.viewModel.selectedPlaylistDetail != nil)

        self.viewModel.clearSelectedPlaylist()

        #expect(self.viewModel.selectedPlaylistDetail == nil)
        #expect(self.viewModel.playlistDetailLoadingState == .idle)
    }

    @Test("Refresh clears and reloads")
    func refreshClearsAndReloads() async {
        self.mockClient.libraryPlaylists = [TestFixtures.makePlaylist(id: "VL1")]
        self.mockClient.libraryArtists = [TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1")]
        self.mockClient.libraryPodcastShows = [TestFixtures.makePodcastShow(id: "MPSPPL1")]
        await self.viewModel.load()
        #expect(self.viewModel.playlists.count == 1)
        #expect(self.viewModel.artists.count == 1)
        #expect(self.viewModel.podcastShows.count == 1)
        #expect(self.viewModel.libraryPlaylistIds == Set(["VL1"]))
        #expect(self.viewModel.libraryArtistIds == Set(["UC-channel-1"]))
        #expect(self.viewModel.libraryPodcastIds == Set(["MPSPPL1"]))

        self.mockClient.libraryPlaylists = [
            TestFixtures.makePlaylist(id: "VL2"),
            TestFixtures.makePlaylist(id: "VL3"),
        ]
        self.mockClient.libraryArtists = [
            TestFixtures.makeArtist(id: "MPLAUC-channel-2", name: "Artist 2"),
            TestFixtures.makeArtist(id: "MPLAUC-channel-3", name: "Artist 3"),
        ]
        self.mockClient.libraryPodcastShows = [
            TestFixtures.makePodcastShow(id: "MPSPPL2"),
            TestFixtures.makePodcastShow(id: "MPSPPL3"),
        ]
        await self.viewModel.refresh()

        #expect(self.viewModel.playlists.count == 2)
        #expect(self.viewModel.artists.count == 2)
        #expect(self.viewModel.podcastShows.count == 2)
        #expect(self.viewModel.libraryPlaylistIds == Set(["VL2", "VL3"]))
        #expect(self.viewModel.libraryArtistIds == Set(["UC-channel-2", "UC-channel-3"]))
        #expect(self.viewModel.libraryPodcastIds == Set(["MPSPPL2", "MPSPPL3"]))
    }

    @Test("Refresh keeps existing library content visible while background load runs")
    func refreshKeepsExistingContentVisibleWhileLoading() async throws {
        self.mockClient.libraryPlaylists = [TestFixtures.makePlaylist(id: "VL1", title: "Playlist 1")]
        await self.viewModel.load()

        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(
                playlists: [TestFixtures.makePlaylist(id: "VL2", title: "Playlist 2")],
                artists: [],
                podcastShows: []
            ),
        ]
        self.mockClient.libraryContentResponseDelays = [.milliseconds(200)]

        let refreshTask = Task {
            await self.viewModel.refresh()
        }

        try await Task.sleep(for: .milliseconds(50))

        #expect(self.viewModel.loadingState == .loadingMore)
        #expect(self.viewModel.playlists.map(\.id) == ["VL1"])

        await refreshTask.value

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.playlists.map(\.id) == ["VL2"])
    }

    @Test("Refresh failure keeps existing library content visible")
    func refreshFailureKeepsExistingContentVisible() async {
        self.mockClient.libraryPlaylists = [TestFixtures.makePlaylist(id: "VL1", title: "Playlist 1")]
        await self.viewModel.load()

        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.refresh()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.playlists.map(\.id) == ["VL1"])
    }

    // MARK: - Artist Library Tests

    @Test("isInLibrary normalizes MPLAUC artist IDs to channel IDs")
    func isInLibraryNormalizesArtistIds() async {
        self.mockClient.libraryArtists = [TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1")]

        await self.viewModel.load()

        #expect(self.viewModel.isInLibrary(artistId: "UC-channel-1") == true)
        #expect(self.viewModel.isInLibrary(artistId: "MPLAUC-channel-1") == true)
    }

    @Test("addToLibrary inserts artist at beginning and stores normalized ID")
    func addToLibraryInsertsArtist() {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1")

        self.viewModel.addToLibrary(artist: artist)

        #expect(self.viewModel.libraryArtistIds == Set(["UC-channel-1"]))
        #expect(self.viewModel.artists.first?.id == "UC-channel-1")
        #expect(self.viewModel.artists.first?.name == "Artist 1")
    }

    @Test("addToLibrary does not duplicate equivalent artist IDs")
    func addToLibraryDoesNotDuplicateEquivalentArtistIds() {
        self.viewModel.addToLibrary(artist: TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1"))
        self.viewModel.addToLibrary(artist: TestFixtures.makeArtist(id: "UC-channel-1", name: "Artist 1"))

        #expect(self.viewModel.libraryArtistIds == Set(["UC-channel-1"]))
        #expect(self.viewModel.artists.count == 1)
    }

    @Test("removeFromLibrary removes normalized artist ID from set and array")
    func removeFromLibraryRemovesArtist() {
        self.viewModel.addToLibrary(artist: TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1"))
        #expect(self.viewModel.isInLibrary(artistId: "UC-channel-1") == true)

        self.viewModel.removeFromLibrary(artistId: "UC-channel-1")

        #expect(self.viewModel.libraryArtistIds.isEmpty)
        #expect(self.viewModel.artists.isEmpty)
    }

    @Test("refresh keeps locally removed artist suppressed until backend catches up")
    func refreshKeepsRemovedArtistSuppressed() async {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1")
        self.mockClient.libraryArtists = [artist]

        await self.viewModel.load()
        self.viewModel.removeFromLibrary(artistId: "UC-channel-1")

        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(playlists: [], artists: [artist], podcastShows: []),
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
        ]

        await self.viewModel.refresh()
        #expect(self.viewModel.isInLibrary(artistId: "UC-channel-1") == false)
        #expect(self.viewModel.artists.isEmpty)

        await self.viewModel.refresh()
        #expect(self.viewModel.isInLibrary(artistId: "UC-channel-1") == false)
        #expect(self.viewModel.artists.isEmpty)
    }

    @Test("refresh keeps locally removed artist suppressed through oscillating backend responses")
    func refreshKeepsRemovedArtistSuppressedThroughOscillation() async {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1")
        self.mockClient.libraryArtists = [artist]

        await self.viewModel.load()
        self.viewModel.removeFromLibrary(artistId: "UC-channel-1")

        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
            PlaylistParser.LibraryContent(playlists: [], artists: [artist], podcastShows: []),
        ]

        await self.viewModel.refresh()
        #expect(self.viewModel.isInLibrary(artistId: "UC-channel-1") == false)
        #expect(self.viewModel.artists.isEmpty)

        await self.viewModel.refresh()
        #expect(self.viewModel.isInLibrary(artistId: "UC-channel-1") == false)
        #expect(self.viewModel.artists.isEmpty)
    }

    @Test("refresh keeps locally added artist visible until backend catches up")
    func refreshKeepsAddedArtistVisible() async {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1")

        self.viewModel.addToLibrary(artist: artist)
        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
            PlaylistParser.LibraryContent(
                playlists: [],
                artists: [TestFixtures.makeArtist(id: "UC-channel-1", name: "Artist 1")],
                podcastShows: []
            ),
        ]

        await self.viewModel.refresh()
        #expect(self.viewModel.isInLibrary(artistId: "UC-channel-1") == true)
        #expect(self.viewModel.artists.first?.id == "UC-channel-1")
        #expect(self.viewModel.artists.first?.name == "Artist 1")

        await self.viewModel.refresh()
        #expect(self.viewModel.isInLibrary(artistId: "UC-channel-1") == true)
        #expect(self.viewModel.artists.first?.id == "UC-channel-1")
    }

    @Test("refresh keeps locally added artist visible through oscillating backend responses")
    func refreshKeepsAddedArtistVisibleThroughOscillation() async {
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1")

        self.viewModel.addToLibrary(artist: artist)
        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(
                playlists: [],
                artists: [TestFixtures.makeArtist(id: "UC-channel-1", name: "Artist 1")],
                podcastShows: []
            ),
            PlaylistParser.LibraryContent(playlists: [], artists: [], podcastShows: []),
        ]

        await self.viewModel.refresh()
        #expect(self.viewModel.isInLibrary(artistId: "UC-channel-1") == true)
        #expect(self.viewModel.artists.first?.id == "UC-channel-1")

        await self.viewModel.refresh()
        #expect(self.viewModel.isInLibrary(artistId: "UC-channel-1") == true)
        #expect(self.viewModel.artists.first?.id == "UC-channel-1")
    }

    @Test("refresh preserves existing artists when refresh falls back to landing preview")
    func refreshPreservesArtistsDuringLandingFallback() async {
        let authoritativeArtist = TestFixtures.makeArtist(id: "UC-channel-1", name: "Artist 1")
        let fallbackPreviewArtist = TestFixtures.makeArtist(id: "UC-channel-2", name: "Artist 2")

        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(
                playlists: [],
                artists: [authoritativeArtist],
                podcastShows: []
            ),
        ]
        await self.viewModel.load()

        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(
                playlists: [],
                artists: [fallbackPreviewArtist],
                podcastShows: [],
                artistsSource: .landingFallback
            ),
        ]

        await self.viewModel.refresh()

        #expect(self.viewModel.libraryArtistIds == Set(["UC-channel-1"]))
        #expect(self.viewModel.artists.count == 1)
        #expect(self.viewModel.artists.first?.id == "UC-channel-1")
    }

    @Test("load deduplicates equivalent library artist IDs")
    func loadDeduplicatesEquivalentArtistIds() async {
        self.mockClient.libraryContentResponses = [
            PlaylistParser.LibraryContent(
                playlists: [],
                artists: [
                    TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1"),
                    TestFixtures.makeArtist(id: "UC-channel-1", name: "Artist 1"),
                ],
                podcastShows: []
            ),
        ]

        await self.viewModel.load()

        #expect(self.viewModel.libraryArtistIds == Set(["UC-channel-1"]))
        #expect(self.viewModel.artists.count == 1)
        #expect(self.viewModel.artists.first?.id == "UC-channel-1")
    }

    // MARK: - Playlist Library Tests

    @Test("addToLibrary inserts playlist at beginning and updates ID set")
    func addToLibraryInsertsPlaylist() {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Playlist 1")

        self.viewModel.addToLibrary(playlist: playlist)

        #expect(self.viewModel.libraryPlaylistIds == Set(["VL-test-playlist"]))
        #expect(self.viewModel.playlists.first?.id == "VL-test-playlist")
        #expect(self.viewModel.playlists.first?.title == "Playlist 1")
    }

    @Test("removeFromLibrary removes playlist from both set and array")
    func removeFromLibraryRemovesPlaylist() {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Playlist 1")
        self.viewModel.addToLibrary(playlist: playlist)
        #expect(self.viewModel.isInLibrary(playlistId: "VL-test-playlist") == true)

        self.viewModel.removeFromLibrary(playlistId: "VL-test-playlist")

        #expect(self.viewModel.libraryPlaylistIds.isEmpty)
        #expect(self.viewModel.playlists.isEmpty)
    }

    // MARK: - Podcast Library Tests

    @Test("addToLibrary inserts podcast at beginning and updates ID set")
    func addToLibraryInsertsPodcast() {
        let podcast = TestFixtures.makePodcastShow(id: "MPSPPLXz2p9test123", title: "Test Podcast")

        self.viewModel.addToLibrary(podcast: podcast)

        #expect(self.viewModel.libraryPodcastIds.contains("MPSPPLXz2p9test123"))
        #expect(self.viewModel.podcastShows.first?.id == "MPSPPLXz2p9test123")
        #expect(self.viewModel.podcastShows.first?.title == "Test Podcast")
    }

    @Test("addToLibrary does not duplicate existing podcast")
    func addToLibraryNoDuplicate() {
        let podcast = TestFixtures.makePodcastShow(id: "MPSPPLXz2p9test123")

        self.viewModel.addToLibrary(podcast: podcast)
        self.viewModel.addToLibrary(podcast: podcast)

        #expect(self.viewModel.podcastShows.count(where: { $0.id == "MPSPPLXz2p9test123" }) == 1)
        #expect(self.viewModel.libraryPodcastIds.count == 1)
    }

    @Test("addToLibrary inserts new podcast at position 0")
    func addToLibraryInsertsAtBeginning() {
        let podcast1 = TestFixtures.makePodcastShow(id: "MPSPPLA", title: "Podcast A")
        let podcast2 = TestFixtures.makePodcastShow(id: "MPSPPLB", title: "Podcast B")

        self.viewModel.addToLibrary(podcast: podcast1)
        self.viewModel.addToLibrary(podcast: podcast2)

        // Podcast B should be first (inserted at position 0)
        #expect(self.viewModel.podcastShows.first?.id == "MPSPPLB")
        #expect(self.viewModel.podcastShows[1].id == "MPSPPLA")
    }

    @Test("removeFromLibrary removes podcast from both set and array")
    func removeFromLibraryRemovesPodcast() {
        let podcast = TestFixtures.makePodcastShow(id: "MPSPPLXz2p9test123")
        self.viewModel.addToLibrary(podcast: podcast)
        #expect(self.viewModel.podcastShows.count == 1)
        #expect(self.viewModel.libraryPodcastIds.count == 1)

        self.viewModel.removeFromLibrary(podcastId: "MPSPPLXz2p9test123")

        #expect(self.viewModel.podcastShows.isEmpty)
        #expect(self.viewModel.libraryPodcastIds.isEmpty)
    }

    @Test("removeFromLibrary handles non-existent podcast gracefully")
    func removeFromLibraryNonExistent() {
        // Should not crash when removing non-existent podcast
        self.viewModel.removeFromLibrary(podcastId: "nonexistent")

        #expect(self.viewModel.podcastShows.isEmpty)
        #expect(self.viewModel.libraryPodcastIds.isEmpty)
    }

    @Test("isInLibrary returns true for added podcast")
    func isInLibraryForAddedPodcast() {
        let podcast = TestFixtures.makePodcastShow(id: "MPSPPLXz2p9test123")
        self.viewModel.addToLibrary(podcast: podcast)

        #expect(self.viewModel.isInLibrary(podcastId: "MPSPPLXz2p9test123") == true)
    }

    @Test("isInLibrary returns false for non-added podcast")
    func isInLibraryForNonAddedPodcast() {
        #expect(self.viewModel.isInLibrary(podcastId: "MPSPPLXz2p9test123") == false)
    }
}
