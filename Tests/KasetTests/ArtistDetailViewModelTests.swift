import Foundation
import Testing
@testable import Kaset

/// Tests for ArtistDetailViewModel using mock client.
@Suite("ArtistDetailViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct ArtistDetailViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: ArtistDetailViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        let artist = TestFixtures.makeArtist(id: "UC-test-artist", name: "Test Artist")
        self.viewModel = ArtistDetailViewModel(artist: artist, client: self.mockClient)
    }

    // MARK: - Initial State Tests

    @Test("Initial state is idle with no artist detail")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.artistDetail == nil)
        #expect(self.viewModel.showAllSongs == false)
    }

    // MARK: - Load Tests

    @Test("Load success sets artist detail")
    func loadSuccess() async {
        let artistDetail = TestFixtures.makeArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            songCount: 10,
            albumCount: 3
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()

        #expect(self.mockClient.getArtistCalled == true)
        #expect(self.mockClient.getArtistIds.first == "UC-test-artist")
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.artistDetail != nil)
        #expect(self.viewModel.artistDetail?.songs.count == 10)
        #expect(self.viewModel.artistDetail?.albums.count == 3)
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

        #expect(self.mockClient.getArtistCalled == true)
        if case let .error(error) = viewModel.loadingState {
            #expect(!error.message.isEmpty)
            #expect(error.isRetryable)
        } else {
            Issue.record("Expected error state")
        }
        #expect(self.viewModel.artistDetail == nil)
    }

    @Test("Load does not duplicate when already loading")
    func loadDoesNotDuplicateWhenAlreadyLoading() async {
        let artistDetail = TestFixtures.makeArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            songCount: 5
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()
        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("Load uses original artist info for unknown name")
    func loadUsesOriginalArtistInfoForUnknownName() async {
        // Create an artist detail with "Unknown Artist" name
        let unknownArtist = Artist(
            id: "UC-test-artist",
            name: "Unknown Artist",
            thumbnailURL: nil
        )
        let artistDetail = ArtistDetail(
            artist: unknownArtist,
            description: nil,
            songs: TestFixtures.makeSongs(count: 3),
            albums: [],
            thumbnailURL: nil
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()

        // Should use original artist name "Test Artist" instead of "Unknown Artist"
        #expect(self.viewModel.artistDetail?.name == "Test Artist")
    }

    // MARK: - Refresh Tests

    @Test("Refresh clears detail and reloads")
    func refreshClearsDetailAndReloads() async {
        let artistDetail = TestFixtures.makeArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            songCount: 5
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()
        #expect(self.viewModel.artistDetail?.songs.count == 5)

        // Update mock to return different song count
        let newArtistDetail = TestFixtures.makeArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            songCount: 8
        )
        self.mockClient.artistDetails["UC-test-artist"] = newArtistDetail

        await self.viewModel.refresh()

        #expect(self.viewModel.artistDetail?.songs.count == 8)
        #expect(self.viewModel.showAllSongs == false)
    }

    // MARK: - Displayed Songs Tests

    @Test("displayedSongs returns preview count by default")
    func displayedSongsReturnsPreviewCount() async {
        let artistDetail = TestFixtures.makeArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            songCount: 10
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()

        #expect(self.viewModel.displayedSongs.count == ArtistDetailViewModel.previewSongCount)
    }

    @Test("displayedSongs returns all songs when showAllSongs is true")
    func displayedSongsReturnsAllWhenShowAllSongs() async {
        let artistDetail = TestFixtures.makeArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            songCount: 10
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()
        self.viewModel.showAllSongs = true

        #expect(self.viewModel.displayedSongs.count == 10)
    }

    @Test("displayedSongs returns empty when no detail")
    func displayedSongsReturnsEmptyWhenNoDetail() {
        #expect(self.viewModel.displayedSongs.isEmpty)
    }

    // MARK: - Has More Songs Tests

    @Test("hasMoreSongs returns false when no detail")
    func hasMoreSongsReturnsFalseWhenNoDetail() {
        #expect(self.viewModel.hasMoreSongs == false)
    }

    @Test("hasMoreSongs returns true when songs exceed preview count")
    func hasMoreSongsReturnsTrueWhenExceedsPreview() async {
        let artistDetail = TestFixtures.makeArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            songCount: 10 // More than previewSongCount
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()

        #expect(self.viewModel.hasMoreSongs == true)
    }

    @Test("hasMoreSongs returns false when songs within preview count")
    func hasMoreSongsReturnsFalseWhenWithinPreview() async {
        let artistDetail = TestFixtures.makeArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            songCount: 3 // Less than previewSongCount
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()

        #expect(self.viewModel.hasMoreSongs == false)
    }

    // MARK: - Subscription Tests

    @Test("toggleSubscription does nothing without channel ID")
    func toggleSubscriptionNoChannelId() async {
        let artistDetail = ArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            description: nil,
            songs: [],
            albums: [],
            thumbnailURL: nil,
            channelId: nil // No channel ID
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()
        await self.viewModel.toggleSubscription()

        #expect(self.mockClient.subscribeToArtistCalled == false)
        #expect(self.mockClient.unsubscribeFromArtistCalled == false)
    }

    @Test("toggleSubscription subscribes when not subscribed")
    func toggleSubscriptionSubscribes() async {
        let artistDetail = ArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            description: nil,
            songs: [],
            albums: [],
            thumbnailURL: nil,
            channelId: "UC-channel-123",
            isSubscribed: false
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()
        await self.viewModel.toggleSubscription()

        #expect(self.mockClient.subscribeToArtistCalled == true)
        #expect(self.mockClient.subscribeToArtistIds.first == "UC-channel-123")
        #expect(self.viewModel.artistDetail?.isSubscribed == true)
    }

    @Test("toggleSubscription unsubscribes when subscribed")
    func toggleSubscriptionUnsubscribes() async {
        let artistDetail = ArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            description: nil,
            songs: [],
            albums: [],
            thumbnailURL: nil,
            channelId: "UC-channel-123",
            isSubscribed: true
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()
        await self.viewModel.toggleSubscription()

        #expect(self.mockClient.unsubscribeFromArtistCalled == true)
        #expect(self.mockClient.unsubscribeFromArtistIds.first == "UC-channel-123")
        #expect(self.viewModel.artistDetail?.isSubscribed == false)
    }

    @Test("toggleSubscription sets error on failure")
    func toggleSubscriptionSetsErrorOnFailure() async {
        let artistDetail = ArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            description: nil,
            songs: [],
            albums: [],
            thumbnailURL: nil,
            channelId: "UC-channel-123",
            isSubscribed: false
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.toggleSubscription()

        #expect(self.viewModel.subscriptionError != nil)
        #expect(self.viewModel.artistDetail?.isSubscribed == false) // Unchanged
    }

    // MARK: - Get All Songs Tests

    @Test("getAllSongs returns artist detail songs when no browse ID")
    func getAllSongsReturnsDetailSongs() async {
        let artistDetail = TestFixtures.makeArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            songCount: 5
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail

        await self.viewModel.load()
        let songs = await self.viewModel.getAllSongs()

        #expect(songs.count == 5)
        #expect(self.mockClient.getArtistSongsCalled == false)
    }

    @Test("getAllSongs fetches from API when browse ID available")
    func getAllSongsFetchesFromAPI() async {
        let artistDetail = ArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            description: nil,
            songs: TestFixtures.makeSongs(count: 5),
            albums: [],
            thumbnailURL: nil,
            hasMoreSongs: true,
            songsBrowseId: "artist-songs-browse-id"
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail
        self.mockClient.artistSongs["artist-songs-browse-id"] = TestFixtures.makeSongs(count: 20)

        await self.viewModel.load()
        let songs = await self.viewModel.getAllSongs()

        #expect(songs.count == 20)
        #expect(self.mockClient.getArtistSongsCalled == true)
        #expect(self.mockClient.getArtistSongsBrowseIds.first == "artist-songs-browse-id")
    }

    @Test("getAllSongs returns cached songs on subsequent calls")
    func getAllSongsReturnsCached() async {
        let artistDetail = ArtistDetail(
            artist: TestFixtures.makeArtist(id: "UC-test-artist"),
            description: nil,
            songs: TestFixtures.makeSongs(count: 5),
            albums: [],
            thumbnailURL: nil,
            hasMoreSongs: true,
            songsBrowseId: "artist-songs-browse-id"
        )
        self.mockClient.artistDetails["UC-test-artist"] = artistDetail
        self.mockClient.artistSongs["artist-songs-browse-id"] = TestFixtures.makeSongs(count: 20)

        await self.viewModel.load()
        _ = await self.viewModel.getAllSongs()
        _ = await self.viewModel.getAllSongs()

        // Should only call API once
        #expect(self.mockClient.getArtistSongsBrowseIds.count == 1)
    }
}
