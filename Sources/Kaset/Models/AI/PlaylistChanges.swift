import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct PlaylistChanges {
    @Guide(description: "List of video IDs (not titles) to remove from the playlist. Empty if no removals.")
    let removals: [String]

    @Guide(description: "Optional reordered list of all video IDs. Only include if reordering is requested.")
    let reorderedIds: [String]?

    @Guide(description: "A brief, friendly explanation of the suggested changes (1-2 sentences).")
    let reasoning: String

    func normalized(forOriginalTrackIds originalTrackIds: [String]) -> Self {
        let normalizedReorderedIds: [String]? = if let reorderedIds = self.reorderedIds,
                                                   !reorderedIds.isEmpty,
                                                   reorderedIds != originalTrackIds
        {
            reorderedIds
        } else {
            nil
        }

        return Self(
            removals: self.removals,
            reorderedIds: normalizedReorderedIds,
            reasoning: self.reasoning
        )
    }
}
