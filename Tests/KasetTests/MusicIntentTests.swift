import Foundation
import Testing
@testable import Kaset

// MARK: - MusicIntentTests

/// Tests for MusicIntent query building and parsing logic.
@Suite("MusicIntent", .tags(.api))
struct MusicIntentTests {
    // MARK: - buildSearchQuery Tests

    @Test("Simple query returns query as-is")
    func simpleQueryReturnsAsIs() {
        let intent = MusicIntent(
            action: .play,
            query: "bohemian rhapsody",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        let result = intent.buildSearchQuery()
        #expect(result == "bohemian rhapsody")
    }

    @Test("Artist-only query builds correctly")
    func artistOnlyQuery() {
        let intent = MusicIntent(
            action: .play,
            query: "rolling stones",
            shuffleScope: "",
            artist: "Rolling Stones",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        let result = intent.buildSearchQuery()
        #expect(result.contains("Rolling Stones"))
        #expect(result.contains("songs"))
    }

    @Test("Artist with era builds correctly")
    func artistWithEra() {
        let intent = MusicIntent(
            action: .play,
            query: "rolling stones 90s hits",
            shuffleScope: "",
            artist: "Rolling Stones",
            genre: "",
            mood: "",
            era: "1990s",
            version: "",
            activity: ""
        )

        let result = intent.buildSearchQuery()
        #expect(result.contains("Rolling Stones"))
        #expect(result.contains("90s"))
    }

    @Test("Artist with 'hits' in query adds greatest hits")
    func artistWithHitsKeyword() {
        let intent = MusicIntent(
            action: .play,
            query: "best of queen",
            shuffleScope: "",
            artist: "Queen",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        let result = intent.buildSearchQuery()
        #expect(result.contains("Queen"))
        #expect(result.contains("greatest hits"))
    }

    @Test("Era-only query adds hits suffix")
    func eraOnlyQuery() {
        let intent = MusicIntent(
            action: .play,
            query: "80s music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "1980s",
            version: "",
            activity: ""
        )

        let result = intent.buildSearchQuery()
        #expect(result.contains("80s"))
        #expect(result.contains("hits"))
    }

    @Test("Era normalizes decade format")
    func eraNormalizesDecade() {
        let intent = MusicIntent(
            action: .play,
            query: "1970s rock",
            shuffleScope: "",
            artist: "",
            genre: "rock",
            mood: "",
            era: "1970s",
            version: "",
            activity: ""
        )

        let result = intent.buildSearchQuery()
        #expect(result.contains("70s"))
    }

    @Test("Mood-only query adds music suffix")
    func moodOnlyQuery() {
        let intent = MusicIntent(
            action: .play,
            query: "chill vibes",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "chill",
            era: "",
            version: "",
            activity: ""
        )

        let result = intent.buildSearchQuery()
        #expect(result.contains("chill"))
        #expect(result.contains("music"))
    }

    @Test("Genre and mood combination")
    func genreAndMoodCombination() {
        let intent = MusicIntent(
            action: .play,
            query: "upbeat jazz",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "upbeat",
            era: "",
            version: "",
            activity: ""
        )

        let result = intent.buildSearchQuery()
        #expect(result.contains("jazz"))
        #expect(result.contains("upbeat"))
        #expect(result.contains("songs"))
    }

    @Test("Version type is included")
    func versionTypeIncluded() {
        let intent = MusicIntent(
            action: .play,
            query: "acoustic covers",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "acoustic",
            activity: ""
        )

        let result = intent.buildSearchQuery()
        #expect(result.contains("acoustic"))
    }

    @Test("Activity-only query adds music suffix")
    func activityOnlyQuery() {
        let intent = MusicIntent(
            action: .play,
            query: "music for studying",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "study"
        )

        let result = intent.buildSearchQuery()
        #expect(result.contains("study") || result.contains("music"))
    }

    @Test("Complex query with multiple components")
    func complexQueryMultipleComponents() {
        let intent = MusicIntent(
            action: .play,
            query: "upbeat rock songs from the 80s",
            shuffleScope: "",
            artist: "",
            genre: "rock",
            mood: "upbeat",
            era: "1980s",
            version: "",
            activity: ""
        )

        let result = intent.buildSearchQuery()
        #expect(result.contains("80s"))
        #expect(result.contains("rock") || result.contains("upbeat"))
    }

    // MARK: - queryDescription Tests

    @Test("queryDescription returns mood and genre")
    func queryDescriptionMoodAndGenre() {
        let intent = MusicIntent(
            action: .play,
            query: "chill jazz",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "chill",
            era: "",
            version: "",
            activity: ""
        )

        let description = intent.queryDescription()
        #expect(description.contains("chill"))
        #expect(description.contains("jazz"))
    }

    @Test("queryDescription includes artist with 'by'")
    func queryDescriptionWithArtist() {
        let intent = MusicIntent(
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

        let description = intent.queryDescription()
        #expect(description.contains("by Beatles"))
    }

    @Test("queryDescription includes era with 'from the'")
    func queryDescriptionWithEra() {
        let intent = MusicIntent(
            action: .play,
            query: "90s pop",
            shuffleScope: "",
            artist: "",
            genre: "pop",
            mood: "",
            era: "1990s",
            version: "",
            activity: ""
        )

        let description = intent.queryDescription()
        #expect(description.contains("from the 1990s"))
    }

    @Test("queryDescription falls back to query when empty")
    func queryDescriptionFallback() {
        let intent = MusicIntent(
            action: .play,
            query: "some random search",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        let description = intent.queryDescription()
        #expect(description == "some random search")
    }

    // MARK: - suggestedContentSource Tests

    @Test("Artist-specific query suggests search")
    func artistSpecificSuggestsSearch() {
        let intent = MusicIntent(
            action: .play,
            query: "Taylor Swift",
            shuffleScope: "",
            artist: "Taylor Swift",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .search)
    }

    @Test("Version-specific query suggests search")
    func versionSpecificSuggestsSearch() {
        let intent = MusicIntent(
            action: .play,
            query: "acoustic covers",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "acoustic",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .search)
    }

    @Test("Popularity keywords suggest charts")
    func popularityKeywordsSuggestCharts() {
        let intent = MusicIntent(
            action: .play,
            query: "top hits",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .charts)
    }

    @Test("Mood-only query suggests moodsAndGenres")
    func moodOnlySuggestsMoodsAndGenres() {
        let intent = MusicIntent(
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

        #expect(intent.suggestedContentSource() == .moodsAndGenres)
    }

    @Test("Activity-based query suggests moodsAndGenres")
    func activitySuggestsMoodsAndGenres() {
        let intent = MusicIntent(
            action: .play,
            query: "workout music",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: "workout"
        )

        #expect(intent.suggestedContentSource() == .moodsAndGenres)
    }

    @Test("Genre-only query suggests moodsAndGenres")
    func genreOnlySuggestsMoodsAndGenres() {
        let intent = MusicIntent(
            action: .play,
            query: "jazz music",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .moodsAndGenres)
    }

    @Test("Default content source is search")
    func defaultContentSourceIsSearch() {
        let intent = MusicIntent(
            action: .play,
            query: "random query",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .search)
    }
}

// MARK: - MusicActionTests

@Suite("MusicAction", .tags(.api))
struct MusicActionTests {
    @Test("All action cases have raw values")
    func allActionsHaveRawValues() {
        for action in MusicAction.allCases {
            #expect(!action.rawValue.isEmpty)
        }
    }

    @Test("Action count is correct")
    func actionCountIsCorrect() {
        #expect(MusicAction.allCases.count == 10)
    }
}

// MARK: - ContentSourceTests

@Suite("ContentSource", .tags(.api))
struct ContentSourceTests {
    @Test("ContentSource has correct raw values")
    func contentSourceRawValues() {
        #expect(ContentSource.search.rawValue == "search")
        #expect(ContentSource.moodsAndGenres.rawValue == "moodsAndGenres")
        #expect(ContentSource.charts.rawValue == "charts")
    }

    @Test("ContentSource description matches raw value")
    func contentSourceDescription() {
        #expect(ContentSource.search.description == "search")
        #expect(ContentSource.moodsAndGenres.description == "moodsAndGenres")
        #expect(ContentSource.charts.description == "charts")
    }
}
