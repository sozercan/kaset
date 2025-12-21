import Foundation
import FoundationModels

/// Represents AI-suggested changes to a playlist.
/// Generated when the user asks to "refine" or "clean up" a playlist.
@available(macOS 26.0, *)
@Generable
struct PlaylistChanges: Sendable {
    /// Video IDs of tracks to remove from the playlist.
    @Guide(description: "List of video IDs (not titles) to remove from the playlist. Empty if no removals.")
    let removals: [String]

    /// Reordered list of video IDs representing the new order.
    /// If nil, order should not change.
    @Guide(description: "Optional reordered list of all video IDs. Only include if reordering is requested.")
    let reorderedIds: [String]?

    /// Brief explanation of why these changes were suggested.
    @Guide(description: "A brief, friendly explanation of the suggested changes (1-2 sentences).")
    let reasoning: String
}
