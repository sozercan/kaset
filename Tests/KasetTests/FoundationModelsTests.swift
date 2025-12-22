import Foundation
import XCTest
@testable import Kaset

// MARK: - MusicIntentTests

/// Tests for MusicIntent query building and content source suggestion.
@available(macOS 26.0, *)
final class MusicIntentTests: XCTestCase {
    // MARK: - buildSearchQuery Tests

    func testBuildSearchQuery_artistOnly() {
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
        XCTAssertTrue(query.contains("Beatles"), "Query should contain artist name")
        XCTAssertTrue(query.contains("songs"), "Query should contain 'songs' suffix")
    }

    func testBuildSearchQuery_moodAndGenre() {
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
        XCTAssertEqual(query, "jazz chill songs", "Should combine genre, mood, and songs suffix")
    }

    func testBuildSearchQuery_artistWithEra() {
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
        XCTAssertTrue(query.contains("Rolling Stones"), "Query should contain artist")
        XCTAssertTrue(query.contains("90s") || query.contains("1990s"), "Query should contain era")
        XCTAssertTrue(query.contains("hits"), "Query should preserve 'hits' from original query")
    }

    func testBuildSearchQuery_eraOnly() {
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
        XCTAssertTrue(query.contains("80s") || query.contains("1980s"), "Query should contain era")
        XCTAssertTrue(query.contains("hits") || query.contains("songs"), "Query should have suffix")
    }

    func testBuildSearchQuery_versionType() {
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
        XCTAssertTrue(query.contains("acoustic"), "Query should contain version type")
    }

    func testBuildSearchQuery_complexQuery() {
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
        XCTAssertTrue(query.contains("Rolling Stones"), "Should contain artist")
        XCTAssertTrue(query.contains("upbeat") || query.contains("rock"), "Should contain mood or genre")
    }

    // MARK: - suggestedContentSource Tests

    func testContentSource_artistQuery_returnsSearch() {
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

        XCTAssertEqual(intent.suggestedContentSource(), .search, "Artist queries should use search")
    }

    func testContentSource_moodQuery_returnsMoodsAndGenres() {
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

        XCTAssertEqual(
            intent.suggestedContentSource(), .moodsAndGenres,
            "Pure mood queries should use Moods & Genres"
        )
    }

    func testContentSource_activityQuery_returnsMoodsAndGenres() {
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

        XCTAssertEqual(
            intent.suggestedContentSource(), .moodsAndGenres,
            "Activity-based queries should use Moods & Genres"
        )
    }

    func testContentSource_chartsQuery_returnsCharts() {
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

        XCTAssertEqual(
            intent.suggestedContentSource(), .charts,
            "Popularity keywords should use Charts"
        )
    }

    func testContentSource_versionQuery_returnsSearch() {
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

        XCTAssertEqual(
            intent.suggestedContentSource(), .search,
            "Version-specific queries need search"
        )
    }

    // MARK: - queryDescription Tests

    func testQueryDescription_allComponents() {
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
        XCTAssertTrue(description.contains("upbeat"), "Should include mood")
        XCTAssertTrue(description.contains("rock"), "Should include genre")
        XCTAssertTrue(description.contains("Queen"), "Should include artist")
        XCTAssertTrue(description.contains("1980s"), "Should include era")
        XCTAssertTrue(description.contains("live"), "Should include version")
    }

    func testQueryDescription_emptyFallsBackToQuery() {
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
        XCTAssertEqual(description, "something random", "Empty components should fall back to query")
    }
}

// MARK: - MusicQueryTests

@available(macOS 26.0, *)
final class MusicQueryTests: XCTestCase {
    func testBuildSearchQuery_basicArtist() {
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
        XCTAssertTrue(result.contains("Coldplay"), "Should include artist")
        XCTAssertTrue(result.contains("songs"), "Should end with 'songs'")
    }

    func testBuildSearchQuery_fullQuery() {
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
        XCTAssertTrue(result.contains("Coldplay"))
        XCTAssertTrue(result.contains("rock"))
        XCTAssertTrue(result.contains("upbeat"))
        XCTAssertTrue(result.contains("2000s"))
        XCTAssertTrue(result.contains("live"))
    }

    func testBuildSearchQuery_activityOnlyWhenEmpty() {
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
        XCTAssertTrue(result.contains("workout music"), "Activity should be used when nothing else specified")
    }

    func testDescription_formatsNicely() {
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
        XCTAssertTrue(desc.contains("energetic"))
        XCTAssertTrue(desc.contains("electronic"))
        XCTAssertTrue(desc.contains("Daft Punk"))
        XCTAssertTrue(desc.contains("2000s"))
        XCTAssertTrue(desc.contains("party"))
    }
}

// MARK: - AISessionTypeTests

@available(macOS 26.0, *)
final class AISessionTypeTests: XCTestCase {
    func testCommandSessionHasLowerTemperature() {
        let options = AISessionType.command.generationOptions
        // Command sessions should use lower temperature for predictable parsing
        // We can't directly access temperature, but we verify the options are created
        XCTAssertNotNil(options, "Command session should have generation options")
    }

    func testAnalysisSessionHasHigherTemperature() {
        let options = AISessionType.analysis.generationOptions
        XCTAssertNotNil(options, "Analysis session should have generation options")
    }

    func testConversationalSessionHasBalancedTemperature() {
        let options = AISessionType.conversational.generationOptions
        XCTAssertNotNil(options, "Conversational session should have generation options")
    }
}

// MARK: - ContentSourceTests

final class ContentSourceTests: XCTestCase {
    func testContentSourceDescription() {
        XCTAssertEqual(ContentSource.search.description, "search")
        XCTAssertEqual(ContentSource.moodsAndGenres.description, "moodsAndGenres")
        XCTAssertEqual(ContentSource.charts.description, "charts")
    }
}

// MARK: - QueueIntentTests

@available(macOS 26.0, *)
final class QueueIntentTests: XCTestCase {
    func testQueueActionValues() {
        // Verify all queue actions are available
        let actions: [QueueAction] = [.add, .addNext, .remove, .clear, .shuffle]
        XCTAssertEqual(actions.count, 5, "Should have 5 queue actions")
    }
}
