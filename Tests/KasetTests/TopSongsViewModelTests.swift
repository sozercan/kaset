import Foundation
import Testing

@testable import Kaset

@Suite("TopSongsViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct TopSongsViewModelTests {
    // MARK: - Initial State Tests

    @Test("Initial state includes songs from destination")
    func initialStateIncludesSongsFromDestination() {
        let mockClient = MockYTMusicClient()
        let songs = [
            TestFixtures.makeSong(videoId: "song-1", title: "Song 1"),
            TestFixtures.makeSong(videoId: "song-2", title: "Song 2"),
        ]
        let destination = TopSongsDestination(
            artistName: "Test Artist",
            songs: songs,
            songsBrowseId: nil,
            songsParams: nil
        )

        let viewModel = TopSongsViewModel(destination: destination, client: mockClient)

        #expect(viewModel.loadingState == .idle)
        #expect(viewModel.songs.count == 2)
        #expect(viewModel.songs[0].title == "Song 1")
        #expect(viewModel.songs[1].title == "Song 2")
    }

    // MARK: - Load Without Browse ID Tests

    @Test("Load without browse ID immediately sets loaded state")
    func loadWithoutBrowseIdSetsLoadedImmediately() async {
        let mockClient = MockYTMusicClient()
        let songs = [TestFixtures.makeSong(videoId: "song-1", title: "Initial")]
        let destination = TopSongsDestination(
            artistName: "Test Artist",
            songs: songs,
            songsBrowseId: nil,
            songsParams: nil
        )
        let viewModel = TopSongsViewModel(destination: destination, client: mockClient)

        await viewModel.load()

        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.songs.count == 1)
        #expect(mockClient.getArtistSongsCalled == false)
    }

    // MARK: - Load With Browse ID Tests

    @Test("Load with browse ID fetches all songs")
    func loadWithBrowseIdFetchesAllSongs() async {
        let mockClient = MockYTMusicClient()
        let initialSongs = [TestFixtures.makeSong(videoId: "song-1", title: "Initial")]
        let destination = TopSongsDestination(
            artistName: "Test Artist",
            songs: initialSongs,
            songsBrowseId: "browse-id-123",
            songsParams: "params-abc"
        )
        let viewModel = TopSongsViewModel(destination: destination, client: mockClient)

        mockClient.artistSongsResponse = [
            TestFixtures.makeSong(videoId: "song-1", title: "Song 1"),
            TestFixtures.makeSong(videoId: "song-2", title: "Song 2"),
            TestFixtures.makeSong(videoId: "song-3", title: "Song 3"),
        ]

        await viewModel.load()

        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.songs.count == 3)
        #expect(mockClient.getArtistSongsCalled)
        #expect(mockClient.getArtistSongsBrowseIds.contains("browse-id-123"))
    }

    @Test("Load with browse ID keeps initial songs on error")
    func loadWithBrowseIdKeepsInitialSongsOnError() async {
        let mockClient = MockYTMusicClient()
        let initialSongs = [
            TestFixtures.makeSong(videoId: "song-1", title: "Initial 1"),
            TestFixtures.makeSong(videoId: "song-2", title: "Initial 2"),
        ]
        let destination = TopSongsDestination(
            artistName: "Test Artist",
            songs: initialSongs,
            songsBrowseId: "browse-id-123",
            songsParams: nil
        )
        let viewModel = TopSongsViewModel(destination: destination, client: mockClient)

        mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )

        await viewModel.load()

        // Should still be loaded with initial songs preserved
        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.songs.count == 2)
        #expect(viewModel.songs[0].title == "Initial 1")
    }

    @Test("Load with browse ID keeps initial songs when API returns empty")
    func loadWithBrowseIdKeepsInitialSongsWhenEmpty() async {
        let mockClient = MockYTMusicClient()
        let initialSongs = [TestFixtures.makeSong(videoId: "song-1", title: "Initial")]
        let destination = TopSongsDestination(
            artistName: "Test Artist",
            songs: initialSongs,
            songsBrowseId: "browse-id-123",
            songsParams: nil
        )
        let viewModel = TopSongsViewModel(destination: destination, client: mockClient)

        mockClient.artistSongsResponse = []

        await viewModel.load()

        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.songs.count == 1)
        #expect(viewModel.songs[0].title == "Initial")
    }

    @Test("Load does not run concurrently when already loading")
    func loadPreventsConncurrentCalls() async {
        let mockClient = MockYTMusicClient()
        let destination = TopSongsDestination(
            artistName: "Test Artist",
            songs: [],
            songsBrowseId: "browse-id-123",
            songsParams: nil
        )
        let viewModel = TopSongsViewModel(destination: destination, client: mockClient)

        mockClient.artistSongsResponse = [TestFixtures.makeSong(videoId: "song-1", title: "Song 1")]
        mockClient.apiDelay = 0.1

        // Start first load
        let task1 = Task {
            await viewModel.load()
        }

        // Try to start another load immediately
        try? await Task.sleep(for: .milliseconds(20))
        let task2 = Task {
            await viewModel.load()
        }

        await task1.value
        await task2.value

        #expect(viewModel.loadingState == .loaded)
    }

    // MARK: - Client Exposure Tests

    @Test("Client is exposed for playback")
    func clientIsExposed() {
        let mockClient = MockYTMusicClient()
        let destination = TopSongsDestination(
            artistName: "Test Artist",
            songs: [],
            songsBrowseId: nil,
            songsParams: nil
        )
        let viewModel = TopSongsViewModel(destination: destination, client: mockClient)

        #expect(viewModel.client is MockYTMusicClient)
    }
}
