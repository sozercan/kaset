import Foundation

/// Parses song metadata from YouTube Music API responses.
enum SongMetadataParser {
    private static let logger = DiagnosticsLogger.api

    /// Contains parsed menu data including feedback tokens, library status, and like status.
    struct MenuParseResult {
        var feedbackTokens: FeedbackTokens?
        var isInLibrary: Bool
        var likeStatus: LikeStatus?
    }

    /// Parses song metadata from the "next" endpoint response.
    /// - Parameters:
    ///   - data: The response from the "next" endpoint
    ///   - videoId: The video ID of the song
    /// - Returns: A fully parsed Song object
    /// - Throws: `YTMusicError.parseError` if the structure cannot be parsed
    static func parse(_ data: [String: Any], videoId: String) throws -> Song {
        let panelVideoRenderer = try extractPanelVideoRenderer(from: data, videoId: videoId)

        let title = self.parseTitle(from: panelVideoRenderer)
        let artists = self.parseArtists(from: panelVideoRenderer)
        let thumbnailURL = self.parseThumbnail(from: panelVideoRenderer)
        let duration = self.parseDuration(from: panelVideoRenderer)
        let menuData = self.parseMenuData(from: panelVideoRenderer)
        let musicVideoType = self.parseMusicVideoType(from: panelVideoRenderer)

        return Song(
            id: videoId,
            title: title,
            artists: artists,
            album: nil,
            duration: duration,
            thumbnailURL: thumbnailURL,
            videoId: videoId,
            musicVideoType: musicVideoType,
            likeStatus: menuData.likeStatus,
            isInLibrary: menuData.isInLibrary,
            feedbackTokens: menuData.feedbackTokens,
            isExplicit: ParsingHelpers.extractIsExplicit(from: panelVideoRenderer)
        )
    }

    /// Extracts the playlistPanelVideoRenderer from the next endpoint response.
    /// Handles both direct and wrapped renderer structures.
    static func extractPanelVideoRenderer(from data: [String: Any], videoId: String) throws -> [String: Any] {
        guard let contents = data["contents"] as? [String: Any],
              let watchNextRenderer = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbedRenderer = watchNextRenderer["tabbedRenderer"] as? [String: Any],
              let watchNextTabbedResults = tabbedRenderer["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = watchNextTabbedResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let musicQueueRenderer = tabContent["musicQueueRenderer"] as? [String: Any],
              let queueContent = musicQueueRenderer["content"] as? [String: Any],
              let playlistPanelRenderer = queueContent["playlistPanelRenderer"] as? [String: Any],
              let playlistContents = playlistPanelRenderer["contents"] as? [[String: Any]],
              let firstItem = playlistContents.first
        else {
            throw YTMusicError.parseError(message: "Failed to parse song metadata for \(videoId)")
        }

        // Handle both direct and wrapped renderer structures
        // Direct: firstItem.playlistPanelVideoRenderer
        // Wrapped: firstItem.playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer
        if let direct = firstItem["playlistPanelVideoRenderer"] as? [String: Any] {
            return direct
        } else if let wrapper = firstItem["playlistPanelVideoWrapperRenderer"] as? [String: Any],
                  let primary = wrapper["primaryRenderer"] as? [String: Any],
                  let wrapped = primary["playlistPanelVideoRenderer"] as? [String: Any]
        {
            return wrapped
        }

        throw YTMusicError.parseError(message: "Failed to parse song metadata for \(videoId)")
    }

    /// Parses the song title from the panel video renderer.
    static func parseTitle(from renderer: [String: Any]) -> String {
        if let titleData = renderer["title"] as? [String: Any],
           let runs = titleData["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            return text
        }
        return "Unknown"
    }

    /// Parses artists from the panel video renderer's longBylineText.
    static func parseArtists(from renderer: [String: Any]) -> [Artist] {
        var artists: [Artist] = []
        guard let bylineData = renderer["longBylineText"] as? [String: Any],
              let runs = bylineData["runs"] as? [[String: Any]]
        else { return artists }

        for run in runs {
            guard let text = run["text"] as? String else { continue }
            if text == " • " || text == " · " {
                break
            }
            guard text != " & ", text != ", " else { continue }

            let artistId: String = if let navEndpoint = run["navigationEndpoint"] as? [String: Any],
                                      let browseEndpoint = navEndpoint["browseEndpoint"] as? [String: Any],
                                      let browseId = browseEndpoint["browseId"] as? String
            {
                browseId
            } else {
                // Generate stable ID from artist name when no browse ID available
                ParsingHelpers.stableId(title: "artist", components: text)
            }
            artists.append(Artist(id: artistId, name: text))
        }
        return artists
    }

    /// Parses the thumbnail URL from the panel video renderer.
    static func parseThumbnail(from renderer: [String: Any]) -> URL? {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]],
              let lastThumb = thumbnails.last,
              let urlString = lastThumb["url"] as? String
        else { return nil }

        let normalizedURL = urlString.hasPrefix("//") ? "https:" + urlString : urlString
        return URL(string: normalizedURL)
    }

    /// Parses the duration from the panel video renderer.
    static func parseDuration(from renderer: [String: Any]) -> TimeInterval? {
        guard let lengthText = renderer["lengthText"] as? [String: Any],
              let runs = lengthText["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let text = firstRun["text"] as? String
        else { return nil }

        return ParsingHelpers.parseDuration(text)
    }

    /// Parses the music video type from the panel video renderer's navigation endpoint.
    /// Path: navigationEndpoint.watchEndpoint.watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType
    static func parseMusicVideoType(from renderer: [String: Any]) -> MusicVideoType? {
        guard let navEndpoint = renderer["navigationEndpoint"] as? [String: Any],
              let watchEndpoint = navEndpoint["watchEndpoint"] as? [String: Any],
              let configs = watchEndpoint["watchEndpointMusicSupportedConfigs"] as? [String: Any],
              let musicConfig = configs["watchEndpointMusicConfig"] as? [String: Any],
              let typeString = musicConfig["musicVideoType"] as? String
        else { return nil }

        return MusicVideoType(rawValue: typeString)
    }

    /// Parses menu data (feedbackTokens, library status, like status) from the panel video renderer.
    static func parseMenuData(from renderer: [String: Any]) -> MenuParseResult {
        var result = MenuParseResult(feedbackTokens: nil, isInLibrary: false, likeStatus: nil)

        guard let menu = renderer["menu"] as? [String: Any],
              let menuRenderer = menu["menuRenderer"] as? [String: Any]
        else { return result }

        // Library/feedback tokens live in `items`; like status lives in `topLevelButtons` or in a
        // like toggle in `items`. Parse them independently so a menu that carries one but not the
        // other still yields what it does have.
        if let items = menuRenderer["items"] as? [[String: Any]] {
            for item in items {
                self.parseMenuServiceItem(item, into: &result)
                self.parseToggleMenuItem(item, into: &result)
            }
        }

        result.likeStatus = Self.parseLikeStatus(from: renderer)
        return result
    }

    /// Parses a row's current like status from its own menu.
    /// An explicit `topLevelButtons` like button wins; otherwise the rating toggle in `items` is
    /// inverted. A pending LIKE only proves "not liked" (INDIFFERENT and DISLIKE look the same),
    /// so it stays unknown and the like-status cache decides.
    static func parseLikeStatus(from renderer: [String: Any]) -> LikeStatus? {
        guard let menu = renderer["menu"] as? [String: Any],
              let menuRenderer = menu["menuRenderer"] as? [String: Any]
        else { return nil }

        return Self.parseDirectLikeStatus(from: menuRenderer)
            ?? Self.parseToggleLikeStatus(from: menuRenderer, videoId: renderer["videoId"] as? String)
    }

    /// Parses a menuServiceItemRenderer for library tokens.
    private static func parseMenuServiceItem(_ item: [String: Any], into result: inout MenuParseResult) {
        guard let menuServiceItem = item["menuServiceItemRenderer"] as? [String: Any],
              let icon = menuServiceItem["icon"] as? [String: Any],
              let iconType = icon["iconType"] as? String
        else { return }

        let token = self.extractFeedbackToken(from: menuServiceItem, key: "serviceEndpoint")

        switch iconType {
        case "LIBRARY_ADD", "BOOKMARK_BORDER":
            if let token {
                result.feedbackTokens = FeedbackTokens(add: token, remove: nil)
            }
        case "LIBRARY_REMOVE", "BOOKMARK":
            result.isInLibrary = true
            if let token {
                result.feedbackTokens = FeedbackTokens(add: nil, remove: token)
            }
        default:
            break
        }
    }

    /// Parses a toggleMenuServiceItemRenderer for library tokens.
    private static func parseToggleMenuItem(_ item: [String: Any], into result: inout MenuParseResult) {
        guard let toggleItem = item["toggleMenuServiceItemRenderer"] as? [String: Any],
              !Self.containsLikeEndpoint(in: toggleItem),
              let defaultIcon = toggleItem["defaultIcon"] as? [String: Any],
              let iconType = defaultIcon["iconType"] as? String
        else { return }

        let defaultToken = self.extractFeedbackToken(from: toggleItem, key: "defaultServiceEndpoint")
        let toggledToken = self.extractFeedbackToken(from: toggleItem, key: "toggledServiceEndpoint")

        if iconType == "LIBRARY_ADD" || iconType == "BOOKMARK_BORDER" {
            result.feedbackTokens = FeedbackTokens(add: defaultToken, remove: toggledToken)
        } else if iconType == "LIBRARY_REMOVE" || iconType == "BOOKMARK" {
            result.isInLibrary = true
            result.feedbackTokens = FeedbackTokens(add: toggledToken, remove: defaultToken)
        }
    }

    /// Extracts a feedback token from a service endpoint.
    private static func extractFeedbackToken(from dict: [String: Any], key: String) -> String? {
        guard let endpoint = dict[key] as? [String: Any],
              let feedback = endpoint["feedbackEndpoint"] as? [String: Any]
        else { return nil }
        return feedback["feedbackToken"] as? String
    }

    /// Parses the current status from a top-level like button.
    private static func parseDirectLikeStatus(from menuRenderer: [String: Any]) -> LikeStatus? {
        let buttons = menuRenderer["topLevelButtons"] as? [[String: Any]] ?? []
        for button in buttons {
            if let likeButton = button["likeButtonRenderer"] as? [String: Any],
               let rawStatus = likeButton["likeStatus"] as? String,
               let likeStatus = LikeStatus(rawValue: rawStatus)
            {
                return likeStatus
            }
        }
        return nil
    }

    /// Inverts a rating toggle: its active endpoint is the rating a click would request.
    /// Only a pending INDIFFERENT is conclusive; it clears the rating the other endpoint
    /// restores (LIKE when that endpoint is absent, as ytmusicapi assumes).
    private static func parseToggleLikeStatus(from menuRenderer: [String: Any], videoId: String?) -> LikeStatus? {
        let items = menuRenderer["items"] as? [[String: Any]] ?? []
        for item in items {
            guard let toggleItem = item["toggleMenuServiceItemRenderer"] as? [String: Any] else { continue }
            let isToggled = (toggleItem["isToggled"] as? Bool) == true
            let activeKey = isToggled ? "toggledServiceEndpoint" : "defaultServiceEndpoint"
            let inactiveKey = isToggled ? "defaultServiceEndpoint" : "toggledServiceEndpoint"
            guard let activeEndpoint = Self.likeEndpoint(in: toggleItem, key: activeKey),
                  activeEndpoint["status"] as? String == LikeStatus.indifferent.rawValue
            else { continue }

            let targetVideoId = (activeEndpoint["target"] as? [String: Any])?["videoId"] as? String
            if let targetVideoId, let videoId, targetVideoId != videoId {
                continue
            }
            let restoredStatus = Self.likeEndpoint(in: toggleItem, key: inactiveKey)?["status"] as? String
            return restoredStatus == LikeStatus.dislike.rawValue ? .dislike : .like
        }
        return nil
    }

    private static func likeEndpoint(in toggleItem: [String: Any], key: String) -> [String: Any]? {
        (toggleItem[key] as? [String: Any])?["likeEndpoint"] as? [String: Any]
    }

    private static func containsLikeEndpoint(in toggleItem: [String: Any]) -> Bool {
        ["defaultServiceEndpoint", "toggledServiceEndpoint"].contains {
            Self.likeEndpoint(in: toggleItem, key: $0) != nil
        }
    }
}
