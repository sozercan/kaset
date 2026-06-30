import Foundation

/// Parses YouTube `next` (watch-next) responses: primary video metadata
/// plus the related-videos rail.
enum WatchNextParser {
    static func parse(_ data: [String: Any]) -> WatchNextData {
        let results = (data["contents"] as? [String: Any])?["twoColumnWatchNextResults"]
            as? [String: Any]

        // Primary metadata (title, view count, channel)
        var videoTitle: String?
        var viewCountText: String?
        var publishedText: String?
        var channel: YouTubeChannel?
        var isSubscribed: Bool?

        let primaryContents = (
            (results?["results"] as? [String: Any])?["results"] as? [String: Any]
        )?["contents"] as? [[String: Any]] ?? []

        for content in primaryContents {
            if let primaryInfo = content["videoPrimaryInfoRenderer"] as? [String: Any] {
                videoTitle = YouTubeItemParser.text(from: primaryInfo["title"])
                publishedText = YouTubeItemParser.text(from: primaryInfo["relativeDateText"])
                let viewCount = (primaryInfo["viewCount"] as? [String: Any])?["videoViewCountRenderer"]
                    as? [String: Any]
                viewCountText = YouTubeItemParser.text(from: viewCount?["viewCount"])
            }

            if let secondaryInfo = content["videoSecondaryInfoRenderer"] as? [String: Any] {
                if let owner = (secondaryInfo["owner"] as? [String: Any])?["videoOwnerRenderer"]
                    as? [String: Any]
                {
                    channel = Self.channel(fromVideoOwner: owner)
                }
                if let subscribeButton = (secondaryInfo["subscribeButton"] as? [String: Any])?["subscribeButtonRenderer"]
                    as? [String: Any]
                {
                    isSubscribed = subscribeButton["subscribed"] as? Bool
                }
            }
        }

        // Related videos rail
        var related: [YouTubeVideo] = []
        var continuation: String?
        if let secondaryResults = results?["secondaryResults"] {
            YouTubeFeedParser.collect(
                in: secondaryResults,
                videos: &related,
                continuation: &continuation
            )
        }

        return WatchNextData(
            videoTitle: videoTitle,
            viewCountText: viewCountText,
            publishedText: publishedText,
            channel: channel,
            related: YouTubeFeedParser.deduplicate(related),
            isSubscribed: isSubscribed,
            commentsContinuation: Self.commentsContinuation(of: data)
        )
    }

    /// The continuation token for the watch page's comments section
    /// (the `comment-item-section` item section).
    static func commentsContinuation(of data: [String: Any]) -> String? {
        self.findCommentsSectionToken(in: data)
    }

    private static func findCommentsSectionToken(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let section = dict["itemSectionRenderer"] as? [String: Any],
               (section["sectionIdentifier"] as? String) == "comment-item-section"
            {
                return self.firstContinuationToken(in: section)
            }
            for nested in dict.values {
                if let token = Self.findCommentsSectionToken(in: nested) {
                    return token
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let token = Self.findCommentsSectionToken(in: element) {
                    return token
                }
            }
        }
        return nil
    }

    private static func firstContinuationToken(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let command = dict["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String
            {
                return token
            }
            for nested in dict.values {
                if let token = Self.firstContinuationToken(in: nested) {
                    return token
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let token = Self.firstContinuationToken(in: element) {
                    return token
                }
            }
        }
        return nil
    }

    // MARK: - Private

    private static func channel(fromVideoOwner owner: [String: Any]) -> YouTubeChannel? {
        let browseEndpoint = (owner["navigationEndpoint"] as? [String: Any])?["browseEndpoint"]
            as? [String: Any]
        guard let name = YouTubeItemParser.text(from: owner["title"]),
              let channelId = browseEndpoint?["browseId"] as? String
        else {
            return nil
        }

        return YouTubeChannel(
            channelId: channelId,
            name: name,
            handle: (browseEndpoint?["canonicalBaseUrl"] as? String)?
                .split(separator: "/").last.map(String.init),
            subscriberCountText: YouTubeItemParser.text(from: owner["subscriberCountText"]),
            thumbnailURL: YouTubeItemParser.thumbnailURL(fromThumbnail: owner["thumbnail"])
        )
    }
}
