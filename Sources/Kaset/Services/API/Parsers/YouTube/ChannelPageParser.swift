import Foundation

/// Parses YouTube channel pages (`browse` with a `UC…` browse ID).
///
/// Channel metadata comes from `metadata.channelMetadataRenderer` (stable
/// across header redesigns); landing-tab videos are collected recursively.
enum ChannelPageParser {
    static func parse(_ data: [String: Any], channelId fallbackChannelId: String) -> YouTubeChannelDetail? {
        let metadata = (data["metadata"] as? [String: Any])?["channelMetadataRenderer"]
            as? [String: Any]

        let channelId = metadata?["externalId"] as? String ?? fallbackChannelId
        guard let name = metadata?["title"] as? String else {
            return nil
        }

        let channel = YouTubeChannel(
            channelId: channelId,
            name: name,
            handle: Self.handle(fromVanityURL: metadata?["vanityChannelUrl"] as? String),
            subscriberCountText: Self.subscriberCountText(of: data),
            descriptionSnippet: metadata?["description"] as? String,
            thumbnailURL: YouTubeItemParser.thumbnailURL(fromThumbnail: metadata?["avatar"])
        )

        var videos: [YouTubeVideo] = []
        var continuation: String?
        if let contents = data["contents"] {
            YouTubeFeedParser.collect(
                in: contents,
                videos: &videos,
                continuation: &continuation
            )
        }

        return YouTubeChannelDetail(
            channel: channel,
            videos: YouTubeFeedParser.deduplicate(videos)
        )
    }

    // MARK: - Private

    /// Extracts "@handle" from "http://www.youtube.com/@handle".
    private static func handle(fromVanityURL url: String?) -> String? {
        guard let last = url?.split(separator: "/").last, last.hasPrefix("@") else {
            return nil
        }
        return String(last)
    }

    /// Best-effort subscriber count from the page header
    /// (e.g. "20.8M subscribers" somewhere in `header`).
    private static func subscriberCountText(of data: [String: Any]) -> String? {
        guard let header = data["header"] else { return nil }
        return Self.firstText(in: header) { $0.localizedCaseInsensitiveContains("subscriber") }
    }

    /// Depth-first search for the first metadata text matching a predicate.
    private static func firstText(
        in value: Any,
        where predicate: (String) -> Bool
    ) -> String? {
        if let dict = value as? [String: Any] {
            for key in ["content", "simpleText", "text"] {
                if let text = dict[key] as? String, predicate(text) {
                    return text
                }
            }
            for nested in dict.values {
                if let found = firstText(in: nested, where: predicate) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = Self.firstText(in: element, where: predicate) {
                    return found
                }
            }
        }
        return nil
    }
}
