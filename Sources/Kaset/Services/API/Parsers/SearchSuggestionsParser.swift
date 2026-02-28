import Foundation

/// Parser for search suggestions responses from YouTube Music API.
enum SearchSuggestionsParser {
    private static let logger = DiagnosticsLogger.api

    /// Parses a search suggestions response.
    /// - Parameter data: The raw JSON response from the API.
    /// - Returns: An array of search suggestions.
    static func parse(_ data: [String: Any]) -> [SearchSuggestion] {
        var suggestions: [SearchSuggestion] = []

        // Navigate to contents array
        guard let contents = data["contents"] as? [[String: Any]] else {
            Self.logger.debug("SearchSuggestionsParser: No contents array found. Top keys: \(data.keys.sorted())")
            return suggestions
        }

        for content in contents {
            // Look for searchSuggestionsSectionRenderer
            if let sectionRenderer = content["searchSuggestionsSectionRenderer"] as? [String: Any],
               let sectionContents = sectionRenderer["contents"] as? [[String: Any]]
            {
                for item in sectionContents {
                    if let suggestion = parseSuggestion(from: item) {
                        suggestions.append(suggestion)
                    }
                }
            }
        }

        return suggestions
    }

    /// Parses a single suggestion from a searchSuggestionRenderer.
    private static func parseSuggestion(from item: [String: Any]) -> SearchSuggestion? {
        // Try searchSuggestionRenderer (text suggestions)
        if let renderer = item["searchSuggestionRenderer"] as? [String: Any] {
            return self.parseSuggestionRenderer(renderer)
        }

        // Try historySuggestionRenderer (search history)
        if let renderer = item["historySuggestionRenderer"] as? [String: Any] {
            return self.parseSuggestionRenderer(renderer)
        }

        return nil
    }

    /// Parses the suggestion text from a renderer.
    private static func parseSuggestionRenderer(_ renderer: [String: Any]) -> SearchSuggestion? {
        // Extract suggestion text from runs
        guard let suggestion = renderer["suggestion"] as? [String: Any],
              let runs = suggestion["runs"] as? [[String: Any]]
        else {
            return nil
        }

        // Combine all text runs into the full suggestion
        let queryText = runs.compactMap { $0["text"] as? String }.joined()

        guard !queryText.isEmpty else {
            return nil
        }

        return SearchSuggestion(query: queryText)
    }
}
