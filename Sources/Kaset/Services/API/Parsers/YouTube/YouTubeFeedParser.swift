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
        var continuation: String?
        Self.collect(in: data, videos: &videos, continuation: &continuation)
        return YouTubeFeed(
            videos: Self.deduplicate(videos),
            continuation: continuation
        )
    }

    /// Parses a continuation response (`onResponseReceivedActions` format).
    static func parseContinuation(_ data: [String: Any]) -> YouTubeFeed {
        let actions = data["onResponseReceivedActions"] as? [[String: Any]] ?? []
        var videos: [YouTubeVideo] = []
        var continuation: String?

        for action in actions {
            let items = (action["appendContinuationItemsAction"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]]
                ?? (action["reloadContinuationItemsCommand"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]]
                ?? []
            for item in items {
                Self.collect(in: item, videos: &videos, continuation: &continuation)
            }
        }

        // Fall back to a full walk for unrecognized response shapes.
        if videos.isEmpty, continuation == nil {
            Self.collect(in: data, videos: &videos, continuation: &continuation)
        }

        return YouTubeFeed(
            videos: Self.deduplicate(videos),
            continuation: continuation
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
        continuation: inout String?
    ) {
        if let dict = value as? [String: Any] {
            if let video = YouTubeItemParser.video(fromAnyItem: dict) {
                videos.append(video)
                return
            }

            if continuation == nil,
               let continuationItem = dict["continuationItemRenderer"] as? [String: Any]
            {
                continuation = Self.token(fromContinuationItem: continuationItem)
                return
            }

            for (key, nested) in dict {
                // Don't descend into engagement panels or player overlays.
                if key == "engagementPanels" || key == "playerOverlays" {
                    continue
                }
                Self.collect(in: nested, videos: &videos, continuation: &continuation)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collect(in: element, videos: &videos, continuation: &continuation)
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

    // MARK: - Playlist Collection

    /// Recursively collects playlist lockups (used by the user-playlists page).
    static func collectPlaylists(_ data: [String: Any]) -> [YouTubePlaylist] {
        var playlists: [YouTubePlaylist] = []
        Self.collectPlaylists(in: data, into: &playlists)

        var seen = Set<String>()
        return playlists.filter { seen.insert($0.playlistId).inserted }
    }

    private static func collectPlaylists(in value: Any, into playlists: inout [YouTubePlaylist]) {
        if let dict = value as? [String: Any] {
            if let lockup = dict["lockupViewModel"] as? [String: Any] {
                if let playlist = YouTubeItemParser.playlist(fromLockup: lockup) {
                    playlists.append(playlist)
                }
                return
            }

            for nested in dict.values {
                Self.collectPlaylists(in: nested, into: &playlists)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collectPlaylists(in: element, into: &playlists)
            }
        }
    }
}
