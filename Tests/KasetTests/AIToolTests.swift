import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.api), .serialized)
@MainActor
struct MusicSearchToolTests {
    let mockClient = MockYTMusicClient()

    @available(macOS 26.0, *)
    private func makeTool() -> MusicSearchTool {
        MusicSearchTool(client: self.mockClient)
    }

    @Test("Tool has correct name and description")
    func toolMetadata() {
        guard #available(macOS 26.0, *) else { return }
        let tool = self.makeTool()
        #expect(tool.name == "searchMusic")
        #expect(tool.description.contains("YouTube Music"))
    }

    @Test("Search returns formatted song results")
    func searchReturnsSongs() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tool = self.makeTool()
        self.mockClient.searchResponse = TestFixtures.makeSearchResponse(
            songCount: 3, albumCount: 0, artistCount: 0, playlistCount: 0
        )

        let args = MusicSearchTool.Arguments(query: "jazz", filter: "songs")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("Search results for 'jazz'"))
        #expect(result.contains("SONG:"))
        #expect(result.contains("videoId:"))
        #expect(self.mockClient.searchCalled)
    }

    @Test("Search returns formatted album results")
    func searchReturnsAlbums() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tool = self.makeTool()
        self.mockClient.searchResponse = TestFixtures.makeSearchResponse(
            songCount: 0, albumCount: 2, artistCount: 0, playlistCount: 0
        )

        let args = MusicSearchTool.Arguments(query: "rock albums", filter: "albums")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("ALBUM:"))
        #expect(result.contains("browseId:"))
    }

    @Test("Search returns formatted artist results")
    func searchReturnsArtists() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tool = self.makeTool()
        self.mockClient.searchResponse = TestFixtures.makeSearchResponse(
            songCount: 0, albumCount: 0, artistCount: 2, playlistCount: 0
        )

        let args = MusicSearchTool.Arguments(query: "Beatles", filter: "artists")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("ARTIST:"))
        #expect(result.contains("channelId:"))
    }

    @Test("Search returns formatted playlist results")
    func searchReturnsPlaylists() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tool = self.makeTool()
        self.mockClient.searchResponse = TestFixtures.makeSearchResponse(
            songCount: 0, albumCount: 0, artistCount: 0, playlistCount: 2
        )

        let args = MusicSearchTool.Arguments(query: "workout", filter: "playlists")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("PLAYLIST:"))
        #expect(result.contains("playlistId:"))
    }

    @Test("Search with 'all' filter returns mixed results")
    func searchAllFilterReturnsMixed() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tool = self.makeTool()
        self.mockClient.searchResponse = TestFixtures.makeSearchResponse(
            songCount: 2, albumCount: 1, artistCount: 1, playlistCount: 1
        )

        let args = MusicSearchTool.Arguments(query: "pop", filter: "all")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("SONG:"))
        #expect(result.contains("ALBUM:"))
        #expect(result.contains("ARTIST:"))
        #expect(result.contains("PLAYLIST:"))
    }

    @Test("Search with empty filter returns all results")
    func searchEmptyFilterReturnsAll() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tool = self.makeTool()
        self.mockClient.searchResponse = TestFixtures.makeSearchResponse(
            songCount: 2, albumCount: 1, artistCount: 1, playlistCount: 1
        )

        let args = MusicSearchTool.Arguments(query: "music", filter: "")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("SONG:"))
        #expect(result.contains("ALBUM:"))
    }

    @Test("Search with no results returns appropriate message")
    func searchNoResults() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tool = self.makeTool()
        self.mockClient.searchResponse = SearchResponse.empty

        let args = MusicSearchTool.Arguments(query: "xyznonexistent", filter: "all")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("No results found"))
        #expect(result.contains("xyznonexistent"))
    }

    @Test("Search propagates errors")
    func searchPropagatesErrors() async throws {
        guard #available(macOS 26.0, *) else { return }
        let tool = self.makeTool()
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )

        let args = MusicSearchTool.Arguments(query: "test", filter: "songs")

        do {
            _ = try await tool.call(arguments: args)
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(error is YTMusicError)
        }
    }
}

@Suite(.tags(.api))
struct QueueToolTests {
    @Test("Tool has correct name and description")
    @MainActor
    func toolMetadata() {
        guard #available(macOS 26.0, *) else { return }
        let playerService = PlayerService()
        let tool = QueueTool(playerService: playerService)

        #expect(tool.name == "getCurrentQueue")
        #expect(tool.description.contains("queue"))
    }

    @Test("Empty queue returns appropriate message")
    @MainActor
    func emptyQueue() async throws {
        guard #available(macOS 26.0, *) else { return }
        let playerService = PlayerService()
        let tool = QueueTool(playerService: playerService)

        let args = QueueTool.Arguments(limit: 20)
        let result = try await tool.call(arguments: args)

        #expect(result.contains("Queue is empty"))
    }
}
