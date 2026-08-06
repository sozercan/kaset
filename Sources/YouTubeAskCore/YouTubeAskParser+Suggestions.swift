import Foundation

extension YouTubeAskParser {
    static func deduplicatedSuggestions(
        _ suggestions: [YouTubeAskParsedSuggestion]
    ) throws -> [YouTubeAskParsedSuggestion] {
        var firstIndexByLabel: [String: Int] = [:]
        var result: [YouTubeAskParsedSuggestion] = []
        result.reserveCapacity(suggestions.count)

        for suggestion in suggestions {
            if let firstIndex = firstIndexByLabel[suggestion.label] {
                // The visible label cannot safely disambiguate distinct opaque
                // capabilities. Keep exact repeats, but fail closed on a label
                // collision instead of silently choosing one command.
                guard result[firstIndex].command.continuation == suggestion.command.continuation else {
                    throw YouTubeAskCoreError.malformedChip
                }
                continue
            }

            firstIndexByLabel[suggestion.label] = result.count
            result.append(suggestion)
        }

        return result
    }

    static let eligibleMarkerValues: Set<String> = [
        "PAyouchat",
        "engagement-panel-youchat",
    ]

    static let eligibleMarkerKeys: Set<String> = [
        "identifier",
        "panelId",
        "panelIdentifier",
        "targetId",
    ]
}
