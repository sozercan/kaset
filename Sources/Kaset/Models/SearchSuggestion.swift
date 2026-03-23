import Foundation

/// Represents a search suggestion from YouTube Music autocomplete.
struct SearchSuggestion: Identifiable, Hashable, Sendable {
    /// Unique identifier for the suggestion.
    let id: String

    /// The suggested search query text.
    let query: String

    /// Creates a suggestion with auto-generated ID.
    init(query: String) {
        self.id = UUID().uuidString
        self.query = query
    }

    /// Creates a suggestion with explicit ID.
    init(id: String, query: String) {
        self.id = id
        self.query = query
    }
}
