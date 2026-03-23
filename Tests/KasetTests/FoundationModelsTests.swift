import Foundation
import Testing
@testable import Kaset

// MARK: - PlaylistChangesTests

@Suite("PlaylistChanges Unit", .tags(.model))
struct PlaylistChangesTests {
    @Test("PlaylistChanges with empty removals")
    func emptyRemovals() {
        let changes = PlaylistChanges(
            removals: [],
            reorderedIds: nil,
            reasoning: "No changes needed"
        )

        #expect(changes.removals.isEmpty)
        #expect(changes.reorderedIds == nil)
        #expect(!changes.reasoning.isEmpty)
    }

    @Test("PlaylistChanges with removals")
    func withRemovals() {
        let changes = PlaylistChanges(
            removals: ["video1", "video2"],
            reorderedIds: nil,
            reasoning: "Removed duplicates"
        )

        #expect(changes.removals.count == 2)
        #expect(changes.removals.contains("video1"))
        #expect(changes.removals.contains("video2"))
    }

    @Test("PlaylistChanges with reordering")
    func withReordering() {
        let newOrder = ["video3", "video1", "video2"]
        let changes = PlaylistChanges(
            removals: [],
            reorderedIds: newOrder,
            reasoning: "Sorted by energy level"
        )

        #expect(changes.removals.isEmpty)
        #expect(changes.reorderedIds == newOrder)
    }

    @Test("PlaylistChanges reasoning is present")
    func reasoningPresent() {
        let changes = PlaylistChanges(
            removals: ["video1"],
            reorderedIds: nil,
            reasoning: "Removed track that doesn't fit the vibe"
        )

        #expect(changes.reasoning.contains("Removed"))
    }
}

// MARK: - LyricsSummaryTests

@Suite("LyricsSummary Unit", .tags(.model))
struct LyricsSummaryTests {
    @Test("LyricsSummary with minimal themes")
    func minimalThemes() {
        let summary = LyricsSummary(
            themes: ["love", "loss"],
            mood: "melancholic",
            explanation: "A song about heartbreak and moving on."
        )

        #expect(summary.themes.count >= 2)
        #expect(summary.themes.contains("love"))
        #expect(summary.themes.contains("loss"))
    }

    @Test("LyricsSummary mood is single word or short phrase")
    func moodFormat() {
        let summary = LyricsSummary(
            themes: ["hope", "resilience", "growth"],
            mood: "uplifting",
            explanation: "An inspiring anthem about overcoming obstacles."
        )

        #expect(!summary.mood.isEmpty)
        #expect(summary.mood == "uplifting")
    }

    @Test("LyricsSummary explanation is concise")
    func explanationConcise() {
        let summary = LyricsSummary(
            themes: ["nostalgia", "youth", "summer"],
            mood: "nostalgic",
            explanation: "The song reminisces about carefree summer days. It captures the bittersweet feeling of looking back at simpler times."
        )

        #expect(!summary.explanation.isEmpty)
        // Should be 2-4 sentences, reasonably concise
        #expect(summary.explanation.count < 500)
    }

    @Test("LyricsSummary with multiple themes")
    func multipleThemes() {
        let summary = LyricsSummary(
            themes: ["rebellion", "freedom", "youth", "identity"],
            mood: "defiant",
            explanation: "A punk anthem about breaking free from expectations."
        )

        #expect(summary.themes.count >= 2)
        #expect(summary.themes.count <= 5)
    }
}
