import Foundation
import FoundationModels

// MARK: - QueueChanges

/// Represents AI-suggested changes to the playback queue.
/// Generated when the user asks to "refine" or modify their queue.
@available(macOS 26.0, *)
@Generable
struct QueueChanges: Sendable {
    /// Video IDs of tracks to remove from the queue.
    @Guide(description: "List of video IDs to remove from the queue. Empty if no removals.")
    let removals: [String]

    /// Video IDs of tracks to add to the queue.
    @Guide(description: "List of video IDs to add to the queue. Empty if no additions.")
    let additions: [String]

    /// Reordered list of video IDs representing the new queue order.
    @Guide(description: "Complete reordered list of all video IDs. Only include if reordering is needed.")
    let reorderedIds: [String]?

    /// Brief explanation of the suggested changes.
    @Guide(description: "A brief, friendly explanation of the suggested changes (1-2 sentences).")
    let reasoning: String
}
