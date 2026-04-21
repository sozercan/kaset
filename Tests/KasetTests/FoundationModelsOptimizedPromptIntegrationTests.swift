import Foundation
import FoundationModels
import Testing
@testable import Kaset

private let optimizedPromptIntegrationEnabled: Bool = {
    if #available(macOS 26.4, *) {
        return SystemLanguageModel.default.availability == .available
    }
    return false
}()

// MARK: - FoundationModelsOptimizedPromptIntegrationTests

/// Integration tests that exercise the actual 26.4+ prompt library against the on-device model.
///
/// These tests focus on the optimized prompts Kaset ships, rather than generic schema-only prompts.
/// They are intentionally narrow so we can validate the main 26.4 behavior changes with low flakiness.
@Suite(
    .tags(.integration, .slow),
    .serialized,
    .timeLimit(.minutes(2)),
    .enabled(if: optimizedPromptIntegrationEnabled, "macOS 26.4+ Apple Intelligence required")
)
@MainActor
struct FoundationModelsOptimizedPromptIntegrationTests {
    private static let maxRetries = 3

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
                return
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        throw lastError!
    }

    private func optimizedCommandIntent(for prompt: String) async throws -> CommandBarParseResult {
        let session = LanguageModelSession(
            instructions: FoundationModelsPromptLibrary.commandBarInstructions(
                version: .optimized26_4AndLater
            )
        )
        let response = try await session.respond(to: prompt, generating: CommandBarParseResult.self)
        return response.content
    }

    private func optimizedLyricsSummary(lyrics: String) async throws -> LyricsSummary {
        let instructions = FoundationModelsPromptLibrary.lyricsExplanationInstructions(
            version: .optimized26_4AndLater
        )
        let prompt = FoundationModelsPromptLibrary.lyricsExplanationPrompt(
            trackTitle: "Example Song",
            artistsDisplay: "Kaset Test Artist",
            lyrics: lyrics,
            version: .optimized26_4AndLater
        )

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: LyricsSummary.self)
        return response.content
    }

    private func optimizedPlaylistChanges(request: String, tracks: [Song]) async throws -> PlaylistChanges {
        let instructions = FoundationModelsPromptLibrary.playlistRefinementInstructions(
            version: .optimized26_4AndLater
        )
        let trackList = FoundationModelsPromptLibrary.playlistTrackList(from: tracks, limit: tracks.count)
        let prompt = FoundationModelsPromptLibrary.playlistRefinementPrompt(
            trackList: trackList,
            totalTracks: tracks.count,
            shownTracks: tracks.count,
            request: request,
            version: .optimized26_4AndLater
        )

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: PlaylistChanges.self)
        return response.content.normalized(forOriginalTrackIds: tracks.map(\.videoId))
    }

    private func optimizedQueueAnalysis(
        tracks: [Song],
        currentIndex: Int,
        isPlaying: Bool
    ) async throws -> QueueAnalysisSummary {
        let instructions = FoundationModelsPromptLibrary.queueDescriptionInstructions(
            version: .optimized26_4AndLater
        )
        let trackLines = FoundationModelsPromptLibrary.queueTrackLines(
            from: tracks,
            currentIndex: currentIndex,
            isPlaying: isPlaying,
            limit: tracks.count
        )
        let prompt = FoundationModelsPromptLibrary.queueDescriptionPrompt(
            trackList: trackLines.joined(separator: "\n"),
            totalTracks: tracks.count,
            shownTracks: trackLines.count,
            version: .optimized26_4AndLater
        )

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: QueueAnalysisSummary.self)
        return response.content
    }

    private var samplePlaylistTracks: [Song] {
        [
            Song(
                id: "track-1",
                title: "Daylight Drive",
                artists: [Artist(id: "artist-1", name: "North Harbor")],
                videoId: "video-1"
            ),
            Song(
                id: "track-2",
                title: "Afterglow",
                artists: [Artist(id: "artist-2", name: "Static Bloom")],
                videoId: "video-2"
            ),
            Song(
                id: "track-3",
                title: "Night Swimming",
                artists: [Artist(id: "artist-3", name: "Glass Avenue")],
                videoId: "video-3"
            ),
        ]
    }

    @Test("26.4 command prompt handles explicit search requests")
    func optimizedCommandPromptHandlesExplicitSearchRequests() async throws {
        try await self.withRetry {
            try await self.optimizedCommandIntent(for: "Search for Billie Eilish")
        } validate: { intent in
            #expect(intent.action == .search || intent.action == .play)
            let combined = "\(intent.artist) \(intent.subject)".lowercased()
            #expect(
                combined.contains("billie") || combined.contains("eilish"),
                "Expected Billie Eilish in artist or subject, got: \(combined)"
            )
        }
    }

    @Test("26.4 command prompt uses the dedicated clear-queue action")
    func optimizedCommandPromptUsesDedicatedClearQueueAction() async throws {
        try await self.withRetry {
            try await self.optimizedCommandIntent(for: "Clear queue")
        } validate: { intent in
            #expect(intent.action == .clearQueue)
        }
    }

    @Test("26.4 command prompt supports explicit queue inspection")
    func optimizedCommandPromptSupportsQueueInspection() async throws {
        try await self.withRetry {
            try await self.optimizedCommandIntent(for: "What's in my queue?")
        } validate: { intent in
            #expect(intent.action == .inspectQueue)
        }
    }

    @Test("26.4 lyrics prompt still decodes structured summaries")
    func optimizedLyricsPromptProducesStructuredSummary() async throws {
        let lyrics = """
        We drove until the streetlights blurred into the rain.
        You laughed and said tomorrow could start again.
        I kept the quiet like a match against the dark.
        """

        try await self.withRetry {
            try await self.optimizedLyricsSummary(lyrics: lyrics)
        } validate: { summary in
            #expect(summary.themes.count >= 2)
            #expect(summary.themes.count <= 5)
            #expect(!summary.mood.isEmpty)
            #expect(!summary.explanation.isEmpty)
        }
    }

    @Test("26.4 playlist prompt keeps reasoning in structured output")
    func optimizedPlaylistPromptKeepsReasoningInStructuredOutput() async throws {
        try await self.withRetry {
            try await self.optimizedPlaylistChanges(
                request: "Keep every track. Do not remove anything. Do not reorder the playlist.",
                tracks: self.samplePlaylistTracks
            )
        } validate: { changes in
            #expect(changes.removals.isEmpty)
            if let reorderedIds = changes.reorderedIds {
                #expect(reorderedIds == self.samplePlaylistTracks.map(\.videoId))
            }
            #expect(!changes.reasoning.isEmpty)
        }
    }

    @Test("26.4 queue prompt produces structured analysis")
    func optimizedQueuePromptProducesStructuredAnalysis() async throws {
        try await self.withRetry {
            try await self.optimizedQueueAnalysis(
                tracks: self.samplePlaylistTracks,
                currentIndex: 1,
                isPlaying: true
            )
        } validate: { analysis in
            #expect(!analysis.opening.isEmpty)
            #expect(!analysis.vibe.isEmpty)
            #expect(!analysis.summary.isEmpty)
            #expect(!analysis.highlights.isEmpty)

            let combined = ([analysis.opening, analysis.vibe, analysis.summary] + analysis.highlights)
                .joined(separator: " ")
                .lowercased()
            let expectedCallouts = [
                "daylight drive",
                "north harbor",
                "afterglow",
                "static bloom",
                "night swimming",
                "glass avenue",
            ]
            #expect(expectedCallouts.contains(where: combined.contains))
        }
    }
}
