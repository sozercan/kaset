import Testing
@testable import Kaset

@Suite(.serialized)
@MainActor
struct CommandBarDiscoveryReviewTests {
    @Test("Explicit song syntax prevents discovery-role collisions")
    func explicitSongSyntaxPreventsDiscoveryRoles() {
        guard #available(macOS 26.0, *) else { return }

        let cases = [
            MusicIntent(
                action: .play,
                query: "Happy",
                shuffleScope: "",
                artist: "",
                genre: "",
                mood: "happy",
                era: "",
                version: "",
                activity: ""
            ),
            MusicIntent(
                action: .play,
                query: "Rock",
                shuffleScope: "",
                artist: "",
                genre: "rock",
                mood: "",
                era: "",
                version: "",
                activity: ""
            ),
        ]

        for intent in cases {
            let originalQuery = "play the song \(intent.query)"
            let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: originalQuery)

            #expect(grounded.genre.isEmpty)
            #expect(grounded.mood.isEmpty)
            #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: originalQuery) == .search)
            #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery) == intent.query)
        }
    }

    @Test("Explicit title syntax does not treat Study Music as an activity")
    func explicitStudyMusicTitleRemainsSearch() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Study Music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "study"
        )
        let originalQuery = "play the song Study Music"
        let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: originalQuery)

        #expect(grounded.activity.isEmpty)
        #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: originalQuery) == .search)
        #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery) == "Study Music")
    }

    @Test("Original mood alias outranks broader synonyms")
    func originalMoodAliasRanksFirst() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let chill = Self.makeCategory(title: "Chill", params: "chill-params")
        let calm = Self.makeCategory(title: "Calm", params: "calm-params")
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(id: "moods", title: "Moods", items: [.playlist(chill), .playlist(calm)]),
        ])
        client.moodCategoryResponses["chill-params"] = Self.songResponse(title: "Wrong", videoId: "wrong")
        client.moodCategoryResponses["calm-params"] = Self.songResponse(title: "Calm", videoId: "calm")
        let intent = MusicIntent(
            action: .play,
            query: "music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "relaxing",
            era: "",
            version: "",
            activity: ""
        )

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(intent, originalQuery: "play calm music")
        )

        #expect(client.moodCategoryParams == ["calm-params"])
        #expect(player.queue.map(\.videoId) == ["calm"])
    }

    @Test("Contextual singular hit requests retain popularity intent")
    func singularHitContentNounsRetainPopularity() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "hit songs by Adele",
            shuffleScope: "",
            artist: "Adele",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.buildSearchQuery() == "Adele greatest hits")

        let titleIntent = MusicIntent(
            action: .play,
            query: "Despacito",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        #expect(
            ContentSourceResolver.buildSearchQuery(
                from: titleIntent,
                groundingQuery: "play the hit song Despacito"
            ) == "Despacito"
        )
    }

    @Test("Standalone activity subjects remain curated")
    func standaloneActivitiesRemainCurated() {
        guard #available(macOS 26.0, *) else { return }

        for activity in ["workout", "sleep", "party"] {
            let intent = MusicIntent(
                action: .play,
                query: activity,
                shuffleScope: "",
                artist: "",
                genre: "",
                mood: "",
                era: "",
                version: "",
                activity: activity
            )
            let originalQuery = "play \(activity)"
            let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: originalQuery)

            #expect(grounded.activity == activity)
            #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: originalQuery) == .moodsAndGenres)
            #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery) == "\(activity) music")

            let queryOnlyIntent = MusicIntent(
                action: .play,
                query: activity,
                shuffleScope: "",
                artist: "",
                genre: "",
                mood: "",
                era: "",
                version: "",
                activity: ""
            )
            #expect(
                ContentSourceResolver.suggestedContentSource(
                    for: queryOnlyIntent,
                    groundingQuery: originalQuery
                ) == .moodsAndGenres
            )
        }

        let topWorkout = MusicIntent(
            action: .play,
            query: "workout",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "workout"
        )
        #expect(
            ContentSourceResolver.suggestedContentSource(
                for: topWorkout,
                groundingQuery: "play top workout"
            ) == .search
        )

        let titleIntent = MusicIntent(
            action: .play,
            query: "Sleep",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "sleep"
        )
        #expect(
            ContentSourceResolver.groundedIntent(
                titleIntent,
                groundingQuery: "play the song Sleep"
            ).activity.isEmpty
        )
        #expect(
            ContentSourceResolver.suggestedContentSource(
                for: titleIntent,
                groundingQuery: "play the song Sleep"
            ) == .search
        )
    }

    @Test("Title and artist years do not ground an era")
    func titleYearsDoNotGroundEra() {
        guard #available(macOS 26.0, *) else { return }

        let artistIntent = MusicIntent(
            action: .play,
            query: "The 1975",
            shuffleScope: "",
            artist: "The 1975",
            genre: "",
            mood: "",
            era: "1970s",
            version: "",
            activity: ""
        )
        let groundedArtist = ContentSourceResolver.groundedIntent(
            artistIntent,
            groundingQuery: "play The 1975"
        )
        #expect(groundedArtist.era.isEmpty)
        #expect(
            ContentSourceResolver.buildSearchQuery(
                from: artistIntent,
                groundingQuery: "play The 1975"
            ) == "The 1975 songs"
        )

        let titleIntent = MusicIntent(
            action: .play,
            query: "1979",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "1970s",
            version: "",
            activity: ""
        )
        let groundedTitle = ContentSourceResolver.groundedIntent(titleIntent, groundingQuery: "play the song 1979")
        #expect(groundedTitle.era.isEmpty)
        #expect(ContentSourceResolver.suggestedContentSource(for: titleIntent, groundingQuery: "play the song 1979") == .search)
        #expect(ContentSourceResolver.buildSearchQuery(from: titleIntent, groundingQuery: "play the song 1979") == "1979")

        let eraIntent = MusicIntent(
            action: .play,
            query: "rock",
            shuffleScope: "",
            artist: "",
            genre: "rock",
            mood: "",
            era: "1990s",
            version: "",
            activity: ""
        )
        #expect(
            ContentSourceResolver.groundedIntent(
                eraIntent,
                groundingQuery: "play rock from 1995"
            ).era == "1990s"
        )
    }

    private static func makeCategory(title: String, params: String) -> Playlist {
        Playlist(
            id: params,
            title: title,
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            moodCategoryEndpoint: MoodCategoryEndpoint(
                browseId: "FEmusic_moods_and_genres_category",
                params: params
            )
        )
    }

    private static func songResponse(title: String, videoId: String) -> HomeResponse {
        let song = Song(
            id: videoId,
            title: title,
            artists: [Artist.inline(name: "Test Artist", namespace: "command-bar-review-test")],
            videoId: videoId
        )
        return HomeResponse(sections: [
            HomeSection(id: "songs", title: "Songs", items: [.song(song)]),
        ])
    }
}
