import Foundation
import Testing
@testable import Kaset

// MARK: - PlaylistChangesTests

@Suite(.tags(.model))
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

    @Test("PlaylistChanges normalizes empty reordering to nil")
    func normalizesEmptyReordering() {
        let changes = PlaylistChanges(
            removals: [],
            reorderedIds: [],
            reasoning: "No changes needed"
        )

        let normalized = changes.normalized(forOriginalTrackIds: ["video1", "video2"])
        #expect(normalized.reorderedIds == nil)
    }

    @Test("PlaylistChanges normalizes unchanged ordering to nil")
    func normalizesUnchangedOrdering() {
        let originalOrder = ["video1", "video2", "video3"]
        let changes = PlaylistChanges(
            removals: [],
            reorderedIds: originalOrder,
            reasoning: "Order already works well"
        )

        let normalized = changes.normalized(forOriginalTrackIds: originalOrder)
        #expect(normalized.reorderedIds == nil)
    }

    @Test("PlaylistChanges preserves meaningful reordering")
    func preservesMeaningfulReordering() {
        let originalOrder = ["video1", "video2", "video3"]
        let newOrder = ["video3", "video1", "video2"]
        let changes = PlaylistChanges(
            removals: [],
            reorderedIds: newOrder,
            reasoning: "Sorted by energy level"
        )

        let normalized = changes.normalized(forOriginalTrackIds: originalOrder)
        #expect(normalized.reorderedIds == newOrder)
    }
}

// MARK: - LyricsSummaryTests

@Suite(.tags(.model))
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

// MARK: - FoundationModelsBudgetTests

@Suite(.tags(.model))
struct FoundationModelsBudgetTests {
    @Test("prompt budget total includes schema tokens")
    func promptBudgetTotalIncludesSchemaTokens() {
        let budget = FoundationModelsPromptBudget(
            contextSize: 4096,
            instructionsTokens: 100,
            promptTokens: 200,
            toolsTokens: 300,
            schemaTokens: 400
        )

        #expect(budget.totalTokens == 1000)
        #expect(budget.remainingTokens == 3096)
    }

    @Test("bestFittingPrefixCount allows zero-line fallback")
    func bestFittingPrefixCountAllowsZeroLineFallback() async {
        let bestFit = await FoundationModelsService.bestFittingPrefixCount(maxCount: 4) { count in
            count == 0
        }

        #expect(bestFit == 0)
    }

    @Test("bestFittingPrefixCount returns the largest fitting prefix")
    func bestFittingPrefixCountReturnsLargestFit() async {
        let bestFit = await FoundationModelsService.bestFittingPrefixCount(maxCount: 6) { count in
            count <= 3
        }

        #expect(bestFit == 3)
    }

    @Test("bestFittingTruncatedContent trims short content below the old 128-char floor")
    func bestFittingTruncatedContentHandlesShortInputs() async {
        let bestFit = await FoundationModelsService.bestFittingTruncatedContent(
            "small input",
            truncationMarker: "..."
        ) { candidate in
            candidate.count <= 3
        }

        #expect(bestFit == "sma")
    }

    @Test("bestFittingTruncatedContent allows an empty fallback")
    func bestFittingTruncatedContentAllowsEmptyFallback() async {
        let bestFit = await FoundationModelsService.bestFittingTruncatedContent(
            "small input",
            truncationMarker: "..."
        ) { candidate in
            candidate.isEmpty
        }

        #expect(bestFit?.isEmpty == true)
    }
}
