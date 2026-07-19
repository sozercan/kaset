import Testing
@testable import Kaset

@Suite(.serialized)
@MainActor
struct CommandBarDiscoveryNormalizationTests {
    @Test("Punctuation-delimited genre tokens survive partial deduplication")
    func multiTokenGenreSurvivesArtistOverlap() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "R&B songs by R. Kelly",
            shuffleScope: "",
            artist: "R. Kelly",
            genre: "R&B",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.buildSearchQuery() == "R. Kelly R&B songs")
    }

    @Test("Query-only supported genres count as discovery dimensions")
    func queryOnlySupportedGenresUseCombinedSearch() {
        guard #available(macOS 26.0, *) else { return }

        for genre in ["blues", "house", "techno", "alternative"] {
            let partiallyParsedIntent = MusicIntent(
                action: .play,
                query: "chill \(genre)",
                shuffleScope: "",
                artist: "",
                genre: "",
                mood: "chill",
                era: "",
                version: "",
                activity: ""
            )
            let queryOnlyIntent = MusicIntent(
                action: .play,
                query: "chill \(genre)",
                shuffleScope: "",
                artist: "",
                genre: "",
                mood: "",
                era: "",
                version: "",
                activity: ""
            )

            #expect(partiallyParsedIntent.suggestedContentSource() == .search)
            #expect(queryOnlyIntent.suggestedContentSource() == .search)
        }
    }

    @Test("Descriptions retain popularity from the original command")
    func descriptionUsesGroundingQueryPopularity() {
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
            activity: ""
        )

        #expect(
            ContentSourceResolver.queryDescription(
                for: intent,
                groundingQuery: "play top jazz"
            ) == "jazz hits"
        )
    }

    @Test("Ambiguous popularity words in song titles do not route to charts")
    func titleWordsDoNotTriggerCharts() {
        guard #available(macOS 26.0, *) else { return }

        let cases = [
            (subject: "The Greatest", command: "play The Greatest"),
            (subject: "Despacito", command: "play the hit song Despacito"),
        ]

        for item in cases {
            let intent = MusicIntent(
                action: .play,
                query: item.subject,
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
                    for: intent,
                    groundingQuery: item.command
                ) == .search
            )
            #expect(
                ContentSourceResolver.buildSearchQuery(
                    from: intent,
                    groundingQuery: item.command
                ) == item.subject
            )
        }
    }

    @Test("Modifier clauses are removed without dangling prepositions")
    func modifierClausesProduceCleanFallbackQueries() {
        guard #available(macOS 26.0, *) else { return }

        let cases = [
            (
                intent: MusicIntent(
                    action: .play,
                    query: "music for relaxing",
                    shuffleScope: "",
                    artist: "",
                    genre: "",
                    mood: "relaxing",
                    era: "",
                    version: "",
                    activity: ""
                ),
                expected: "relaxing music"
            ),
            (
                intent: MusicIntent(
                    action: .play,
                    query: "rock songs of the 90s",
                    shuffleScope: "",
                    artist: "",
                    genre: "rock",
                    mood: "",
                    era: "1990s",
                    version: "",
                    activity: ""
                ),
                expected: "90s rock hits"
            ),
            (
                intent: MusicIntent(
                    action: .play,
                    query: "music while studying",
                    shuffleScope: "",
                    artist: "",
                    genre: "",
                    mood: "",
                    era: "",
                    version: "",
                    activity: "study"
                ),
                expected: "study music"
            ),
        ]

        for item in cases {
            #expect(item.intent.buildSearchQuery() == item.expected)
        }
    }

    @Test("Four-digit years ground their canonical decade")
    func yearGroundsCanonicalEra() {
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

        let grounded = ContentSourceResolver.groundedIntent(
            intent,
            groundingQuery: "play rock from 1995"
        )

        #expect(grounded.era == "1990s")
        #expect(
            ContentSourceResolver.suggestedContentSource(
                for: intent,
                groundingQuery: "play rock from 1995"
            ) == .search
        )
    }

    @Test("Live versions remain grounded beside mood and activity constraints")
    func liveMoodAndActivityRemainGrounded() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "live workout music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "live",
            activity: "workout"
        )

        let grounded = ContentSourceResolver.groundedIntent(intent)

        #expect(grounded.version == "live")
        #expect(grounded.activity == "workout")
        #expect(intent.suggestedContentSource() == .search)
    }

    @Test("Alias-grounded activity preserves a separately explicit mood")
    func aliasActivityDoesNotEraseExplicitMood() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "energetic",
            era: "",
            version: "",
            activity: "workout"
        )

        let grounded = ContentSourceResolver.groundedIntent(
            intent,
            groundingQuery: "play energetic music for exercising"
        )

        #expect(grounded.mood == "energetic")
        #expect(grounded.activity == "workout")
        #expect(
            ContentSourceResolver.suggestedContentSource(
                for: intent,
                groundingQuery: "play energetic music for exercising"
            ) == .search
        )
    }

    @Test("Unknown title-shaped moods remain searches")
    func titleMoodDoesNotForceDiscovery() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Dark",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "dark",
            era: "",
            version: "",
            activity: ""
        )

        let grounded = ContentSourceResolver.groundedIntent(
            intent,
            groundingQuery: "play the song Dark"
        )

        #expect(grounded.mood.isEmpty)
        #expect(
            ContentSourceResolver.suggestedContentSource(
                for: intent,
                groundingQuery: "play the song Dark"
            ) == .search
        )
        #expect(
            ContentSourceResolver.buildSearchQuery(
                from: intent,
                groundingQuery: "play the song Dark"
            ) == "Dark"
        )
    }

    @Test("Alias-grounded mood does not create a duplicate activity dimension")
    func aliasMoodAndQueryActivityRemainCurated() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "workout music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "energetic",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .moodsAndGenres)
    }

    @Test("Activity cleanup preserves title-ending phrases")
    func activityPhraseInSongTitleIsPreserved() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Go to Sleep",
            shuffleScope: "",
            artist: "Radiohead",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "sleep"
        )

        #expect(
            ContentSourceResolver.buildSearchQuery(
                from: intent,
                groundingQuery: "play Go to Sleep by Radiohead while sleeping"
            ) == "Radiohead go to sleep songs"
        )
    }

    @Test("From-artist suffix is removed structurally")
    func fromArtistSuffixIsRemoved() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "songs from the Beatles",
            shuffleScope: "",
            artist: "The Beatles",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.buildSearchQuery() == "The Beatles songs")
    }
}
