import Testing
@testable import Kaset

@Suite(.serialized)
@MainActor
struct CommandBarDiscoveryEndpointTests {
    @Test("Mood category cycles use structured endpoints instead of display IDs")
    func distinctEndpointsWithSameDisplayIdResolve() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let sharedId = "ambiguous-display-id"
        let outer = Self.makePlaylist(
            id: sharedId,
            title: "Chill",
            endpoint: MoodCategoryEndpoint(
                browseId: "FEmusic_moods_and_genres_category",
                params: "outer"
            )
        )
        let inner = Self.makePlaylist(
            id: sharedId,
            title: "Chilled",
            endpoint: MoodCategoryEndpoint(
                browseId: "FEmusic_moods_and_genres_category_inner",
                params: "inner"
            )
        )
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(id: "moods", title: "Moods", items: [.playlist(outer)]),
        ])
        client.moodCategoryResponses["outer"] = HomeResponse(sections: [
            HomeSection(id: "nested", title: "Nested", items: [.playlist(inner)]),
        ])
        client.moodCategoryResponses["inner"] = Self.songResponse(
            Self.makeSong(title: "Resolved", videoId: "resolved")
        )

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(Self.chillIntent(), originalQuery: "play chill music")
        )

        #expect(client.moodCategoryParams == ["outer", "inner"])
        #expect(player.queue.map(\.videoId) == ["resolved"])
    }

    @Test("Distinct category endpoints with the same display ID remain candidates")
    func duplicateDisplayIdsDoNotDiscardEndpoints() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let sharedId = "shared-display-id"
        let empty = Self.makePlaylist(
            id: sharedId,
            title: "Chill",
            endpoint: MoodCategoryEndpoint(
                browseId: "FEmusic_moods_and_genres_category",
                params: "empty"
            )
        )
        let populated = Self.makePlaylist(
            id: sharedId,
            title: "Chill",
            endpoint: MoodCategoryEndpoint(
                browseId: "FEmusic_moods_and_genres_category",
                params: "populated"
            )
        )
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(id: "moods", title: "Moods", items: [.playlist(empty), .playlist(populated)]),
        ])
        client.moodCategoryResponses["empty"] = HomeResponse(sections: [])
        client.moodCategoryResponses["populated"] = Self.songResponse(
            Self.makeSong(title: "Resolved", videoId: "resolved")
        )

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(Self.chillIntent(), originalQuery: "play chill music")
        )

        #expect(client.moodCategoryParams == ["empty", "populated"])
        #expect(player.queue.map(\.videoId) == ["resolved"])
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

    private static func makePlaylist(
        id: String,
        title: String,
        endpoint: MoodCategoryEndpoint
    ) -> Playlist {
        Playlist(
            id: id,
            title: title,
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            moodCategoryEndpoint: endpoint
        )
    }

    private static func songResponse(_ song: Song) -> HomeResponse {
        HomeResponse(sections: [
            HomeSection(id: "songs", title: "Songs", items: [.song(song)]),
        ])
    }

    private static func makeSong(title: String, videoId: String) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: [Artist.inline(name: "Test Artist", namespace: "command-bar-endpoint-test")],
            videoId: videoId
        )
    }
}
