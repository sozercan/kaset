import Foundation

enum SearchSuggestionsParser {
    private static let logger = DiagnosticsLogger.api

    static func parse(_ data: [String: Any]) -> [SearchSuggestion] {
        var suggestions: [SearchSuggestion] = []
        var seenQueries = Set<String>()

        guard let contents = data["contents"] as? [[String: Any]] else {
            Self.logger.debug("SearchSuggestionsParser: No contents array found. Top keys: \(data.keys.sorted())")
            return suggestions
        }

        for content in contents {
            if let sectionRenderer = content["searchSuggestionsSectionRenderer"] as? [String: Any],
               let sectionContents = sectionRenderer["contents"] as? [[String: Any]]
            {
                for item in sectionContents {
                    if let suggestion = parseSuggestion(from: item), seenQueries.insert(suggestion.query).inserted {
                        suggestions.append(suggestion)
                    }
                }
            }
        }

        return suggestions
    }

    private static func parseSuggestion(from item: [String: Any]) -> SearchSuggestion? {
        if let renderer = item["searchSuggestionRenderer"] as? [String: Any] {
            return self.parseSuggestionRenderer(renderer)
        }

        if let renderer = item["historySuggestionRenderer"] as? [String: Any] {
            return self.parseSuggestionRenderer(renderer)
        }

        return nil
    }

    private static func parseSuggestionRenderer(_ renderer: [String: Any]) -> SearchSuggestion? {
        guard let suggestion = renderer["suggestion"] as? [String: Any],
              let runs = suggestion["runs"] as? [[String: Any]]
        else {
            return nil
        }

        let queryText = ParsingHelpers.joinedRunText(runs)

        guard !queryText.isEmpty else {
            return nil
        }

        return SearchSuggestion(query: queryText)
    }
}
