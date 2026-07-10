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

        let chapters = Self.chapters(of: data)

        return WatchNextData(
            videoTitle: videoTitle,
            viewCountText: viewCountText,
            publishedText: publishedText,
            channel: channel,
            related: YouTubeFeedParser.deduplicate(related),
            chapters: chapters,
            isSubscribed: isSubscribed,
            commentsContinuation: Self.commentsContinuation(of: data)
        )
    }

    /// Navigation chapters exposed by YouTube's watch-next response.
    ///
    /// Prefer the player bar's `chapterRenderer` markers because they are the
    /// canonical watch-page timeline source. Fall back to
    /// `macroMarkersListItemRenderer`, which can appear in the chapters panel,
    /// structured description, and search previews, and therefore needs
    /// de-duplication.
    static func chapters(of data: [String: Any]) -> [YouTubeChapter] {
        let videoId = self.currentVideoId(of: data)
        var chapterRenderers: [YouTubeChapter] = []
        self.collectChapterRenderers(in: data, videoId: videoId, chapters: &chapterRenderers)
        let canonical = self.deduplicateChapters(chapterRenderers)
        if !canonical.isEmpty {
            return canonical
        }

        var macroMarkers: [YouTubeChapter] = []
        self.collectMacroMarkerRenderers(in: data, fallbackVideoId: videoId, chapters: &macroMarkers)
        return self.deduplicateChapters(macroMarkers)
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

    private static func currentVideoId(of data: [String: Any]) -> String? {
        if let endpoint = data["currentVideoEndpoint"] as? [String: Any],
           let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
           let videoId = watchEndpoint["videoId"] as? String,
           !videoId.isEmpty
        {
            return videoId
        }

        return nil
    }

    private static func collectChapterRenderers(
        in value: Any,
        videoId: String?,
        chapters: inout [YouTubeChapter]
    ) {
        if let dict = value as? [String: Any] {
            if let renderer = dict["chapterRenderer"] as? [String: Any],
               let chapter = self.chapter(fromChapterRenderer: renderer, videoId: videoId)
            {
                chapters.append(chapter)
            }

            for nested in dict.values {
                self.collectChapterRenderers(in: nested, videoId: videoId, chapters: &chapters)
            }
        } else if let array = value as? [Any] {
            for element in array {
                self.collectChapterRenderers(in: element, videoId: videoId, chapters: &chapters)
            }
        }
    }

    private static func collectMacroMarkerRenderers(
        in value: Any,
        fallbackVideoId: String?,
        chapters: inout [YouTubeChapter]
    ) {
        if let dict = value as? [String: Any] {
            if let renderer = dict["macroMarkersListItemRenderer"] as? [String: Any],
               let chapter = self.chapter(fromMacroMarkerRenderer: renderer, fallbackVideoId: fallbackVideoId)
            {
                chapters.append(chapter)
            }

            for nested in dict.values {
                self.collectMacroMarkerRenderers(
                    in: nested,
                    fallbackVideoId: fallbackVideoId,
                    chapters: &chapters
                )
            }
        } else if let array = value as? [Any] {
            for element in array {
                self.collectMacroMarkerRenderers(
                    in: element,
                    fallbackVideoId: fallbackVideoId,
                    chapters: &chapters
                )
            }
        }
    }

    private static func chapter(
        fromChapterRenderer renderer: [String: Any],
        videoId: String?
    ) -> YouTubeChapter? {
        guard let title = YouTubeItemParser.text(from: renderer["title"]),
              let startMillis = self.intValue(from: renderer["timeRangeStartMillis"])
        else {
            return nil
        }

        return YouTubeChapter(
            videoId: videoId,
            title: title,
            startTime: TimeInterval(startMillis) / 1000,
            endTime: nil,
            timeText: nil,
            thumbnailURL: YouTubeItemParser.thumbnailURL(fromThumbnail: renderer["thumbnail"])
        )
    }

    private static func chapter(
        fromMacroMarkerRenderer renderer: [String: Any],
        fallbackVideoId: String?
    ) -> YouTubeChapter? {
        guard let title = YouTubeItemParser.text(from: renderer["title"]) else {
            return nil
        }

        let repeatCommand = self.findRepeatChapterCommand(in: renderer["repeatButton"])
        let watchEndpoint = self.watchEndpoint(from: renderer)
        let endpointVideoId = watchEndpoint?["videoId"] as? String
        if let fallbackVideoId, let endpointVideoId, endpointVideoId != fallbackVideoId {
            return nil
        }
        let timeText = YouTubeItemParser.text(from: renderer["timeDescription"])
        let startMillis = self.intValue(from: repeatCommand?["startTimeMs"])
            ?? self.intValue(from: watchEndpoint?["startTimeSeconds"]).map { $0 * 1000 }
            ?? timeText.flatMap(self.milliseconds(fromTimeText:))

        guard let startMillis else { return nil }

        return YouTubeChapter(
            videoId: endpointVideoId ?? fallbackVideoId,
            title: title,
            startTime: TimeInterval(startMillis) / 1000,
            endTime: self.intValue(from: repeatCommand?["endTimeMs"]).map { TimeInterval($0) / 1000 },
            timeText: timeText,
            thumbnailURL: YouTubeItemParser.thumbnailURL(fromThumbnail: renderer["thumbnail"])
        )
    }

    private static func milliseconds(fromTimeText text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else {
            return nil
        }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else {
            return nil
        }

        let seconds: Int = if values.count == 3 {
            values[0] * 3600 + values[1] * 60 + values[2]
        } else {
            values[0] * 60 + values[1]
        }
        return seconds * 1000
    }

    private static func watchEndpoint(from renderer: [String: Any]) -> [String: Any]? {
        guard let onTap = renderer["onTap"] as? [String: Any] else { return nil }
        return onTap["watchEndpoint"] as? [String: Any]
    }

    private static func findRepeatChapterCommand(in value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let command = dict["repeatChapterCommand"] as? [String: Any] {
                return command
            }

            for nested in dict.values {
                if let command = self.findRepeatChapterCommand(in: nested) {
                    return command
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let command = self.findRepeatChapterCommand(in: element) {
                    return command
                }
            }
        }

        return nil
    }

    private static func intValue(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let double as Double:
            Int(double)
        case let number as NSNumber:
            Int(number.int64Value)
        case let string as String:
            Int(string)
        default:
            nil
        }
    }

    private static func deduplicateChapters(_ chapters: [YouTubeChapter]) -> [YouTubeChapter] {
        var seen: Set<String> = []
        var result: [YouTubeChapter] = []

        for chapter in chapters {
            let key = "\(chapter.videoId ?? "")|\(Int((chapter.startTime * 1000).rounded()))|\(chapter.title)"
            guard seen.insert(key).inserted else { continue }
            result.append(chapter)
        }

        return result.sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            return lhs.title < rhs.title
        }
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
