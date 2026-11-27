import Foundation

enum YouTubeFeedParser {
    static func parse(_ data: [String: Any]) -> YouTubeFeed {
        var videos: [YouTubeVideo] = []
        var shorts: [YouTubeVideo] = []
        var continuation: String?
        Self.collect(in: data, videos: &videos, shorts: &shorts, continuation: &continuation)
        return YouTubeFeed(
            videos: Self.deduplicate(videos),
            shorts: Self.deduplicate(shorts),
            continuation: continuation
        )
    }

    static func parseContinuation(_ data: [String: Any]) -> YouTubeFeed {
        let actions = data["onResponseReceivedActions"] as? [[String: Any]] ?? []
        var videos: [YouTubeVideo] = []
        var shorts: [YouTubeVideo] = []
        var continuation: String?

        for action in actions {
            let items = (action["appendContinuationItemsAction"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]]
                ?? (action["reloadContinuationItemsCommand"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]]
                ?? []
            for item in items {
                Self.collect(in: item, videos: &videos, shorts: &shorts, continuation: &continuation)
            }
        }

        if videos.isEmpty, continuation == nil {
            Self.collect(in: data, videos: &videos, shorts: &shorts, continuation: &continuation)
        }

        return YouTubeFeed(
            videos: Self.deduplicate(videos),
            shorts: Self.deduplicate(shorts),
            continuation: continuation
        )
    }

    static func parseHomeBundle(from data: Data) throws -> YouTubeHomeBundle {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMusicError.parseError(message: "Response is not a JSON object")
        }
        return YouTubeHomeBundle(
            feed: Self.parse(json),
            chips: Self.parseChips(json),
            shelves: Self.parseHomeShelves(json)
        )
    }

    static func parseChips(_ data: [String: Any]) -> [YouTubeHomeChip] {
        guard let chips = chipBarContents(data) else { return [] }

        var result: [YouTubeHomeChip] = []
        var seen = Set<String>()
        for entry in chips {
            guard let chip = entry["chipCloudChipRenderer"] as? [String: Any] else { continue }
            if chip["isSelected"] as? Bool == true {
                continue
            }
            guard let title = YouTubeItemParser.text(from: chip["text"]),
                  let continuation = (
                      (chip["navigationEndpoint"] as? [String: Any])?["continuationCommand"]
                          as? [String: Any]
                  )?["token"] as? String,
                  !continuation.isEmpty,
                  seen.insert(title).inserted
            else {
                continue
            }
            result.append(YouTubeHomeChip(title: title, continuation: continuation))
        }
        return result
    }

    static func parseHomeShelves(_ data: [String: Any]) -> [YouTubeHomeSection] {
        guard let contents = richGridContents(data) else { return [] }

        var sections: [YouTubeHomeSection] = []
        var index = 0
        for entry in contents {
            guard let section = entry["richSectionRenderer"] as? [String: Any],
                  let content = section["content"] as? [String: Any],
                  let shelf = content["richShelfRenderer"] as? [String: Any],
                  let title = YouTubeItemParser.text(from: shelf["title"])
            else {
                continue
            }

            var videos: [YouTubeVideo] = []
            var shorts: [YouTubeVideo] = []
            var continuation: String?
            Self.collect(in: shelf["contents"] as Any, videos: &videos, shorts: &shorts, continuation: &continuation)
            let deduped = Self.deduplicate(videos)
            guard !deduped.isEmpty else { continue }

            index += 1
            sections.append(YouTubeHomeSection(
                id: "shelf-\(index)-\(title)",
                title: title,
                videos: deduped,
                kind: .shelf
            ))
        }
        return sections
    }

    private static func richGridContents(_ data: [String: Any]) -> [[String: Any]]? {
        self.richGridRenderer(data)?["contents"] as? [[String: Any]]
    }

    private static func chipBarContents(_ data: [String: Any]) -> [[String: Any]]? {
        guard let header = richGridRenderer(data)?["header"] as? [String: Any],
              let bar = header["feedFilterChipBarRenderer"] as? [String: Any]
        else {
            return nil
        }
        return bar["contents"] as? [[String: Any]]
    }

    private static func richGridRenderer(_ data: [String: Any]) -> [String: Any]? {
        let tabs = (
            (data["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"]
                as? [String: Any]
        )?["tabs"] as? [[String: Any]] ?? []

        for tab in tabs {
            guard let tabRenderer = tab["tabRenderer"] as? [String: Any],
                  let content = tabRenderer["content"] as? [String: Any],
                  let grid = content["richGridRenderer"] as? [String: Any]
            else {
                continue
            }
            return grid
        }
        return nil
    }

    static func collect(
        in value: Any,
        videos: inout [YouTubeVideo],
        continuation: inout String?
    ) {
        var shorts: [YouTubeVideo] = []
        Self.collect(in: value, videos: &videos, shorts: &shorts, continuation: &continuation)
    }

    static func collect(
        in value: Any,
        videos: inout [YouTubeVideo],
        shorts: inout [YouTubeVideo],
        continuation: inout String?
    ) {
        if let dict = value as? [String: Any] {
            if let shortsLockup = dict["shortsLockupViewModel"] as? [String: Any] {
                if let short = YouTubeItemParser.short(fromShortsLockup: shortsLockup) {
                    shorts.append(short)
                }
                return
            }

            if let video = YouTubeItemParser.video(fromAnyItem: dict) {
                if video.isShort {
                    shorts.append(video)
                } else {
                    videos.append(video)
                }
                return
            }

            if continuation == nil,
               let continuationItem = dict["continuationItemRenderer"] as? [String: Any]
            {
                continuation = Self.token(fromContinuationItem: continuationItem)
                return
            }

            for (key, nested) in dict {
                if key == "engagementPanels" || key == "playerOverlays" {
                    continue
                }
                Self.collect(in: nested, videos: &videos, shorts: &shorts, continuation: &continuation)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collect(in: element, videos: &videos, shorts: &shorts, continuation: &continuation)
            }
        }
    }

    static func token(fromContinuationItem item: [String: Any]) -> String? {
        (
            (item["continuationEndpoint"] as? [String: Any])?["continuationCommand"]
                as? [String: Any]
        )?["token"] as? String
    }

    static func deduplicate(_ videos: [YouTubeVideo]) -> [YouTubeVideo] {
        var seen = Set<String>()
        return videos.filter { seen.insert($0.videoId).inserted }
    }

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
