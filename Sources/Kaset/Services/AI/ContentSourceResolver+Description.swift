import Foundation

@available(macOS 26.0, *)
extension ContentSourceResolver {
    static func queryDescription(
        for intent: MusicIntent,
        groundingQuery: String? = nil
    ) -> String {
        let intent = Self.groundedIntent(intent, groundingQuery: groundingQuery)
        var parts: [String] = []
        let popularityQuery = MusicDiscoveryTaxonomy.queryExcludingExplicitTitle(
            groundingQuery ?? intent.query,
            title: intent.query
        )
        let wantsHits = MusicDiscoveryTaxonomy.containsRoutingPopularityKeyword(popularityQuery)

        if !intent.mood.isEmpty {
            parts.append(intent.mood)
        }
        if !intent.genre.isEmpty {
            parts.append(intent.genre)
        }
        if wantsHits {
            parts.append("hits")
        }
        if !intent.artist.isEmpty {
            parts.append("by \(intent.artist)")
        }
        if !intent.era.isEmpty {
            parts.append("from the \(intent.era)")
        }
        if !intent.version.isEmpty {
            parts.append("(\(intent.version))")
        }
        if !intent.activity.isEmpty {
            parts.append("for \(intent.activity)")
        }

        if parts.isEmpty {
            return intent.query
        }

        return parts.joined(separator: " ")
    }
}
