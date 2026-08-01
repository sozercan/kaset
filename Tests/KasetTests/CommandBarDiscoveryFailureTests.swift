import Foundation
import Testing
@testable import Kaset

@Suite(.serialized)
@MainActor
struct CommandBarDiscoveryFailureTests {
    @Test("Curated candidate failures do not fan out across categories")
    func curatedFailureStopsCandidateTraversal() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let first = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_first-params",
            title: "Chill"
        )
        let second = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_second-params",
            title: "Chilled"
        )
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(id: "moods", title: "Moods", items: [.playlist(first), .playlist(second)]),
        ])
        client.moodCategoryError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))
        client.songsSearchResponse = SearchResponse(
            songs: [Self.makeSong(title: "Fallback", videoId: "fallback")],
            albums: [],
            artists: [],
            playlists: [],
            continuationToken: nil
        )

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(Self.chillIntent(), originalQuery: "play chill music")
        )

        #expect(client.moodCategoryParams == ["first-params"])
        #expect(client.searchQueries == ["chill music"])
    }

    @available(macOS 26.0, *)
    private static func chillIntent() -> MusicIntent {
        MusicIntent(
            action: .play,
            query: "chill music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "chill",
            era: "",
            version: "",
            activity: ""
        )
    }

    private static func makePlaylist(id: String, title: String) -> Playlist {
        Playlist(
            id: id,
            title: title,
            description: nil,
            thumbnailURL: nil,
            trackCount: nil
        )
    }

    private static func makeSong(title: String, videoId: String) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: [Artist.inline(name: "Test Artist", namespace: "command-bar-failure-test")],
            videoId: videoId
        )
    }
}
