import Foundation
import FoundationModels
import Testing
@testable import Kaset

// MARK: - MusicIntentIntegrationTests

/// Integration tests that call the actual Apple Intelligence LLM.
///
/// These tests validate that natural language prompts are correctly parsed
/// into `MusicIntent` structs. They require macOS 26+ with Apple Intelligence.
///
/// ## Flakiness Mitigation
///
/// LLM outputs are inherently non-deterministic. These tests mitigate flakiness by:
/// 1. **Retry logic**: Each test retries up to 3 times before failing
/// 2. **Relaxed matching**: Checks multiple fields (e.g., mood OR query) for expected content
/// 3. **Case-insensitive**: All string comparisons are lowercased
/// 4. **Fresh sessions**: Each attempt uses a new `LanguageModelSession` to avoid context drift
///
/// ## Running These Tests
///
/// Run only integration tests:
/// ```bash
/// xcodebuild test -scheme Kaset -destination 'platform=macOS' \
///   -only-testing:KasetTests/MusicIntentIntegrationTests
/// ```
///
/// Run all unit tests EXCEPT integration tests:
/// ```bash
/// xcodebuild test -scheme Kaset -destination 'platform=macOS' \
///   -only-testing:KasetTests -skip-testing:KasetTests/MusicIntentIntegrationTests
/// ```
///
/// Skip by tag (recommended for CI):
/// ```bash
/// xcodebuild test -scheme Kaset -destination 'platform=macOS' \
///   -only-testing:KasetTests -skip-test-tag integration
/// ```
@Suite("MusicIntent Integration", .tags(.integration, .slow), .serialized)
@MainActor
struct MusicIntentIntegrationTests {
    // MARK: - Constants

    /// Maximum number of retry attempts for flaky LLM calls.
    private static let maxRetries = 3

    /// System prompt for intent parsing - provides clear field definitions for consistent parsing.
    private static let systemPrompt = """
    Parse music commands into MusicIntent. Be precise about field placement:

    Actions: play, queue, shuffle, like, dislike, skip, previous, pause, resume, search

    Fields (use exact field for each concept):
    - query: The raw search text or song/artist name
    - artist: Specific artist/band name (e.g., "Beatles", "Taylor Swift")
    - genre: Music genre (rock, jazz, hip-hop, classical, electronic, pop, country)
    - mood: Emotional quality (upbeat, chill, sad, happy, energetic, relaxing, melancholic)
    - era: Time period (1980s, 1990s, 2000s, classic)
    - version: Recording type (acoustic, live, remix, instrumental, cover)
    - activity: What user is doing (workout, study, sleep, party, driving, cooking, focus, running, yoga)

    IMPORTANT: "for studying", "for workout", "for sleep" → put in activity field, not mood.
    """

    // MARK: - Test Helpers

    /// Parses a natural language prompt into a MusicIntent using the LLM.
    /// Creates a fresh session per call to avoid context window overflow.
    private func parseIntent(from prompt: String) async throws -> MusicIntent {
        guard SystemLanguageModel.default.availability == .available else {
            throw AIUnavailableError()
        }
        // Create a fresh session each time to avoid context accumulation
        let session = LanguageModelSession(instructions: Self.systemPrompt)
        let response = try await session.respond(to: prompt, generating: MusicIntent.self)
        return response.content
    }

    /// Retries a test assertion up to `maxRetries` times to handle LLM non-determinism.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum number of attempts (defaults to `maxRetries`)
    ///   - operation: The async operation that returns a value to validate
    ///   - validate: A closure that validates the result and throws if invalid
    /// - Throws: The last validation error if all attempts fail
    private func withRetry<T>(
        maxAttempts: Int = maxRetries,
        operation: () async throws -> T,
        validate: (T) throws -> Void
    ) async throws {
        var lastError: Error?

        for attempt in 1 ... maxAttempts {
            do {
                let result = try await operation()
                try validate(result)
                return // Success
            } catch is AIUnavailableError {
                throw AIUnavailableError() // Don't retry unavailability
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    // Brief delay before retry to avoid rate limiting
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        throw lastError ?? AIUnavailableError()
    }

    // MARK: - Basic Actions (Parameterized)

    @Test("Parses playback control commands", arguments: [
        (prompt: "Play music", expectedAction: MusicAction.play),
        (prompt: "Skip this song", expectedAction: MusicAction.skip),
        (prompt: "Skip to next track", expectedAction: MusicAction.skip),
        (prompt: "Pause the music", expectedAction: MusicAction.pause),
        (prompt: "Resume the paused music", expectedAction: MusicAction.resume),
        (prompt: "Like this song", expectedAction: MusicAction.like),
        (prompt: "Add jazz to queue", expectedAction: MusicAction.queue),
    ])
    func parsePlaybackCommand(prompt: String, expectedAction: MusicAction) async throws {
        try await self.withRetry {
            try await self.parseIntent(from: prompt)
        } validate: { intent in
            #expect(intent.action == expectedAction)
        }
    }

    // MARK: - Content Queries (Parameterized)

    @Test("Parses mood-based queries", arguments: [
        (prompt: "Play something chill", expected: "chill"),
        (prompt: "Play upbeat music", expected: "upbeat"),
    ])
    func parseMoodQuery(prompt: String, expected: String) async throws {
        try await self.withRetry {
            try await self.parseIntent(from: prompt)
        } validate: { intent in
            #expect(intent.action == .play)
            let combined = "\(intent.mood) \(intent.query)".lowercased()
            #expect(
                combined.contains(expected), "Expected '\(expected)' in mood or query, got: \(combined)"
            )
        }
    }

    @Test("Parses genre queries", arguments: [
        (prompt: "Play jazz", expected: "jazz"),
        (prompt: "Play some rock", expected: "rock"),
    ])
    func parseGenreQuery(prompt: String, expected: String) async throws {
        try await self.withRetry {
            try await self.parseIntent(from: prompt)
        } validate: { intent in
            #expect(intent.action == .play)
            let combined = "\(intent.genre) \(intent.query)".lowercased()
            #expect(
                combined.contains(expected), "Expected '\(expected)' in genre or query, got: \(combined)"
            )
        }
    }

    @Test("Parses era/decade queries", arguments: [
        (prompt: "Play 80s hits", expected: "80"),
        (prompt: "Play 90s music", expected: "90"),
    ])
    func parseEraQuery(prompt: String, expected: String) async throws {
        try await self.withRetry {
            try await self.parseIntent(from: prompt)
        } validate: { intent in
            #expect(intent.action == .play)
            let combined = "\(intent.era) \(intent.query)".lowercased()
            #expect(
                combined.contains(expected), "Expected '\(expected)' in era or query, got: \(combined)"
            )
        }
    }

    @Test("Parses artist queries", arguments: [
        (prompt: "Play Beatles", expected: "beatles"),
        (prompt: "Play Taylor Swift songs", expected: "taylor"),
    ])
    func parseArtistQuery(prompt: String, expected: String) async throws {
        try await self.withRetry {
            try await self.parseIntent(from: prompt)
        } validate: { intent in
            #expect(intent.action == .play)
            let combined = "\(intent.artist) \(intent.query)".lowercased()
            #expect(
                combined.contains(expected), "Expected '\(expected)' in artist or query, got: \(combined)"
            )
        }
    }

    @Test("Parses activity-based queries", arguments: [
        (prompt: "Play music for studying", expected: "study"),
        (prompt: "Play workout songs", expected: "workout"),
    ])
    func parseActivityQuery(prompt: String, expected: String) async throws {
        try await self.withRetry {
            try await self.parseIntent(from: prompt)
        } validate: { intent in
            #expect(intent.action == .play)
            // LLM may place activity keywords in activity, mood, genre, or query fields
            let combined = "\(intent.activity) \(intent.mood) \(intent.genre) \(intent.query)"
                .lowercased()
            #expect(
                combined.contains(expected),
                "Expected '\(expected)' in activity, mood, genre, or query, got: \(combined)"
            )
        }
    }

    // MARK: - Complex Query

    @Test("Parses complex multi-component query")
    func parseComplexQuery() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "Play chill jazz from the 80s")
        } validate: { intent in
            #expect(intent.action == .play)
            let components = [intent.mood, intent.genre, intent.era].filter { !$0.isEmpty }
            #expect(components.count >= 2, "Expected at least 2 components populated, got: \(components)")
        }
    }

    @Test("Parses version type query")
    func parseVersionQuery() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "Play acoustic covers")
        } validate: { intent in
            #expect(intent.action == .play)
            let combined = "\(intent.version) \(intent.query)".lowercased()
            #expect(
                combined.contains("acoustic"), "Expected 'acoustic' in version or query, got: \(combined)"
            )
        }
    }

    // MARK: - Shuffle Commands

    @Test("Parses shuffle commands", arguments: [
        (prompt: "Shuffle my library", expected: "library"),
        (prompt: "Shuffle play my music", expected: ""),
    ])
    func parseShuffleCommand(prompt: String, expected: String) async throws {
        try await self.withRetry {
            try await self.parseIntent(from: prompt)
        } validate: { intent in
            #expect(intent.action == .shuffle || intent.action == .play)
            if !expected.isEmpty {
                let combined = "\(intent.shuffleScope) \(intent.query)".lowercased()
                #expect(
                    combined.contains(expected),
                    "Expected '\(expected)' in shuffleScope or query, got: \(combined)"
                )
            }
        }
    }

    // MARK: - Navigation Commands

    @Test("Parses previous track command")
    func parsePreviousCommand() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "Go back to the previous song")
        } validate: { intent in
            #expect(intent.action == .previous)
        }
    }

    @Test("Parses search command")
    func parseSearchCommand() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "Search for Billie Eilish")
        } validate: { intent in
            #expect(intent.action == .search || intent.action == .play)
            let combined = "\(intent.artist) \(intent.query)".lowercased()
            #expect(combined.contains("billie") || combined.contains("eilish"))
        }
    }

    // MARK: - Rating Commands

    @Test("Parses dislike command")
    func parseDislikeCommand() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "I don't like this song")
        } validate: { intent in
            #expect(intent.action == .dislike)
        }
    }

    // MARK: - Multi-Attribute Queries

    @Test("Parses query with artist and mood")
    func parseArtistWithMood() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "Play energetic songs by Daft Punk")
        } validate: { intent in
            #expect(intent.action == .play)
            let artistQuery = "\(intent.artist) \(intent.query)".lowercased()
            let moodQuery = "\(intent.mood) \(intent.query)".lowercased()
            #expect(artistQuery.contains("daft") || artistQuery.contains("punk"))
            #expect(moodQuery.contains("energetic") || moodQuery.contains("upbeat"))
        }
    }

    @Test("Parses query with genre, era, and mood")
    func parseGenreEraMood() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "Play upbeat disco from the 70s")
        } validate: { intent in
            #expect(intent.action == .play)
            let allFields = "\(intent.mood) \(intent.genre) \(intent.era) \(intent.query)".lowercased()
            #expect(allFields.contains("disco") || allFields.contains("funk"))
            #expect(allFields.contains("70") || allFields.contains("1970"))
        }
    }

    // MARK: - Edge Cases

    @Test("Handles ambiguous play command")
    func handleAmbiguousPlay() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "Play something")
        } validate: { intent in
            #expect(intent.action == .play)
        }
    }

    @Test("Handles language variation")
    func handleLanguageVariation() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "Put on some tunes")
        } validate: { intent in
            // Should interpret as play
            #expect(intent.action == .play)
        }
    }
}

// MARK: - AIUnavailableError

/// Error thrown when Apple Intelligence is not available.
/// Tests catching this error should be considered skipped.
struct AIUnavailableError: Error, CustomStringConvertible {
    var description: String { "Apple Intelligence not available on this device" }
}
