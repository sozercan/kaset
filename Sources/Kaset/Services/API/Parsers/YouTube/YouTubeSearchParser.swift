import Foundation

/// Parses YouTube `search` responses.
///
/// June 2026 renderer mix (confirmed via api-explorer):
/// - Videos: legacy `videoRenderer`
/// - Channels: legacy `channelRenderer`
/// - Playlists: new `lockupViewModel` (`LOCKUP_CONTENT_TYPE_PLAYLIST`)
/// - Shorts shelves: `shortsLockupViewModel` (intentionally skipped)
enum YouTubeSearchParser {
    /// Parses a full search response.
    static func parse(_ data: [String: Any]) -> YouTubeSearchResponse {
        var response = YouTubeSearchResponse.empty

        let sections = Self.primarySections(of: data)
        for section in sections {
            if let itemSection = section["itemSectionRenderer"] as? [String: Any],
               let items = itemSection["contents"] as? [[String: Any]]
            {
                for item in items {
                    Self.append(item, to: &response)
                }
            } else if response.continuation == nil,
                      let continuationItem = section["continuationItemRenderer"] as? [String: Any]
            {
                response.continuation = YouTubeFeedParser.token(
                    fromContinuationItem: continuationItem
                )
            }
        }

        return response
    }

    /// Parses a search continuation response.
    static func parseContinuation(_ data: [String: Any]) -> YouTubeSearchResponse {
        var response = YouTubeSearchResponse.empty
        let actions = data["onResponseReceivedCommands"] as? [[String: Any]]
            ?? data["onResponseReceivedActions"] as? [[String: Any]]
            ?? []

        for action in actions {
            let items = (action["appendContinuationItemsAction"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]] ?? []
            for sectionItem in items {
                if let itemSection = sectionItem["itemSectionRenderer"] as? [String: Any],
                   let items = itemSection["contents"] as? [[String: Any]]
                {
                    for item in items {
                        Self.append(item, to: &response)
                    }
                } else if response.continuation == nil,
                          let continuationItem = sectionItem["continuationItemRenderer"]
                          as? [String: Any]
                {
                    response.continuation = YouTubeFeedParser.token(
                        fromContinuationItem: continuationItem
                    )
                }
            }
        }

        return response
    }

    // MARK: - Private

    /// The primary result sections
    /// (`contents.twoColumnSearchResultsRenderer.primaryContents.sectionListRenderer.contents`).
    private static func primarySections(of data: [String: Any]) -> [[String: Any]] {
        let sectionList = (
            (
                (data["contents"] as? [String: Any])?["twoColumnSearchResultsRenderer"]
                    as? [String: Any]
            )?["primaryContents"] as? [String: Any]
        )?["sectionListRenderer"] as? [String: Any]
        return sectionList?["contents"] as? [[String: Any]] ?? []
    }

    /// Dispatches one result item into the right bucket.
    private static func append(_ item: [String: Any], to response: inout YouTubeSearchResponse) {
        if let video = YouTubeItemParser.video(fromAnyItem: item) {
            response.videos.append(video)
            return
        }

        if let channelRenderer = item["channelRenderer"] as? [String: Any],
           let channel = YouTubeItemParser.channel(fromChannelRenderer: channelRenderer)
        {
            response.channels.append(channel)
            return
        }

        if let lockup = item["lockupViewModel"] as? [String: Any],
           let playlist = YouTubeItemParser.playlist(fromLockup: lockup)
        {
            response.playlists.append(playlist)
        }
    }
}
