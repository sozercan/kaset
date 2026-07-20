import Testing
@testable import Kaset

@Suite(.serialized)
@MainActor
struct CommandBarDiscoveryRegressionTests {
    @Test("Activity cleanup removes grounded aliases")
    func activityCleanupRemovesGroundedAliases() {
        guard #available(macOS 26.0, *) else { return }

        let cases = [
            (query: "jazz music to work out", activity: "workout", expected: "jazz workout songs"),
            (query: "jazz music to workout", activity: "workout", expected: "jazz workout songs"),
            (query: "jazz music for workouts", activity: "workout", expected: "jazz workout songs"),
            (query: "jazz music to code", activity: "focus", expected: "jazz focus songs"),
            (query: "jazz music while focusing", activity: "focus", expected: "jazz focus songs"),
            (query: "jazz music to drive", activity: "driving", expected: "jazz driving songs"),
            (query: "jazz music to cook", activity: "cooking", expected: "jazz cooking songs"),
        ]

        for item in cases {
            let intent = MusicIntent(
                action: .play,
                query: item.query,
                shuffleScope: "",
                artist: "",
                genre: "jazz",
                mood: "",
                era: "",
                version: "",
                activity: item.activity
            )

            #expect(intent.buildSearchQuery() == item.expected)
        }
    }

    @Test("Self-titled songs preserve both title and artist roles")
    func selfTitledSongPreservesTitleAndArtist() {
        guard #available(macOS 26.0, *) else { return }

        let intent = MusicIntent(
            action: .play,
            query: "Black Sabbath by Black Sabbath",
            shuffleScope: "",
            artist: "Black Sabbath",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )
        #expect(
            ContentSourceResolver.buildSearchQuery(
                from: intent,
                groundingQuery: "play Black Sabbath by Black Sabbath"
            ) == "Black Sabbath black sabbath songs"
        )
    }

    @Test("Activity evidence must come from recognized context")
    func activityEvidenceIsContextBound() {
        guard #available(macOS 26.0, *) else { return }

        let collisions = [
            (query: "Drive", activity: "driving", original: "play Drive while studying"),
            (query: "Drive", activity: "driving", original: "play Drive and study music"),
            (query: "Drive", activity: "driving", original: "while studying play Drive"),
            (query: "Drive", activity: "driving", original: "play Drive with music to relax"),
            (query: "Born to Run", activity: "running", original: "while studying play Born to Run"),
        ]

        for item in collisions {
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
            let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: item.original)

            #expect(grounded.activity.isEmpty)
            #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: item.original) == .search)
            #expect(ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: item.original) == item.query)
        }

        let positiveCases = [
            (activity: "driving", original: "play music for commuting"),
            (activity: "driving", original: "play music to drive"),
            (activity: "driving", original: "play driving music"),
            (activity: "workout", original: "play music for a workout"),
        ]

        for item in positiveCases {
            let intent = MusicIntent(
                action: .play,
                query: "music",
                shuffleScope: "",
                artist: "",
                genre: "",
                mood: "",
                era: "",
                version: "",
                activity: item.activity
            )
            let grounded = ContentSourceResolver.groundedIntent(intent, groundingQuery: item.original)

            #expect(grounded.activity == item.activity)
            #expect(ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: item.original) == .moodsAndGenres)
        }
    }
}
