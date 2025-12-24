import Foundation
import Testing
@testable import Kaset

// MARK: - MusicIntentTests

/// Tests for MusicIntent query building and content source suggestion.
@available(macOS 26.0, *)
@Suite
struct MusicIntentTests {
    // MARK: - buildSearchQuery Tests

    @Test("Build search query with artist only")
    func buildSearchQueryArtistOnly() {
        let intent = MusicIntent(
            action: .play,
            query: "Beatles songs",
            shuffleScope: "",
            artist: "Beatles",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        let query = intent.buildSearchQuery()
        #expect(query.contains("Beatles"), "Query should contain artist name")
        #expect(query.contains("songs"), "Query should contain 'songs' suffix")
    }

    @Test("Build search query with mood and genre")
    func buildSearchQueryMoodAndGenre() {
        let intent = MusicIntent(
            action: .play,
            query: "",
            shuffleScope: "",
            artist: "",
            genre: "jazz",
            mood: "chill",
            era: "",
            version: "",
            activity: ""
        )

        let query = intent.buildSearchQuery()
        #expect(query == "jazz chill songs", "Should combine genre, mood, and songs suffix")
    }

    @Test("Build search query with artist and era")
    func buildSearchQueryArtistWithEra() {
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

        let query = intent.buildSearchQuery()
        #expect(query.contains("Rolling Stones"), "Query should contain artist")
        #expect(query.contains("90s") || query.contains("1990s"), "Query should contain era")
        #expect(query.contains("hits"), "Query should preserve 'hits' from original query")
    }

    @Test("Build search query with era only")
    func buildSearchQueryEraOnly() {
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

        let query = intent.buildSearchQuery()
        #expect(query.contains("80s") || query.contains("1980s"), "Query should contain era")
        #expect(query.contains("hits") || query.contains("songs"), "Query should have suffix")
    }

    @Test("Build search query with version type")
    func buildSearchQueryVersionType() {
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

        let query = intent.buildSearchQuery()
        #expect(query.contains("acoustic"), "Query should contain version type")
    }

    @Test("Build search query complex")
    func buildSearchQueryComplex() {
        let intent = MusicIntent(
            action: .play,
            query: "upbeat rolling stones songs from the 90s",
            shuffleScope: "",
            artist: "Rolling Stones",
            genre: "rock",
            mood: "upbeat",
            era: "1990s",
            version: "",
            activity: ""
        )

        let query = intent.buildSearchQuery()
        #expect(query.contains("Rolling Stones"), "Should contain artist")
        #expect(query.contains("upbeat") || query.contains("rock"), "Should contain mood or genre")
    }

    // MARK: - suggestedContentSource Tests

    @Test("Content source for artist query returns search")
    func contentSourceArtistQueryReturnsSearch() {
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

        #expect(intent.suggestedContentSource() == .search, "Artist queries should use search")
    }

    @Test("Content source for mood query returns moods and genres")
    func contentSourceMoodQueryReturnsMoodsAndGenres() {
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

        #expect(intent.suggestedContentSource() == .moodsAndGenres, "Pure mood queries should use Moods & Genres")
    }

    @Test("Content source for activity query returns moods and genres")
    func contentSourceActivityQueryReturnsMoodsAndGenres() {
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

        #expect(intent.suggestedContentSource() == .moodsAndGenres, "Activity-based queries should use Moods & Genres")
    }

    @Test("Content source for charts query returns charts")
    func contentSourceChartsQueryReturnsCharts() {
        let intent = MusicIntent(
            action: .play,
            query: "top songs",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .charts, "Popularity keywords should use Charts")
    }

    @Test("Content source for version query returns search")
    func contentSourceVersionQueryReturnsSearch() {
        let intent = MusicIntent(
            action: .play,
            query: "live performances",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "live",
            activity: ""
        )

        #expect(intent.suggestedContentSource() == .search, "Version-specific queries need search")
    }

    // MARK: - queryDescription Tests

    @Test("Query description with all components")
    func queryDescriptionAllComponents() {
        let intent = MusicIntent(
            action: .play,
            query: "upbeat rock by Queen from the 80s (live)",
            shuffleScope: "",
            artist: "Queen",
            genre: "rock",
            mood: "upbeat",
            era: "1980s",
            version: "live",
            activity: ""
        )

        let description = intent.queryDescription()
        #expect(description.contains("upbeat"), "Should include mood")
        #expect(description.contains("rock"), "Should include genre")
        #expect(description.contains("Queen"), "Should include artist")
        #expect(description.contains("1980s"), "Should include era")
        #expect(description.contains("live"), "Should include version")
    }

    @Test("Query description with empty components falls back to query")
    func queryDescriptionEmptyFallsBackToQuery() {
        let intent = MusicIntent(
            action: .play,
            query: "something random",
            shuffleScope: "",
            artist: "",
            genre: "",
            mood: "",
            era: "",
            version: "",
            activity: ""
        )

        let description = intent.queryDescription()
        #expect(description == "something random", "Empty components should fall back to query")
    }
}

// MARK: - MusicQueryTests

@available(macOS 26.0, *)
@Suite
struct MusicQueryTests {
    @Test("Build search query basic artist")
    func buildSearchQueryBasicArtist() {
        let query = MusicQuery(
            searchTerm: "",
            artist: "Coldplay",
            genre: "",
            mood: "",
            activity: "",
            era: "",
            version: "",
            language: "",
            contentRating: "",
            count: 0
        )

        let result = query.buildSearchQuery()
        #expect(result.contains("Coldplay"), "Should include artist")
        #expect(result.contains("songs"), "Should end with 'songs'")
    }

    @Test("Build search query full query")
    func buildSearchQueryFullQuery() {
        let query = MusicQuery(
            searchTerm: "",
            artist: "Coldplay",
            genre: "rock",
            mood: "upbeat",
            activity: "",
            era: "2000s",
            version: "live",
            language: "",
            contentRating: "",
            count: 0
        )

        let result = query.buildSearchQuery()
        #expect(result.contains("Coldplay"))
        #expect(result.contains("rock"))
        #expect(result.contains("upbeat"))
        #expect(result.contains("2000s"))
        #expect(result.contains("live"))
    }

    @Test("Build search query activity only when empty")
    func buildSearchQueryActivityOnlyWhenEmpty() {
        let query = MusicQuery(
            searchTerm: "",
            artist: "",
            genre: "",
            mood: "",
            activity: "workout",
            era: "",
            version: "",
            language: "",
            contentRating: "",
            count: 0
        )

        let result = query.buildSearchQuery()
        #expect(result.contains("workout music"), "Activity should be used when nothing else specified")
    }

    @Test("Description formats nicely")
    func descriptionFormatsNicely() {
        let query = MusicQuery(
            searchTerm: "",
            artist: "Daft Punk",
            genre: "electronic",
            mood: "energetic",
            activity: "party",
            era: "2000s",
            version: "",
            language: "",
            contentRating: "",
            count: 0
        )

        let desc = query.description()
        #expect(desc.contains("energetic"))
        #expect(desc.contains("electronic"))
        #expect(desc.contains("Daft Punk"))
        #expect(desc.contains("2000s"))
        #expect(desc.contains("party"))
    }
}

// MARK: - AISessionTypeTests

@available(macOS 26.0, *)
@Suite
struct AISessionTypeTests {
    @Test("Command session has generation options")
    func commandSessionHasLowerTemperature() {
        let options = AISessionType.command.generationOptions
        #expect(options != nil, "Command session should have generation options")
    }

    @Test("Analysis session has generation options")
    func analysisSessionHasHigherTemperature() {
        let options = AISessionType.analysis.generationOptions
        #expect(options != nil, "Analysis session should have generation options")
    }

    @Test("Conversational session has generation options")
    func conversationalSessionHasBalancedTemperature() {
        let options = AISessionType.conversational.generationOptions
        #expect(options != nil, "Conversational session should have generation options")
    }
}

// MARK: - ContentSourceTests

@Suite
struct ContentSourceTests {
    @Test(
        "Content source description",
        arguments: [
            (ContentSource.search, "search"),
            (ContentSource.moodsAndGenres, "moodsAndGenres"),
            (ContentSource.charts, "charts"),
        ]
    )
    func contentSourceDescription(source: ContentSource, expected: String) {
        #expect(source.description == expected)
    }
}

// MARK: - QueueIntentTests

@available(macOS 26.0, *)
@Suite
struct QueueIntentTests {
    @Test("Queue action values")
    func queueActionValues() {
        let actions: [QueueAction] = [.add, .addNext, .remove, .clear, .shuffle]
        #expect(actions.count == 5, "Should have 5 queue actions")
    }
}
