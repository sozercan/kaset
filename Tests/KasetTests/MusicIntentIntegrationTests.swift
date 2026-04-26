import Foundation
import FoundationModels
import Testing
@testable import Kaset

// MARK: - MusicIntentIntegrationTests

/// Integration tests that call the actual Apple Intelligence LLM.
///
/// These tests validate that natural language prompts are correctly parsed
/// into the production command-bar stage-1 parse schema. They require macOS 26+
/// with Apple Intelligence.
///
/// ## Flakiness Mitigation
///
/// LLM outputs are inherently non-deterministic. These tests mitigate flakiness by:
/// 1. **Retry logic**: Each test retries up to 3 times before failing
/// 2. **Relaxed matching**: Checks multiple fields (e.g., mood OR subject) for expected content
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
/// Run all unit tests (integration tests auto-skip if AI unavailable):
/// ```bash
/// xcodebuild test -scheme Kaset -destination 'platform=macOS' \
///   -only-testing:KasetTests
/// ```
@Suite(
    .tags(.integration, .slow),
    .serialized,
    .enabled(if: SystemLanguageModel.default.availability == .available, "Apple Intelligence required")
)
@MainActor
struct MusicIntentIntegrationTests {
    // MARK: - Constants

    /// Maximum number of retry attempts for flaky LLM calls.
    private static let maxRetries = 3

    // MARK: - Test Helpers

    /// Parses a natural language prompt into a `CommandBarParseResult` using the shipped prompt.
    /// Creates a fresh session per call to avoid context window overflow.
    private func parseIntent(from prompt: String) async throws -> CommandBarParseResult {
        let session = LanguageModelSession(
            instructions: FoundationModelsPromptLibrary.commandBarInstructions(
                version: .current
            )
        )
        let response = try await session.respond(to: prompt, generating: CommandBarParseResult.self)
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
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    // Brief delay before retry to avoid rate limiting
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        throw lastError!
    }

    // MARK: - Basic Actions (Parameterized)

    @Test("Parses playback control commands", arguments: [
        (prompt: "Play music", expectedAction: CommandBarAction.play),
        (prompt: "Skip this song", expectedAction: CommandBarAction.skip),
        (prompt: "Skip to next track", expectedAction: CommandBarAction.skip),
        (prompt: "Pause the music", expectedAction: CommandBarAction.pause),
        (prompt: "Resume the paused music", expectedAction: CommandBarAction.resume),
        (prompt: "Like this song", expectedAction: CommandBarAction.like),
        (prompt: "Add jazz to queue", expectedAction: CommandBarAction.queue),
    ])
    func parsePlaybackCommand(prompt: String, expectedAction: CommandBarAction) async throws {
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
            let combined = "\(intent.mood) \(intent.subject)".lowercased()
            #expect(
                combined.contains(expected), "Expected '\(expected)' in mood or subject, got: \(combined)"
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
            let combined = "\(intent.genre) \(intent.subject)".lowercased()
            #expect(
                combined.contains(expected), "Expected '\(expected)' in genre or subject, got: \(combined)"
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
            let combined = "\(intent.era) \(intent.subject)".lowercased()
            #expect(
                combined.contains(expected), "Expected '\(expected)' in era or subject, got: \(combined)"
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
            let combined = "\(intent.artist) \(intent.subject)".lowercased()
            #expect(
                combined.contains(expected), "Expected '\(expected)' in artist or subject, got: \(combined)"
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
            // LLM may place activity keywords in activity, mood, genre, or subject fields
            let combined = "\(intent.activity) \(intent.mood) \(intent.genre) \(intent.subject)"
                .lowercased()
            #expect(
                combined.contains(expected),
                "Expected '\(expected)' in activity, mood, genre, or subject, got: \(combined)"
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
            let combined = "\(intent.version) \(intent.subject)".lowercased()
            #expect(
                combined.contains("acoustic"), "Expected 'acoustic' in version or subject, got: \(combined)"
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
                let combined = "\(intent.shuffleScope) \(intent.subject)".lowercased()
                #expect(
                    combined.contains(expected),
                    "Expected '\(expected)' in shuffleScope or subject, got: \(combined)"
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
            let combined = "\(intent.artist) \(intent.subject)".lowercased()
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
            let artistQuery = "\(intent.artist) \(intent.subject)".lowercased()
            let moodQuery = "\(intent.mood) \(intent.subject)".lowercased()
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
            let allFields = "\(intent.mood) \(intent.genre) \(intent.era) \(intent.subject)".lowercased()
            #expect(allFields.contains("disco") || allFields.contains("funk"))
            #expect(allFields.contains("70") || allFields.contains("1970"))
        }
    }

    @Test("Parses queue inspection into the explicit read-only action")
    func parseQueueInspectionCommand() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "What's in my queue?")
        } validate: { intent in
            #expect(intent.action == .inspectQueue)
        }
    }

    @Test("Parses clear queue into the dedicated destructive action")
    func parseClearQueueCommand() async throws {
        try await self.withRetry {
            try await self.parseIntent(from: "Clear queue")
        } validate: { intent in
            #expect(intent.action == .clearQueue)
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
