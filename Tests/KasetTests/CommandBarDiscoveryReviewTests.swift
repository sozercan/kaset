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

    @Test("Explicit titles do not ground generated activity")
    func explicitTitlesDoNotGroundActivity() {
        guard #available(macOS 26.0, *) else { return }

        let cases = [
            (title: "Born to Run", activity: "run"),
            (title: "Music to Run", activity: "run"),
        ]
        for item in cases {
            let intent = MusicIntent(
                action: .play,
                query: item.title,
                shuffleScope: "",
                artist: "",
                genre: "",
                mood: "",
                era: "",
                version: "",
                activity: item.activity
            )
            let originalQuery = "play the song \(item.title)"
            let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: originalQuery)

            #expect(grounded.activity.isEmpty)
            #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: originalQuery) == .search)
            #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery) == item.title)
        }
    }

    @Test("Explicit titles do not ground artist, era, or version")
    func explicitTitlesDoNotGroundOtherRoles() {
        guard #available(macOS 26.0, *) else { return }

        let artistIntent = MusicIntent(
            action: .play,
            query: "Train",
            shuffleScope: "",
            artist: "Train",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        #expect(
            ContentSourceResolver.groundedIntent(
                artistIntent,
                groundingQuery: "play the song Train"
            ).artist.isEmpty
        )

        let eraIntent = MusicIntent(
            action: .play,
            query: "Summer of 1995",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "1990s",
            version: "",
            activity: ""
        )
        #expect(
            ContentSourceResolver.groundedIntent(
                eraIntent,
                groundingQuery: "play the song Summer of 1995"
            ).era.isEmpty
        )

        let versionIntent = MusicIntent(
            action: .play,
            query: "Cover",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "cover",
            activity: ""
        )
        #expect(
            ContentSourceResolver.groundedIntent(
                versionIntent,
                groundingQuery: "play the song Cover"
            ).version.isEmpty
        )
    }

    @Test("Qualifiers outside explicit titles remain grounded")
    func explicitTitleQualifiersRemainGrounded() {
        guard #available(macOS 26.0, *) else { return }

        let activityIntent = MusicIntent(
            action: .play,
            query: "Born to Run",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "study"
        )
        #expect(
            ContentSourceResolver.groundedIntent(
                activityIntent,
                groundingQuery: "play the song Born to Run while studying"
            ).activity == "study"
        )

        let artistIntent = MusicIntent(
            action: .play,
            query: "Drops of Jupiter",
            shuffleScope: "",
            artist: "Train",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        #expect(
            ContentSourceResolver.groundedIntent(
                artistIntent,
                groundingQuery: "play the song Drops of Jupiter by Train"
            ).artist == "Train"
        )

        let versionIntent = MusicIntent(
            action: .play,
            query: "Cover",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "cover",
            activity: ""
        )
        #expect(
            ContentSourceResolver.groundedIntent(
                versionIntent,
                groundingQuery: "play the song Cover cover"
            ).version == "cover"
        )
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

    @Test("Popularity words inside explicit titles remain title text")
    func explicitTitlePopularityRemainsSearch() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Top of the World",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        let originalQuery = "play the song Top of the World"

        #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: originalQuery) == .search)
        #expect(ContentSourceResolver.queryDescription(for: intent, groundingQuery: originalQuery) == "Top of the World")
        #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery) == "Top of the World")
    }

    @Test("Prepositions inside explicit titles remain part of the title")
    func explicitTitlePrepositionsDoNotGroundQualifiers() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Rock in the 80s",
            shuffleScope: "",
            artist: "",
            genre: "rock",
            mood: "",
            era: "1980s",
            version: "",
            activity: ""
        )
        let originalQuery = "play the song Rock in the 80s"
        let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: originalQuery)

        #expect(grounded.genre.isEmpty)
        #expect(grounded.era.isEmpty)
        #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: originalQuery) == .search)
        #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery) == "Rock in the 80s")
    }

    @Test("Recent decades retain four-digit canonical forms")
    func recentDecadesRemainCanonical() {
        guard #available(macOS 26.0, *) else { return }

        for era in ["2010s", "2020s"] {
            let intent = MusicIntent(
                action: .play,
                query: "\(era) pop",
                shuffleScope: "",
                artist: "",
                genre: "pop",
                mood: "",
                era: era,
                version: "",
                activity: ""
            )

            #expect(intent.buildSearchQuery() == "\(era) pop hits")
        }
    }

    @Test("Contextual greatest requests retain popularity intent")
    func contextualGreatestRetainsPopularity() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "greatest songs by Adele",
            shuffleScope: "",
            artist: "Adele",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.buildSearchQuery() == "Adele greatest hits")
    }

    @Test("Parsed subjects discard command filler")
    func parsedSubjectCommandFillerIsRemoved() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "play some jazz",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.buildSearchQuery() == "jazz songs")
    }

    @Test("Work wording grounds the focus activity")
    func workGroundsFocusActivity() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "focus"
        )
        let originalQuery = "play music for work"
        let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: originalQuery)

        #expect(grounded.activity == "focus")
        #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: originalQuery) == .moodsAndGenres)
        #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery) == "focus music")
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
