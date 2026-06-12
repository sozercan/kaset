import Foundation

/// Parses YouTube browse feeds (home `FEwhat_to_watch` and feed continuations).
///
/// The home feed is a `twoColumnBrowseResultsRenderer` →
/// `richGridRenderer` of `richItemRenderer`s. Item collection walks the
/// response recursively so the parser tolerates renderer-generation churn
/// (legacy `videoRenderer` vs. `lockupViewModel`) and container reshuffles.
enum YouTubeFeedParser {
    /// Parses a full browse response into a feed page.
    static func parse(_ data: [String: Any]) -> YouTubeFeed {
        var videos: [YouTubeVideo] = []
        var continuationToken: String?
        Self.collect(in: data, videos: &videos, continuationToken: &continuationToken)
        return YouTubeFeed(
            videos: Self.deduplicate(videos),
            continuationToken: continuationToken
        )
    }

    /// Parses a continuation response (`onResponseReceivedActions` format).
    static func parseContinuation(_ data: [String: Any]) -> YouTubeFeed {
        let actions = data["onResponseReceivedActions"] as? [[String: Any]] ?? []
        var videos: [YouTubeVideo] = []
        var continuationToken: String?

        for action in actions {
            let items = (action["appendContinuationItemsAction"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]]
                ?? (action["reloadContinuationItemsCommand"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]]
                ?? []
            for item in items {
                Self.collect(in: item, videos: &videos, continuationToken: &continuationToken)
            }
        }

        // Fall back to a full walk for unrecognized response shapes.
        if videos.isEmpty, continuationToken == nil {
            Self.collect(in: data, videos: &videos, continuationToken: &continuationToken)
        }

        return YouTubeFeed(
            videos: Self.deduplicate(videos),
            continuationToken: continuationToken
        )
    }

    // MARK: - Collection

    /// Recursively collects videos and the first continuation token.
    ///
    /// Recursion stops at recognized item wrappers, so nested renderers inside
    /// an item (e.g. avatar view models) are not double-counted.
    static func collect(
        in value: Any,
        videos: inout [YouTubeVideo],
        continuationToken: inout String?
    ) {
        if let dict = value as? [String: Any] {
            if let video = YouTubeItemParser.video(fromAnyItem: dict) {
                videos.append(video)
                return
            }

            if continuationToken == nil,
               let continuationItem = dict["continuationItemRenderer"] as? [String: Any]
            {
                continuationToken = Self.token(fromContinuationItem: continuationItem)
                return
            }

            for (key, nested) in dict {
                // Don't descend into engagement panels or player overlays.
                if key == "engagementPanels" || key == "playerOverlays" {
                    continue
                }
                Self.collect(in: nested, videos: &videos, continuationToken: &continuationToken)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collect(in: element, videos: &videos, continuationToken: &continuationToken)
            }
        }
    }

    /// Extracts the token from a `continuationItemRenderer`.
    static func token(fromContinuationItem item: [String: Any]) -> String? {
        (
            (item["continuationEndpoint"] as? [String: Any])?["continuationCommand"]
                as? [String: Any]
        )?["token"] as? String
    }

    /// Removes duplicate videos while preserving order.
    static func deduplicate(_ videos: [YouTubeVideo]) -> [YouTubeVideo] {
        var seen = Set<String>()
        return videos.filter { seen.insert($0.videoId).inserted }
    }
}
