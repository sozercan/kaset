import Testing
@testable import Kaset

// MARK: - CommandBarDiscoveryEdgeCaseTests

@Suite(.serialized)
@MainActor
struct CommandBarDiscoveryEdgeCaseTests {
    @Test("Duplicate mood and activity values count as one dimension")
    func duplicateMoodAndActivityRemainCurated() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "focus music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "focus",
            era: "",
            version: "",
            activity: "focus"
        )

        #expect(intent.suggestedContentSource() == .moodsAndGenres)
        #expect(intent.buildSearchQuery() == "focus music")
    }

    @Test("Song-title prepositions survive artist query cleanup")
    func songTitlePrepositionsArePreserved() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "From Me to You by the Beatles",
            shuffleScope: "",
            artist: "The Beatles",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        let query = intent.buildSearchQuery().lowercased()

        #expect(query.contains("from me to you"))
        #expect(query.contains("the beatles"))
    }

    @Test("Partially matching curated sections retain direct songs")
    func partialSectionSongsAreUsed() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let song = Self.makeSong(title: "Take Five", videoId: "take-five")
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(id: "jazz-essentials", title: "Jazz Essentials", items: [.song(song)]),
        ])
        let intent = MusicIntent(
            action: .play,
            query: "jazz",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(intent, originalQuery: "play jazz")
        )

        #expect(client.searchQueries.isEmpty)
        #expect(player.queue.map(\.videoId) == ["take-five"])
    }

    @Test("Incidental exact-title songs do not outrank curated playlists")
    func exactTitleSongDoesNotOutrankCuratedPlaylist() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let incidentalSong = Self.makeSong(title: "Jazz", videoId: "incidental-jazz")
        let curatedSong = Self.makeSong(title: "Take Five", videoId: "take-five")
        let playlist = Self.makePlaylist(id: "jazz-essentials", title: "Jazz Essentials")
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(id: "recommended", title: "Recommended", items: [.song(incidentalSong)]),
            HomeSection(id: "playlists", title: "Playlists", items: [.playlist(playlist)]),
        ])
        client.playlistDetails[playlist.id] = PlaylistDetail(playlist: playlist, tracks: [curatedSong])
        let intent = MusicIntent(
            action: .play,
            query: "jazz",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(intent, originalQuery: "play jazz")
        )

        #expect(client.getPlaylistIds == [playlist.id])
        #expect(player.queue.map(\.videoId) == ["take-five"])
    }

    @Test("Explicit search actions preserve grounded modifiers")
    func explicitSearchUsesGroundedQuery() async {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .search,
            query: "rock",
            shuffleScope: "",
            artist: "",
            genre: "rock",
            mood: "",
            era: "1990s",
            version: "",
            activity: ""
        )

        let outcome = await CommandExecutor(
            client: MockYTMusicClient(),
            playerService: MockPlayerService()
        ).execute(.musicIntent(intent, originalQuery: "search for 90s rock"))

        #expect(outcome.searchQueryToOpen == "90s rock")

        let titleIntent = MusicIntent(
            action: .search,
            query: "Greatest",
            shuffleScope: "",
            artist: "Eminem",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        let titleOutcome = await CommandExecutor(
            client: MockYTMusicClient(),
            playerService: MockPlayerService()
        ).execute(.musicIntent(titleIntent, originalQuery: "search for Greatest by Eminem"))

        #expect(titleOutcome.searchQueryToOpen == "Greatest by Eminem")
    }

    @Test("Song titles containing activity words remain searches")
    func activityWordInSongTitleDoesNotTriggerDiscovery() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Running Up That Hill",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .search)
        #expect(
            ContentSourceResolver.suggestedContentSource(
                for: intent,
                groundingQuery: "play the song Running Up That Hill"
            ) == .search
        )
    }

    @Test("Era cleanup does not leave dangling prepositions")
    func eraCleanupProducesValidQuery() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "rock songs from the 80s",
            shuffleScope: "",
            artist: "",
            genre: "rock",
            mood: "",
            era: "1980s",
            version: "",
            activity: ""
        )

        #expect(intent.buildSearchQuery() == "80s rock hits")

        let apostrophizedIntent = MusicIntent(
            action: .play,
            query: "rock songs from the 90's",
            shuffleScope: "",
            artist: "",
            genre: "rock",
            mood: "",
            era: "1990s",
            version: "",
            activity: ""
        )
        #expect(apostrophizedIntent.buildSearchQuery() == "90s rock hits")
    }

    @Test("Activity inflection does not erase a song title")
    func activityDoesNotEraseSongTitle() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Drive",
            shuffleScope: "",
            artist: "Incubus",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "driving"
        )
        let query = ContentSourceResolver.buildSearchQuery(
            from: intent,
            groundingQuery: "play Drive by Incubus while driving"
        ).lowercased()

        #expect(query.contains("drive"))
        #expect(query.contains("incubus"))
    }

    @Test("Artist cleanup runs after trailing qualifiers are removed")
    func artistCleanupHandlesTrailingQualifiers() {
        guard #available(macOS 26.0, *) else { return }

        let activityIntent = MusicIntent(
            action: .play,
            query: "Halo by Beyoncé for studying",
            shuffleScope: "",
            artist: "Beyoncé",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "study"
        )
        let eraIntent = MusicIntent(
            action: .play,
            query: "Halo by Beyoncé from the 90s",
            shuffleScope: "",
            artist: "Beyoncé",
            genre: "",
            mood: "",
            era: "1990s",
            version: "",
            activity: ""
        )

        let activityQuery = activityIntent.buildSearchQuery().lowercased()
        let eraQuery = eraIntent.buildSearchQuery().lowercased()

        #expect(activityQuery.contains("beyoncé"))
        #expect(activityQuery.contains("halo"))
        #expect(activityQuery.contains("study"))
        #expect(!activityQuery.contains(" by "))
        #expect(eraQuery.contains("beyoncé 90s halo"))
        #expect(!eraQuery.contains(" by "))
    }

    @Test("Exercising remains grounded as a workout activity")
    func exercisingRemainsGrounded() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "music for exercising",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "workout"
        )

        let grounded = ContentSourceResolver.groundedIntent(intent)

        #expect(grounded.activity == "workout")
        #expect(intent.suggestedContentSource() == .moodsAndGenres)
        #expect(intent.buildSearchQuery() == "workout music")
    }

    @Test("Semantic mood aliases share discovery taxonomy")
    func calmGroundsToRelaxingDiscovery() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let song = Self.makeSong(title: "Quiet Morning", videoId: "quiet-morning")
        let category = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_calm-params",
            title: "Calm"
        )
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(id: "moods", title: "Moods", items: [.playlist(category)]),
        ])
        client.moodCategoryResponse = HomeResponse(sections: [
            HomeSection(id: "songs", title: "Songs", items: [.song(song)]),
        ])
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

        let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: "play calm music")
        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(intent, originalQuery: "play calm music")
        )

        #expect(grounded.mood == "relaxing")
        #expect(client.moodCategoryParams == ["calm-params"])
        #expect(client.searchQueries.isEmpty)
        #expect(player.queue.map(\.videoId) == ["quiet-morning"])
    }

    @Test("Popularity keywords require whole-token matches")
    func popularitySubstringsDoNotTriggerCharts() {
        guard #available(macOS 26.0, *) else { return }

        let focusIntent = MusicIntent(
            action: .play,
            query: "focus music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "focus"
        )
        let titleIntent = MusicIntent(
            action: .play,
            query: "White Rabbit by Jefferson Airplane",
            shuffleScope: "",
            artist: "Jefferson Airplane",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(
            ContentSourceResolver.suggestedContentSource(
                for: focusIntent,
                groundingQuery: "play focus music on my laptop"
            ) == .moodsAndGenres
        )
        #expect(!titleIntent.buildSearchQuery().lowercased().contains("greatest hits"))
    }

    @Test("Localized canonical modifiers survive supported non-English grounding")
    func localizedModifiersRemainGrounded() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
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
        let originalQuery = "joue du rock des années 90"
        let grounded = ContentSourceResolver.groundedIntent(
            intent,
            groundingQuery: originalQuery
        )

        #expect(grounded.era == "1990s")
        #expect(
            ContentSourceResolver.buildSearchQuery(
                from: intent,
                groundingQuery: originalQuery
            ) == "90s rock hits"
        )
        #expect(
            ContentSourceResolver.suggestedContentSource(
                for: intent,
                groundingQuery: originalQuery
            ) == .search
        )
    }

    @Test("Popularity requests with discovery constraints use search")
    func constrainedPopularityUsesSearch() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
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
            ContentSourceResolver.suggestedContentSource(
                for: intent,
                groundingQuery: "play popular 90s rock"
            ) == .search
        )

        let topJazz = MusicIntent(
            action: .play,
            query: "jazz",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        #expect(
            ContentSourceResolver.buildSearchQuery(
                from: topJazz,
                groundingQuery: "play top jazz"
            ) == "jazz hits"
        )

        let topWorkout = MusicIntent(
            action: .play,
            query: "workout songs",
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
                from: topWorkout,
                groundingQuery: "play top workout songs"
            ) == "workout songs hits"
        )
    }

    @Test("Semantic mood and activity duplicates collapse to activity")
    func semanticMoodActivityDuplicatesRemainCurated() {
        guard #available(macOS 26.0, *) else { return }

        let cases = [
            (query: "party music", mood: "upbeat", activity: "party"),
            (query: "workout music", mood: "energetic", activity: "workout"),
        ]

        for item in cases {
            let intent = MusicIntent(
                action: .play,
                query: item.query,
                shuffleScope: "",
                artist: "",
                genre: "",
                mood: item.mood,
                era: "",
                version: "",
                activity: item.activity
            )
            let grounded = ContentSourceResolver.groundedIntent(intent)

            #expect(grounded.mood.isEmpty)
            #expect(grounded.activity == item.activity)
            #expect(intent.suggestedContentSource() == .moodsAndGenres)
        }

        let explicitCombinedIntent = MusicIntent(
            action: .play,
            query: "happy workout music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "happy",
            era: "",
            version: "",
            activity: "workout"
        )
        let explicitGrounded = ContentSourceResolver.groundedIntent(explicitCombinedIntent)

        #expect(explicitGrounded.mood == "happy")
        #expect(explicitGrounded.activity == "workout")
        #expect(explicitCombinedIntent.suggestedContentSource() == .search)
    }

    @Test("Song titles with to-run phrasing remain searches")
    func toRunSongTitleDoesNotTriggerActivityRouting() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Born to Run",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "run"
        )

        let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: "play Born to Run")

        #expect(grounded.activity.isEmpty)
        #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: "play Born to Run") == .search)
        #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: "play Born to Run") == "Born to Run")
    }

    @Test("Era searches retain both mood and genre")
    func eraSearchKeepsMoodAndGenre() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "chill",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "chill",
            era: "1990s",
            version: "",
            activity: ""
        )
        let query = ContentSourceResolver.buildSearchQuery(
            from: intent,
            groundingQuery: "play 90s chill jazz"
        )

        #expect(query.contains("90s"))
        #expect(query.contains("chill"))
        #expect(query.contains("jazz"))
    }

    @Test("Repeated words in song titles are preserved")
    func repeatedTitleWordsArePreserved() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Bye Bye Bye by NSYNC",
            shuffleScope: "",
            artist: "NSYNC",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.buildSearchQuery().lowercased().contains("bye bye bye"))
    }

    @Test("Standalone activity music phrases remain curated")
    func standaloneActivityPhraseRemainsCurated() {
        guard #available(macOS 26.0, *) else { return }

        for query in ["workout songs", "study tracks", "sleep songs", "party songs"] {
            let intent = MusicIntent(
                action: .play,
                query: query,
                shuffleScope: "",
                artist: "",
                genre: "",
                mood: "",
                era: "",
                version: "",
                activity: ""
            )

            #expect(intent.suggestedContentSource() == .moodsAndGenres)
        }

        let articleIntent = MusicIntent(
            action: .play,
            query: "music for a workout",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "workout"
        )
        let grounded = ContentSourceResolver.groundedIntent(articleIntent)

        #expect(grounded.activity == "workout")
        #expect(articleIntent.suggestedContentSource() == .moodsAndGenres)
        #expect(articleIntent.buildSearchQuery() == "workout music")

        let purposeCases = [
            (query: "music to sleep", activity: "sleep"),
            (query: "music to study", activity: "study"),
            (query: "music to work out", activity: "workout"),
            (query: "music while sleeping", activity: "sleep"),
        ]
        for item in purposeCases {
            let intent = MusicIntent(
                action: .play,
                query: item.query,
                shuffleScope: "",
                artist: "",
                genre: "",
                mood: "",
                era: "",
                version: "",
                activity: item.activity
            )
            #expect(ContentSourceResolver.groundedIntent(intent).activity == item.activity)
            #expect(intent.suggestedContentSource() == .moodsAndGenres)
        }
    }

    @Test("Version qualifier is not confused with title inflection")
    func versionQualifierSurvivesTitleInflection() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Nine Lives",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "live",
            activity: ""
        )
        let query = ContentSourceResolver.buildSearchQuery(
            from: intent,
            groundingQuery: "play Nine Lives live"
        ).lowercased()

        #expect(query.contains("nine lives"))
        #expect(query.contains("live"))
        #expect(ContentSourceResolver.groundedIntent(intent, groundingQuery: "play Nine Lives").version.isEmpty)
        #expect(
            ContentSourceResolver.buildSearchQuery(
                from: intent,
                groundingQuery: "play Nine Lives"
            ) == "Nine Lives"
        )
    }
}

extension CommandBarDiscoveryEdgeCaseTests {
    @Test("Exact title words do not swallow a version qualifier")
    func versionQualifierSurvivesExactTitleWord() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Live Forever",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "live",
            activity: ""
        )

        let query = ContentSourceResolver.buildSearchQuery(
            from: intent,
            groundingQuery: "play Live Forever live"
        )

        #expect(query == "live forever live version songs")
        #expect(ContentSourceResolver.groundedIntent(intent, groundingQuery: "play Live Forever").version.isEmpty)

        let terminalTitleIntent = MusicIntent(
            action: .play,
            query: "Long Live",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "live",
            activity: ""
        )
        #expect(
            ContentSourceResolver.groundedIntent(
                terminalTitleIntent,
                groundingQuery: "play Long Live"
            ).version.isEmpty
        )
        #expect(
            ContentSourceResolver.buildSearchQuery(
                from: terminalTitleIntent,
                groundingQuery: "play Long Live"
            ) == "Long Live"
        )

        let liveBluesIntent = MusicIntent(
            action: .play,
            query: "live blues",
            shuffleScope: "",
            artist: "",
            genre: "blues",
            mood: "",
            era: "",
            version: "live",
            activity: ""
        )
        let liveBlues = ContentSourceResolver.groundedIntent(
            liveBluesIntent,
            groundingQuery: "play live blues"
        )
        #expect(liveBlues.version == "live")
        #expect(
            ContentSourceResolver.suggestedContentSource(
                for: liveBluesIntent,
                groundingQuery: "play live blues"
            ) == .search
        )
    }

    @Test("Y2K and aughts wording retain the 2000s era")
    func semantic2000sAliasesRemainGrounded() {
        guard #available(macOS 26.0, *) else { return }

        for alias in ["Y2K", "aughts"] {
            let parsedIntent = MusicIntent(
                action: .play,
                query: "pop",
                shuffleScope: "",
                artist: "",
                genre: "pop",
                mood: "",
                era: "2000s",
                version: "",
                activity: ""
            )
            let originalQuery = "play \(alias) pop"

            #expect(ContentSourceResolver.groundedIntent(parsedIntent, groundingQuery: originalQuery).era == "2000s")
            #expect(
                ContentSourceResolver.suggestedContentSource(
                    for: parsedIntent,
                    groundingQuery: originalQuery
                ) == .search
            )

            let queryOnlyIntent = MusicIntent(
                action: .play,
                query: "\(alias) pop",
                shuffleScope: "",
                artist: "",
                genre: "pop",
                mood: "",
                era: "",
                version: "",
                activity: ""
            )
            #expect(queryOnlyIntent.suggestedContentSource() == .search)
        }
    }

    @Test("Duplicate mood and activity values preserve the activity role")
    func duplicateMoodAndActivityPreserveActivityRole() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "music for driving",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "driving",
            era: "",
            version: "",
            activity: "driving"
        )

        let grounded = ContentSourceResolver.groundedIntent(intent)

        #expect(grounded.mood.isEmpty)
        #expect(grounded.activity == "driving")
        #expect(intent.buildSearchQuery() == "driving music")
        #expect(intent.suggestedContentSource() == .moodsAndGenres)
    }

    @Test("Stop-word-only artist names remain grounded")
    func stopWordArtistRemainsGrounded() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "greatest hits by The The",
            shuffleScope: "",
            artist: "The The",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        let grounded = ContentSourceResolver.groundedIntent(intent)

        #expect(grounded.artist == "The The")
        #expect(intent.suggestedContentSource() == .search)
    }

    @Test("Semantic genre aliases remain grounded")
    func semanticGenreAliasRemainsGrounded() {
        guard #available(macOS 26.0, *) else { return }

        let cases = [
            (genre: "hip-hop", original: "play rap for studying"),
            (genre: "rap", original: "play hip-hop for studying"),
            (genre: "edm", original: "play electronic music for studying"),
            (genre: "rnb", original: "play R&B for studying"),
        ]

        for item in cases {
            let intent = MusicIntent(
                action: .play,
                query: item.genre,
                shuffleScope: "",
                artist: "",
                genre: item.genre,
                mood: "",
                era: "",
                version: "",
                activity: "study"
            )
            let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: item.original)

            #expect(grounded.genre == item.genre)
            #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: item.original) == .search)
        }
    }

    private static func makeSong(title: String, videoId: String) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: [Artist.inline(name: "Test Artist", namespace: "command-bar-edge-test")],
            videoId: videoId
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
}
