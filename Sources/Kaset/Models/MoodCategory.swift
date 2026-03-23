import Foundation
import SwiftUI

// MARK: - MoodCategory

/// Represents a moods/genres category that can be navigated to.
/// Unlike playlists, these are browse endpoints that return sections of content.
struct MoodCategory: Identifiable, Hashable, Sendable {
    /// The browse ID for this category (e.g., "FEmusic_moods_and_genres_category")
    let browseId: String

    /// Optional params for the browse request
    let params: String?

    /// Display title for the category
    let title: String

    /// Optional color for the card background (from API's leftStripeColor)
    let color: Color?

    init(browseId: String, params: String?, title: String, color: Color? = nil) {
        self.browseId = browseId
        self.params = params
        self.title = title
        self.color = color
    }

    /// Unique identifier (combines browseId and params)
    var id: String {
        if let params {
            "\(self.browseId)_\(params)"
        } else {
            self.browseId
        }
    }

    /// Whether this browse ID represents a mood/genre category
    static func isMoodCategory(_ browseId: String) -> Bool {
        browseId.hasPrefix("FEmusic_moods_and_genres")
    }

    /// Parses a combined ID (browseId_params) back into components
    static func parseId(_ combinedId: String) -> (browseId: String, params: String?)? {
        // Check if this looks like a mood category ID
        guard combinedId.hasPrefix("FEmusic_moods_and_genres") else {
            return nil
        }

        // The params start after the base browse ID
        // Format: FEmusic_moods_and_genres_category_PARAMS or just FEmusic_moods_and_genres_category
        let baseId = "FEmusic_moods_and_genres_category"
        if combinedId == baseId {
            return (baseId, nil)
        }

        // Try to extract params (everything after the underscore following category)
        if combinedId.hasPrefix(baseId + "_") {
            let params = String(combinedId.dropFirst(baseId.count + 1))
            return (baseId, params)
        }

        // Fallback - use the whole thing as browseId
        return (combinedId, nil)
    }
}
