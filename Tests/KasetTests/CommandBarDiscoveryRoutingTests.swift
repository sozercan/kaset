import Testing
@testable import Kaset

// MARK: - CommandBarDiscoveryRoutingTests

@Suite(.serialized)
@MainActor
struct CommandBarDiscoveryRoutingTests {
    @Test("Jazz category uses category songs instead of treating the category as a playlist")
    func jazzCategoryUsesDirectSongs() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let existing = Self.makeSong(title: "Existing", videoId: "existing")
        let jazzSongs = [
            Self.makeSong(title: "Take Five", videoId: "take-five"),
            Self.makeSong(title: "So What", videoId: "so-what"),
        ]
        player.queue = [existing]
        let chillCategory = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_chill-params",
            title: "Chill"
        )
        let jazzCategory = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_jazz-params",
            title: "Jazz"
        )
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(
                id: "categories",
                title: "Moods & Genres",
                items: [.playlist(chillCategory), .playlist(jazzCategory)]
            ),
        ])
        client.moodCategoryResponse = HomeResponse(sections: [
            HomeSection(
                id: "songs",
                title: "Songs",
                items: jazzSongs.map(HomeSectionItem.song)
            ),
        ])

        let outcome = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(Self.jazzIntent(hallucinatedMood: "chill"), originalQuery: "add jazz to queue")
        )

        #expect(client.moodCategoryBrowseIds == ["FEmusic_moods_and_genres_category"])
        #expect(client.moodCategoryParams == ["jazz-params"])
        #expect(client.getPlaylistIds.isEmpty)
        #expect(client.searchQueries.isEmpty)
        #expect(player.queue.map(\.videoId) == ["existing", "take-five", "so-what"])
        #expect(outcome.resultMessage == "Added jazz to queue")
    }

    @Test("Chill category fetches a real nested playlist")
    func chillCategoryUsesNestedPlaylist() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let playlistId = "VLRDCLAK5uy_chilled"
        let playlist = Self.makePlaylist(id: playlistId, title: "Chilled")
        let chillSongs = [
            Self.makeSong(title: "Soft Focus", videoId: "soft-focus"),
            Self.makeSong(title: "Night Air", videoId: "night-air"),
        ]
        client.moodsAndGenresResponse = Self.categoryLanding(title: "Chill", params: "chill-params")
        client.moodCategoryResponse = HomeResponse(sections: [
            HomeSection(
                id: "chilled",
                title: "Chilled",
                items: [.playlist(playlist)]
            ),
        ])
        client.playlistDetails[playlistId] = PlaylistDetail(playlist: playlist, tracks: chillSongs)

        let outcome = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(Self.chillIntent(), originalQuery: "play chill music")
        )

        #expect(client.moodCategoryBrowseIds == ["FEmusic_moods_and_genres_category"])
        #expect(client.moodCategoryParams == ["chill-params"])
        #expect(client.getPlaylistIds == [playlistId])
        #expect(client.searchQueries.isEmpty)
        #expect(player.queue.map(\.videoId) == ["soft-focus", "night-air"])
        #expect(outcome.resultMessage == "Playing chill")
    }

    @Test("Empty category content falls back to a clean song search")
    func emptyCategoryFallsBackToCleanSearch() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let fallbackSong = Self.makeSong(title: "Fallback Jazz", videoId: "fallback-jazz")
        client.moodsAndGenresResponse = Self.categoryLanding(title: "Jazz", params: "jazz-params")
        client.moodCategoryResponse = HomeResponse(sections: [])
        client.songsSearchResponse = SearchResponse(
            songs: [fallbackSong],
            albums: [],
            artists: [],
            playlists: [],
            continuationToken: nil
        )

        let outcome = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(Self.jazzIntent(), originalQuery: "add jazz to queue")
        )

        #expect(client.searchQueries == ["jazz songs"])
        #expect(player.queue.map(\.videoId) == ["fallback-jazz"])
        #expect(outcome.resultMessage == "Playing jazz")
    }

    @Test("Empty category and search results do not report success")
    func emptyResultsDoNotReportSuccess() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        client.moodsAndGenresResponse = Self.categoryLanding(title: "Jazz", params: "jazz-params")
        client.moodCategoryResponse = HomeResponse(sections: [])

        let outcome = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(Self.jazzIntent(), originalQuery: "add jazz to queue")
        )

        #expect(player.playQueueCallCount == 0)
        #expect(player.appendToQueueCallCount == 0)
        #expect(outcome.resultMessage == nil)
        #expect(outcome.errorMessage == "No songs found for \"jazz songs\"")
    }

    @Test("Generated modifiers must be grounded and search terms are deduplicated")
    func generatedModifiersAreGroundedAndDeduplicated() {
        guard #available(macOS 26.0, *) else { return }

        let classicalIntent = MusicIntent(
            action: .play,
            query: "classical music",
            shuffleScope: "",
            artist: "",
            genre: "classical",
            mood: "",
            era: "classic",
            version: "",
            activity: ""
        )
        let decadeIntent = MusicIntent(
            action: .play,
            query: "90's rock",
            shuffleScope: "",
            artist: "",
            genre: "rock",
            mood: "",
            era: "1990s",
            version: "",
            activity: ""
        )

        #expect(Self.chillIntent().buildSearchQuery() == "chill music")
        #expect(Self.chillIntent().queryDescription() == "chill")
        #expect(Self.chillIntent().suggestedContentSource() == .moodsAndGenres)
        #expect(Self.jazzIntent().buildSearchQuery() == "jazz songs")
        #expect(Self.jazzIntent().queryDescription() == "jazz")
        #expect(Self.jazzIntent().suggestedContentSource() == .moodsAndGenres)
        #expect(classicalIntent.buildSearchQuery() == "classical songs")
        #expect(classicalIntent.suggestedContentSource() == .moodsAndGenres)
        #expect(decadeIntent.buildSearchQuery() == "90s rock hits")
        #expect(decadeIntent.queryDescription() == "rock from the 1990s")
        #expect(decadeIntent.suggestedContentSource() == .search)
    }

    @Test("Inflected modifiers remain grounded")
    func inflectedModifiersRemainGrounded() {
        guard #available(macOS 26.0, *) else { return }

        let relaxingIntent = MusicIntent(
            action: .play,
            query: "music to relax",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "relaxing",
            era: "",
            version: "",
            activity: ""
        )
        let artistIntent = MusicIntent(
            action: .play,
            query: "songs by Beatles",
            shuffleScope: "",
            artist: "Beatles",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        let coverIntent = MusicIntent(
            action: .play,
            query: "acoustic covers of pop hits",
            shuffleScope: "",
            artist: "",
            genre: "pop",
            mood: "",
            era: "",
            version: "cover",
            activity: ""
        )
        let runningIntent = MusicIntent(
            action: .play,
            query: "music for running",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "run"
        )
        let versionOnlyIntent = MusicIntent(
            action: .play,
            query: "Halo",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "live",
            activity: ""
        )

        #expect(relaxingIntent.buildSearchQuery() == "relaxing music")
        #expect(artistIntent.buildSearchQuery() == "Beatles songs")
        #expect(ContentSourceResolver.groundedIntent(coverIntent).version == "cover")
        #expect(coverIntent.suggestedContentSource() == .search)
        #expect(coverIntent.buildSearchQuery().contains("covers"))
        #expect(ContentSourceResolver.groundedIntent(runningIntent).activity == "run")
        #expect(runningIntent.suggestedContentSource() == .moodsAndGenres)
        #expect(
            ContentSourceResolver.buildSearchQuery(
                from: versionOnlyIntent,
                groundingQuery: "play Halo live"
            ).contains("live")
        )
    }

    @Test("Duplicate mood and genre values use the recognized role")
    func duplicateMoodAndGenreUseRecognizedRole() {
        guard #available(macOS 26.0, *) else { return }

        let duplicateChillIntent = MusicIntent(
            action: .play,
            query: "chill music",
            shuffleScope: "",
            artist: "",
            genre: "chill",
            mood: "chill",
            era: "",
            version: "",
            activity: ""
        )
        let duplicateJazzIntent = MusicIntent(
            action: .play,
            query: "jazz music",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "jazz",
            era: "",
            version: "",
            activity: ""
        )

        #expect(duplicateChillIntent.buildSearchQuery() == "chill music")
        #expect(duplicateChillIntent.queryDescription() == "chill")
        #expect(duplicateJazzIntent.buildSearchQuery() == "jazz songs")
        #expect(duplicateJazzIntent.queryDescription() == "jazz")
        #expect(duplicateJazzIntent.suggestedContentSource() == .moodsAndGenres)
    }

    @Test("Original command grounds qualifiers omitted from the generated subject")
    func originalCommandGroundsOmittedQualifiers() {
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
        let originalQuery = "play 90s rock"

        let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: originalQuery)

        #expect(grounded.era == "1990s")
        #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery) == "90s rock hits")
        #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: originalQuery) == .search)
    }

    @Test("Multi-dimensional discovery requests use combined search")
    func multiDimensionalDiscoveryUsesSearch() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "chill jazz for studying",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "chill",
            era: "",
            version: "",
            activity: "study"
        )

        #expect(intent.suggestedContentSource() == .search)
    }

    @Test("Era combined with another discovery dimension uses search")
    func eraAndMoodUseSearch() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "90s chill music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "chill",
            era: "1990s",
            version: "",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .search)
    }

    @Test("Subject-only qualifiers participate in dimension routing")
    func subjectOnlyQualifiersUseSearch() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "chill jazz",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .search)
    }

    @Test("Grounded activity is retained in combined search")
    func groundedActivityIsIncludedInSearch() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "jazz",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "",
            era: "",
            version: "",
            activity: "study"
        )
        let originalQuery = "play jazz for studying"

        let query = ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery)

        #expect(query.contains("jazz"))
        #expect(query.contains("study"))
        #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: originalQuery) == .search)
    }

    @Test("Activity aliases are shared with category discovery")
    func activityAliasesRemainGrounded() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "music for commuting",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "driving"
        )

        let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: "play music for commuting")

        #expect(grounded.activity == "driving")
        #expect(
            ContentSourceResolver.suggestedContentSource(
                for: intent,
                groundingQuery: "play music for commuting"
            ) == .moodsAndGenres
        )
    }

    @Test("Executor grounds generated fields against the original command")
    func executorUsesOriginalCommandForGrounding() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let song = Self.makeSong(title: "90s Rock", videoId: "90s-rock")
        client.songsSearchResponse = SearchResponse(
            songs: [song],
            albums: [],
            artists: [],
            playlists: [],
            continuationToken: nil
        )
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

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(intent, originalQuery: "play 90s rock")
        )

        #expect(client.searchQueries == ["90s rock hits"])
        #expect(player.queue.map(\.videoId) == ["90s-rock"])
    }

    @Test("Exact genre category wins over a preceding partial match")
    func exactGenreCategoryWinsOverPartialMatch() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let kPop = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_kpop-params",
            title: "K-Pop"
        )
        let pop = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_pop-params",
            title: "Pop"
        )
        let incidentalSong = Self.makeSong(title: "Pop", videoId: "incidental")
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(
                id: "genres",
                title: "Genres",
                items: [.song(incidentalSong), .playlist(kPop), .playlist(pop)]
            ),
        ])
        client.moodCategoryResponses["kpop-params"] = Self.songResponse(
            Self.makeSong(title: "K-Pop Result", videoId: "kpop")
        )
        client.moodCategoryResponses["pop-params"] = Self.songResponse(
            Self.makeSong(title: "Pop Result", videoId: "pop")
        )
        let intent = MusicIntent(
            action: .play,
            query: "pop music",
            shuffleScope: "",
            artist: "",
            genre: "pop",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(intent, originalQuery: "play pop music")
        )

        #expect(client.moodCategoryParams == ["pop-params"])
        #expect(player.queue.map(\.videoId) == ["pop"])
    }

    @Test("Filler words cannot select an unrelated category")
    func fillerWordsDoNotSelectUnrelatedCategory() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let forYou = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_for-you-params",
            title: "For You"
        )
        let workout = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_workout-params",
            title: "Workout"
        )
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(id: "moods", title: "Moods", items: [.playlist(forYou), .playlist(workout)]),
        ])
        client.moodCategoryResponses["for-you-params"] = Self.songResponse(
            Self.makeSong(title: "Wrong Result", videoId: "wrong")
        )
        client.moodCategoryResponses["workout-params"] = Self.songResponse(
            Self.makeSong(title: "Running Result", videoId: "running")
        )
        let intent = MusicIntent(
            action: .play,
            query: "music for running",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "run"
        )

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(intent, originalQuery: "play music for running")
        )

        #expect(client.moodCategoryParams == ["workout-params"])
        #expect(player.queue.map(\.videoId) == ["running"])
    }
}

extension CommandBarDiscoveryRoutingTests {
    @Test("Nested mood category cards resolve without becoming playlist IDs")
    func nestedMoodCategoryResolvesRecursively() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let nestedCategory = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_inner-params",
            title: "Chilled",
            moodCategoryEndpoint: MoodCategoryEndpoint(
                browseId: "FEmusic_moods_and_genres_category_inner",
                params: "inner-params"
            )
        )
        client.moodsAndGenresResponse = Self.categoryLanding(title: "Chill", params: "outer-params")
        client.moodCategoryResponses["outer-params"] = HomeResponse(sections: [
            HomeSection(id: "nested", title: "Chilled", items: [.playlist(nestedCategory)]),
        ])
        client.moodCategoryResponses["inner-params"] = Self.songResponse(
            Self.makeSong(title: "Nested Chill", videoId: "nested-chill")
        )

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(Self.chillIntent(), originalQuery: "play chill music")
        )

        #expect(client.moodCategoryParams == ["outer-params", "inner-params"])
        #expect(client.moodCategoryBrowseIds == [
            "FEmusic_moods_and_genres_category",
            "FEmusic_moods_and_genres_category_inner",
        ])
        #expect(client.getPlaylistIds.isEmpty)
        #expect(player.queue.map(\.videoId) == ["nested-chill"])
    }

    @Test("Punctuation-only terms cannot match every category")
    func punctuationOnlyTermsDoNotMatchCategories() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let wrongCategory = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_wrong-params",
            title: "Unrelated"
        )
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(id: "moods", title: "Moods", items: [.playlist(wrongCategory)]),
        ])
        let fallbackSong = Self.makeSong(title: "Fallback Chill", videoId: "fallback-chill")
        client.songsSearchResponse = SearchResponse(
            songs: [fallbackSong],
            albums: [],
            artists: [],
            playlists: [],
            continuationToken: nil
        )
        let intent = MusicIntent(
            action: .play,
            query: "chill & noise",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "chill",
            era: "",
            version: "",
            activity: ""
        )

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(intent, originalQuery: "play chill & noise")
        )

        #expect(client.moodCategoryParams.isEmpty)
        #expect(client.searchQueries == ["chill music noise"])
        #expect(player.queue.map(\.videoId) == ["fallback-chill"])
    }

    @Test("Modern decade shorthand remains grounded")
    func modernDecadeShorthandRemainsGrounded() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
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
        let originalQuery = "play 00s pop"

        let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: originalQuery)

        #expect(grounded.era == "2000s")
        #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery) == "2000s pop hits")
    }

    @Test("Canonical artist spellings remain grounded")
    func canonicalArtistSpellingsRemainGrounded() {
        guard #available(macOS 26.0, *) else { return }

        let cases = [
            (artist: "Beyoncé", original: "play Halo by Beyonce"),
            (artist: "AC/DC", original: "play Back in Black by ACDC"),
            (artist: "P!nk", original: "play songs by Pink"),
            (artist: "A$AP Rocky", original: "play Praise the Lord by ASAP Rocky"),
        ]

        for item in cases {
            let intent = MusicIntent(
                action: .play,
                query: "song",
                shuffleScope: "",
                artist: item.artist,
                genre: "",
                mood: "",
                era: "",
                version: "",
                activity: ""
            )

            #expect(ContentSourceResolver.groundedIntent(intent, groundingQuery: item.original).artist == item.artist)
        }

        let hallucinatedArtist = MusicIntent(
            action: .play,
            query: "training music",
            shuffleScope: "",
            artist: "Train",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        let hallucinatedGenre = MusicIntent(
            action: .play,
            query: "blue songs",
            shuffleScope: "",
            artist: "",
            genre: "blues",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(ContentSourceResolver.groundedIntent(hallucinatedArtist).artist.isEmpty)
        #expect(ContentSourceResolver.groundedIntent(hallucinatedGenre).genre.isEmpty)
    }

    @Test("Grounded focus mood is not double-counted as an activity")
    func focusMoodRemainsCurated() {
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
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .moodsAndGenres)
    }

    @Test("Matching direct songs on the landing response are preserved")
    func landingDirectSongsAreUsed() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let song = Self.makeSong(title: "Jazz Standard", videoId: "jazz-standard")
        client.moodsAndGenresResponse = HomeResponse(sections: [
            HomeSection(id: "jazz", title: "Jazz", items: [.song(song)]),
        ])

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(Self.jazzIntent(), originalQuery: "play jazz")
        )

        #expect(client.moodCategoryParams.isEmpty)
        #expect(client.getPlaylistIds.isEmpty)
        #expect(client.searchQueries.isEmpty)
        #expect(player.queue.map(\.videoId) == ["jazz-standard"])
    }

    @Test("Mood category direct songs are deduplicated by video ID")
    func moodCategoryDirectSongsAreDeduplicated() async {
        guard #available(macOS 26.0, *) else { return }

        let client = MockYTMusicClient()
        let player = MockPlayerService()
        let repeated = Self.makeSong(title: "Repeated", videoId: "repeated")
        let unique = Self.makeSong(title: "Unique", videoId: "unique")
        client.moodsAndGenresResponse = Self.categoryLanding(title: "Jazz", params: "jazz-params")
        client.moodCategoryResponse = HomeResponse(sections: [
            HomeSection(id: "first", title: "First", items: [.song(repeated), .song(unique)]),
            HomeSection(id: "second", title: "Second", items: [.song(repeated)]),
        ])

        _ = await CommandExecutor(client: client, playerService: player).execute(
            .musicIntent(Self.jazzIntent(), originalQuery: "play jazz")
        )

        #expect(player.queue.map(\.videoId) == ["repeated", "unique"])
    }

    @available(macOS 26.0, *)
    private static func chillIntent() -> MusicIntent {
        MusicIntent(
            action: .play,
            query: "chill music",
            shuffleScope: "queue",
            artist: "",
            genre: "relaxing",
            mood: "chill",
            era: "classic",
            version: "",
            activity: ""
        )
    }

    @available(macOS 26.0, *)
    private static func jazzIntent(hallucinatedMood: String = "") -> MusicIntent {
        MusicIntent(
            action: .queue,
            query: "jazz",
            shuffleScope: "queue",
            artist: "",
            genre: "jazz",
            mood: hallucinatedMood,
            era: "",
            version: "",
            activity: ""
        )
    }

    private static func categoryLanding(title: String, params: String) -> HomeResponse {
        let category = Self.makePlaylist(
            id: "FEmusic_moods_and_genres_category_\(params)",
            title: title
        )
        return HomeResponse(sections: [
            HomeSection(
                id: "categories",
                title: "Moods & Genres",
                items: [.playlist(category)]
            ),
        ])
    }

    private static func songResponse(_ song: Song) -> HomeResponse {
        HomeResponse(sections: [
            HomeSection(id: "songs", title: "Songs", items: [.song(song)]),
        ])
    }

    private static func makePlaylist(
        id: String,
        title: String,
        moodCategoryEndpoint: MoodCategoryEndpoint? = nil
    ) -> Playlist {
        Playlist(
            id: id,
            title: title,
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            moodCategoryEndpoint: moodCategoryEndpoint
        )
    }

    private static func makeSong(title: String, videoId: String) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: [Artist.inline(name: "Test Artist", namespace: "command-bar-test")],
            videoId: videoId
        )
    }
}
