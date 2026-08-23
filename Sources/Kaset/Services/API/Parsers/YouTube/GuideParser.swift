import Foundation

/// Parses the YouTube `guide` response (sidebar structure).
///
/// Signed in, the guide contains a subscriptions section whose
/// `guideEntryRenderer`s point at `UC…` channel browse IDs with channel
/// avatars — that list is the user's subscribed channels.
enum GuideParser {
    /// Extracts subscribed channels from a guide response.
    ///
    /// Scoped to `guideSubscriptionsSectionRenderer`: the rest of the guide
    /// also contains `UC…` entries for YouTube's own system channels
    /// (Music, Shopping, Live) which are NOT user subscriptions.
    static func subscribedChannels(_ data: [String: Any]) -> [YouTubeChannel] {
        guard let subscriptionsSection = firstSubscriptionsSection(in: data) else {
            return []
        }

        var channels: [YouTubeChannel] = []
        Self.collect(in: subscriptionsSection, into: &channels)

        var seen = Set<String>()
        return channels.filter { seen.insert($0.channelId).inserted }
    }

    // MARK: - Private

    private static func firstSubscriptionsSection(in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let section = dict["guideSubscriptionsSectionRenderer"] as? [String: Any] {
                return section
            }
            for nested in dict.values {
                if let found = Self.firstSubscriptionsSection(in: nested) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = Self.firstSubscriptionsSection(in: element) {
                    return found
                }
            }
        }
        return nil
    }

    private static func collect(in value: Any, into channels: inout [YouTubeChannel]) {
        if let dict = value as? [String: Any] {
            if let entry = dict["guideEntryRenderer"] as? [String: Any] {
                if let channel = channel(fromGuideEntry: entry) {
                    channels.append(channel)
                }
                // Entries can nest (collapsible sections keep children inside).
                for nested in entry.values {
                    Self.collect(in: nested, into: &channels)
                }
                return
            }

            for nested in dict.values {
                Self.collect(in: nested, into: &channels)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collect(in: element, into: &channels)
            }
        }
    }

    private static func channel(fromGuideEntry entry: [String: Any]) -> YouTubeChannel? {
        let browseId = (
            (entry["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
        )?["browseId"] as? String

        // Only channel entries — guide also lists Home/Library/etc.
        guard let browseId, browseId.hasPrefix("UC") else {
            return nil
        }

        guard let name = YouTubeItemParser.text(from: entry["formattedTitle"]) else {
            return nil
        }

        return YouTubeChannel(
            channelId: browseId,
            name: name,
            thumbnailURL: YouTubeItemParser.thumbnailURL(fromThumbnail: entry["thumbnail"])
        )
    }
}
