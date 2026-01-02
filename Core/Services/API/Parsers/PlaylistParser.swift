import Foundation
import os

/// Parser for playlist-related responses from YouTube Music API.
enum PlaylistParser {
    private static let logger = DiagnosticsLogger.api

    /// Parsed header data for a playlist.
    private struct HeaderData {
        var title: String = "Unknown Playlist"
        var description: String?
        var thumbnailURL: URL?
        var author: String?
        var duration: String?
    }

    /// Parses library playlists from browse response.
    static func parseLibraryPlaylists(_ data: [String: Any]) -> [Playlist] {
        var playlists: [Playlist] = []

        // Navigate to contents
        guard let contents = data["contents"] as? [String: Any],
              let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return []
        }

        for sectionData in sectionContents {
            // Try gridRenderer
            if let gridRenderer = sectionData["gridRenderer"] as? [String: Any],
               let items = gridRenderer["items"] as? [[String: Any]]
            {
                for itemData in items {
                    if let twoRowRenderer = itemData["musicTwoRowItemRenderer"] as? [String: Any],
                       let playlist = parsePlaylistFromTwoRowRenderer(twoRowRenderer)
                    {
                        playlists.append(playlist)
                    }
                }
            }

            // Try itemSectionRenderer > musicShelfRenderer
            if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
            {
                for itemContent in itemContents {
                    if let shelfRenderer = itemContent["musicShelfRenderer"] as? [String: Any],
                       let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
                    {
                        for shelfItem in shelfContents {
                            if let responsiveRenderer = shelfItem["musicResponsiveListItemRenderer"] as? [String: Any],
                               let playlist = parsePlaylistFromResponsiveRenderer(responsiveRenderer)
                            {
                                playlists.append(playlist)
                            }
                        }
                    }
                }
            }
        }

        return playlists
    }

    /// Parses playlist detail from browse response.
    static func parsePlaylistDetail(_ data: [String: Any], playlistId: String) -> PlaylistDetail {
        let header = self.parsePlaylistHeader(data)

        // Parse tracks
        let tracks = self.parsePlaylistTracks(data, fallbackThumbnailURL: header.thumbnailURL)

        let playlist = Playlist(
            id: playlistId,
            title: header.title,
            description: header.description,
            thumbnailURL: header.thumbnailURL,
            trackCount: tracks.count,
            author: header.author
        )

        return PlaylistDetail(playlist: playlist, tracks: tracks, duration: header.duration)
    }

    /// Parses playlist detail from browse response with pagination support.
    static func parsePlaylistWithContinuation(_ data: [String: Any], playlistId: String) -> PlaylistTracksResponse {
        let header = self.parsePlaylistHeader(data)

        // Parse tracks
        let tracks = self.parsePlaylistTracks(data, fallbackThumbnailURL: header.thumbnailURL)

        let playlist = Playlist(
            id: playlistId,
            title: header.title,
            description: header.description,
            thumbnailURL: header.thumbnailURL,
            trackCount: tracks.count,
            author: header.author
        )

        let detail = PlaylistDetail(playlist: playlist, tracks: tracks, duration: header.duration)
        let continuationToken = Self.extractPlaylistContinuationToken(from: data)

        Self.logger.debug("parsePlaylistWithContinuation: tracks=\(tracks.count), hasToken=\(continuationToken != nil)")

        return PlaylistTracksResponse(detail: detail, continuationToken: continuationToken)
    }

    /// Parses playlist continuation response.
    static func parsePlaylistContinuation(_ data: [String: Any]) -> PlaylistContinuationResponse {
        var tracks: [Song] = []
        var continuationToken: String?

        Self.logger.debug("Parsing playlist continuation. Top-level keys: \(Array(data.keys))")

        // Try legacy continuationContents format
        if let continuationContents = data["continuationContents"] as? [String: Any] {
            Self.logger.debug("Found continuationContents, keys: \(Array(continuationContents.keys))")
            if let shelfContinuation = continuationContents["musicShelfContinuation"] as? [String: Any],
               let contents = shelfContinuation["contents"] as? [[String: Any]]
            {
                Self.logger.debug("Found musicShelfContinuation with \(contents.count) items")
                for itemData in contents {
                    if let track = parseTrackItem(itemData, fallbackThumbnailURL: nil) {
                        tracks.append(track)
                    }
                }
                continuationToken = Self.extractTokenFromRenderer(shelfContinuation)
            }

            // Try musicPlaylistShelfContinuation
            if tracks.isEmpty,
               let playlistShelfContinuation = continuationContents["musicPlaylistShelfContinuation"] as? [String: Any],
               let contents = playlistShelfContinuation["contents"] as? [[String: Any]]
            {
                Self.logger.debug("Found musicPlaylistShelfContinuation with \(contents.count) items")
                for itemData in contents {
                    if let track = parseTrackItem(itemData, fallbackThumbnailURL: nil) {
                        tracks.append(track)
                    }
                }
                // Try legacy format first
                continuationToken = Self.extractTokenFromRenderer(playlistShelfContinuation)
                // Then try 2025 format
                if continuationToken == nil {
                    continuationToken = Self.extractTokenFromContents(contents)
                }
            }

            // Try sectionListContinuation (for sectionListRenderer-level continuations)
            if tracks.isEmpty,
               let sectionListContinuation = continuationContents["sectionListContinuation"] as? [String: Any],
               let sectionContents = sectionListContinuation["contents"] as? [[String: Any]]
            {
                Self.logger.debug("Found sectionListContinuation with \(sectionContents.count) sections")
                for sectionData in sectionContents {
                    if let playlistShelfRenderer = sectionData["musicPlaylistShelfRenderer"] as? [String: Any],
                       let shelfContents = playlistShelfRenderer["contents"] as? [[String: Any]]
                    {
                        Self.logger.debug("Found musicPlaylistShelfRenderer in sectionListContinuation with \(shelfContents.count) items")
                        for itemData in shelfContents {
                            if let track = parseTrackItem(itemData, fallbackThumbnailURL: nil) {
                                tracks.append(track)
                            }
                        }
                        // Try both token extraction formats
                        continuationToken = Self.extractTokenFromRenderer(playlistShelfRenderer)
                        if continuationToken == nil {
                            continuationToken = Self.extractTokenFromContents(shelfContents)
                        }
                    }
                    if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
                       let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
                    {
                        Self.logger.debug("Found musicShelfRenderer in sectionListContinuation with \(shelfContents.count) items")
                        for itemData in shelfContents {
                            if let track = parseTrackItem(itemData, fallbackThumbnailURL: nil) {
                                tracks.append(track)
                            }
                        }
                        continuationToken = Self.extractTokenFromRenderer(shelfRenderer)
                    }
                }
                // Check for continuation at sectionListContinuation level
                if continuationToken == nil {
                    continuationToken = Self.extractTokenFromRenderer(sectionListContinuation)
                }
            }
        }

        // Try 2025 format: onResponseReceivedActions -> appendContinuationItemsAction -> continuationItems
        if tracks.isEmpty,
           let onResponseReceivedActions = data["onResponseReceivedActions"] as? [[String: Any]],
           let firstAction = onResponseReceivedActions.first,
           let appendAction = firstAction["appendContinuationItemsAction"] as? [String: Any],
           let continuationItems = appendAction["continuationItems"] as? [[String: Any]]
        {
            Self.logger.debug("Using 2025 format continuation response with \(continuationItems.count) items")
            for itemData in continuationItems {
                if let track = parseTrackItem(itemData, fallbackThumbnailURL: nil) {
                    tracks.append(track)
                }
            }
            // Get next continuation token from last item
            continuationToken = Self.extractTokenFromContents(continuationItems)
        }

        if continuationToken != nil {
            Self.logger.debug("Playlist continuation parsed: \(tracks.count) tracks, has next token: true")
        } else {
            Self.logger.debug("Playlist continuation parsed: \(tracks.count) tracks, has next token: false")
        }

        return PlaylistContinuationResponse(tracks: tracks, continuationToken: continuationToken)
    }

    /// Parses liked songs response with pagination support.
    /// Checks both legacy continuations format and 2025 continuationItemRenderer format.
    static func parseLikedSongs(_ data: [String: Any]) -> LikedSongsResponse {
        let tracks = self.parsePlaylistTracks(data, fallbackThumbnailURL: nil)
        let continuationToken = Self.extractContinuationToken(from: data)
        Self.logger.info("Parsed \(tracks.count) liked songs, hasMore: \(continuationToken != nil)")
        return LikedSongsResponse(songs: tracks, continuationToken: continuationToken)
    }

    /// Parses liked songs continuation response.
    /// Handles both legacy musicShelfContinuation and 2025 onResponseReceivedActions formats.
    static func parseLikedSongsContinuation(_ data: [String: Any]) -> LikedSongsResponse {
        var tracks: [Song] = []

        // Try legacy musicShelfContinuation format
        if let continuationContents = data["continuationContents"] as? [String: Any],
           let shelfContinuation = continuationContents["musicShelfContinuation"] as? [String: Any],
           let contents = shelfContinuation["contents"] as? [[String: Any]]
        {
            Self.logger.debug("Parsing liked songs continuation (legacy format) with \(contents.count) items")
            for itemData in contents {
                if let track = parseTrackItem(itemData, fallbackThumbnailURL: nil) {
                    tracks.append(track)
                }
            }
        }

        // Try 2025 format: onResponseReceivedActions -> appendContinuationItemsAction
        if tracks.isEmpty,
           let onResponseReceivedActions = data["onResponseReceivedActions"] as? [[String: Any]],
           let firstAction = onResponseReceivedActions.first,
           let appendAction = firstAction["appendContinuationItemsAction"] as? [String: Any],
           let continuationItems = appendAction["continuationItems"] as? [[String: Any]]
        {
            Self.logger.debug("Parsing liked songs continuation (2025 format) with \(continuationItems.count) items")
            for itemData in continuationItems {
                if let track = parseTrackItem(itemData, fallbackThumbnailURL: nil) {
                    tracks.append(track)
                }
            }
        }

        let continuationToken = Self.extractContinuationTokenFromContinuation(data)
        Self.logger.debug("Liked songs continuation parsed: \(tracks.count) tracks, hasMore: \(continuationToken != nil)")
        return LikedSongsResponse(songs: tracks, continuationToken: continuationToken)
    }

    // MARK: - Continuation Token Extraction

    /// Extracts continuation token from initial browse response (liked songs).
    /// Checks both legacy continuations format and 2025 continuationItemRenderer format.
    private static func extractContinuationToken(from data: [String: Any]) -> String? {
        guard let contents = data["contents"] as? [String: Any],
              let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return nil
        }

        // Look for continuation in musicShelfRenderer
        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any] {
                // Try legacy continuations format
                if let token = Self.extractTokenFromRenderer(shelfRenderer) {
                    Self.logger.debug("Found liked songs continuation token (legacy format)")
                    return token
                }
                // Try 2025 format - continuationItemRenderer at end of contents
                if let shelfContents = shelfRenderer["contents"] as? [[String: Any]],
                   let token = Self.extractTokenFromContents(shelfContents)
                {
                    Self.logger.debug("Found liked songs continuation token (2025 format)")
                    return token
                }
            }
        }

        return nil
    }

    /// Extracts continuation token from a continuation response (liked songs).
    /// Checks both legacy continuations format and 2025 continuationItemRenderer format.
    private static func extractContinuationTokenFromContinuation(_ data: [String: Any]) -> String? {
        if let continuationContents = data["continuationContents"] as? [String: Any],
           let shelfContinuation = continuationContents["musicShelfContinuation"] as? [String: Any]
        {
            // Try legacy continuations format
            if let token = extractTokenFromRenderer(shelfContinuation) {
                self.logger.debug("Found liked songs continuation token from continuation (legacy format)")
                return token
            }
            // Try 2025 format - continuationItemRenderer at end of contents
            if let contents = shelfContinuation["contents"] as? [[String: Any]],
               let token = Self.extractTokenFromContents(contents)
            {
                Self.logger.debug("Found liked songs continuation token from continuation (2025 format)")
                return token
            }
        }

        // Try 2025 format: onResponseReceivedActions -> appendContinuationItemsAction
        if let onResponseReceivedActions = data["onResponseReceivedActions"] as? [[String: Any]],
           let firstAction = onResponseReceivedActions.first,
           let appendAction = firstAction["appendContinuationItemsAction"] as? [String: Any],
           let continuationItems = appendAction["continuationItems"] as? [[String: Any]],
           let token = Self.extractTokenFromContents(continuationItems)
        {
            Self.logger.debug("Found liked songs continuation token from 2025 format response")
            return token
        }

        return nil
    }

    /// Extracts continuation token from playlist browse response (handles multiple renderer types).
    private static func extractPlaylistContinuationToken(from data: [String: Any]) -> String? {
        guard let contents = data["contents"] as? [String: Any] else {
            self.logger.debug("No contents key found in playlist response. Top keys: \(Array(data.keys))")
            return nil
        }

        Self.logger.debug("Contents keys: \(Array(contents.keys))")

        // Try singleColumnBrowseResultsRenderer path
        if let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
           let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
           let firstTab = tabs.first,
           let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
           let tabContent = tabRenderer["content"] as? [String: Any],
           let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any]
        {
            // First check for continuation at sectionListRenderer level (like Home page)
            if let token = Self.extractTokenFromRenderer(sectionListRenderer) {
                Self.logger.debug("Found continuation token at sectionListRenderer level")
                return token
            }

            if let sectionContents = sectionListRenderer["contents"] as? [[String: Any]] {
                Self.logger.debug("Found singleColumnBrowseResultsRenderer with \(sectionContents.count) sections")
                // Log renderer types found
                for (idx, sectionData) in sectionContents.enumerated() {
                    let rendererKeys = sectionData.keys.filter { $0.hasSuffix("Renderer") }
                    Self.logger.debug("Section \(idx) renderer keys: \(rendererKeys)")
                }
                // Look for continuation in musicShelfRenderer or musicPlaylistShelfRenderer
                for sectionData in sectionContents {
                    if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any] {
                        Self.logger.debug("Found musicShelfRenderer, has continuations: \(shelfRenderer["continuations"] != nil)")
                        if let token = Self.extractTokenFromRenderer(shelfRenderer) {
                            Self.logger.debug("Found continuation token in musicShelfRenderer")
                            return token
                        }
                    }
                    if let playlistShelfRenderer = sectionData["musicPlaylistShelfRenderer"] as? [String: Any] {
                        Self.logger.debug("Found musicPlaylistShelfRenderer, has continuations: \(playlistShelfRenderer["continuations"] != nil)")
                        // Try legacy continuations format first
                        if let token = Self.extractTokenFromRenderer(playlistShelfRenderer) {
                            Self.logger.debug("Found continuation token in musicPlaylistShelfRenderer (legacy format)")
                            return token
                        }
                        // Try 2025 format - token at last item of contents
                        if let contents = playlistShelfRenderer["contents"] as? [[String: Any]],
                           let token = Self.extractTokenFromContents(contents)
                        {
                            return token
                        }
                    }
                }
            }
        }

        // Try twoColumnBrowseResultsRenderer path
        if let twoColumnRenderer = contents["twoColumnBrowseResultsRenderer"] as? [String: Any] {
            Self.logger.debug("Found twoColumnBrowseResultsRenderer, keys: \(Array(twoColumnRenderer.keys))")
            // Try secondaryContents path
            if let secondaryContents = twoColumnRenderer["secondaryContents"] as? [String: Any],
               let sectionListRenderer = secondaryContents["sectionListRenderer"] as? [String: Any]
            {
                // First check for continuation at sectionListRenderer level
                if let token = Self.extractTokenFromRenderer(sectionListRenderer) {
                    Self.logger.debug("Found continuation token at secondaryContents sectionListRenderer level")
                    return token
                }

                if let sectionContents = sectionListRenderer["contents"] as? [[String: Any]] {
                    Self.logger.debug("Found secondaryContents with \(sectionContents.count) sections")
                    for sectionData in sectionContents {
                        if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any] {
                            Self.logger.debug("Found musicShelfRenderer in secondaryContents, has continuations: \(shelfRenderer["continuations"] != nil)")
                            if let token = Self.extractTokenFromRenderer(shelfRenderer) {
                                Self.logger.debug("Found continuation token in secondaryContents musicShelfRenderer")
                                return token
                            }
                        }
                        if let playlistShelfRenderer = sectionData["musicPlaylistShelfRenderer"] as? [String: Any] {
                            Self.logger.debug("Found musicPlaylistShelfRenderer in secondaryContents, has continuations: \(playlistShelfRenderer["continuations"] != nil)")
                            // Try legacy continuations format first
                            if let token = Self.extractTokenFromRenderer(playlistShelfRenderer) {
                                Self.logger.debug("Found continuation token in secondaryContents musicPlaylistShelfRenderer (legacy format)")
                                return token
                            }
                            // Try 2025 format - token at last item of contents
                            if let contents = playlistShelfRenderer["contents"] as? [[String: Any]],
                               let token = Self.extractTokenFromContents(contents)
                            {
                                return token
                            }
                        }
                    }
                }
            }

            // Try tabs path
            if let tabs = twoColumnRenderer["tabs"] as? [[String: Any]],
               let firstTab = tabs.first,
               let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
               let tabContent = tabRenderer["content"] as? [String: Any],
               let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
               let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
            {
                Self.logger.debug("Found twoColumnBrowseResultsRenderer tabs with \(sectionContents.count) sections")
                for sectionData in sectionContents {
                    if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
                       let token = Self.extractTokenFromRenderer(shelfRenderer)
                    {
                        Self.logger.debug("Found continuation token in tabs musicShelfRenderer")
                        return token
                    }
                    if let playlistShelfRenderer = sectionData["musicPlaylistShelfRenderer"] as? [String: Any],
                       let token = Self.extractTokenFromRenderer(playlistShelfRenderer)
                    {
                        Self.logger.debug("Found continuation token in tabs musicPlaylistShelfRenderer")
                        return token
                    }
                }
            }
        }

        Self.logger.debug("No continuation token found in playlist response")
        return nil
    }

    /// Extracts token from a shelf renderer's continuations array (legacy format).
    private static func extractTokenFromRenderer(_ renderer: [String: Any]) -> String? {
        guard let continuations = renderer["continuations"] as? [[String: Any]],
              let firstContinuation = continuations.first,
              let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
              let token = nextContinuationData["continuation"] as? String
        else {
            return nil
        }
        return token
    }

    /// Extracts continuation token from the last item in a contents array (2025 format).
    /// YouTube Music now uses continuationItemRenderer at the end of the contents array.
    private static func extractTokenFromContents(_ contents: [[String: Any]]) -> String? {
        guard let lastItem = contents.last,
              let continuationItemRenderer = lastItem["continuationItemRenderer"] as? [String: Any],
              let continuationEndpoint = continuationItemRenderer["continuationEndpoint"] as? [String: Any],
              let continuationCommand = continuationEndpoint["continuationCommand"] as? [String: Any],
              let token = continuationCommand["token"] as? String
        else {
            return nil
        }
        Self.logger.debug("Found continuation token in continuationItemRenderer (2025 format)")
        return token
    }

    /// Extracts continuation token from a playlist continuation response.
    private static func extractPlaylistContinuationTokenFromContinuation(_ data: [String: Any]) -> String? {
        guard let continuationContents = data["continuationContents"] as? [String: Any] else {
            return nil
        }

        // Try musicShelfContinuation
        if let shelfContinuation = continuationContents["musicShelfContinuation"] as? [String: Any],
           let token = Self.extractTokenFromRenderer(shelfContinuation)
        {
            return token
        }

        // Try musicPlaylistShelfContinuation
        if let playlistShelfContinuation = continuationContents["musicPlaylistShelfContinuation"] as? [String: Any],
           let token = Self.extractTokenFromRenderer(playlistShelfContinuation)
        {
            return token
        }

        return nil
    }

    // MARK: - Header Parsing

    private static func parsePlaylistHeader(_ data: [String: Any]) -> HeaderData {
        var header = HeaderData()

        guard let headerDict = data["header"] as? [String: Any] else {
            return header
        }

        // Try each header renderer type in order of preference
        Self.applyDetailHeaderRenderer(from: headerDict, to: &header)
        Self.applyImmersiveHeaderRenderer(from: headerDict, to: &header)
        Self.applyVisualHeaderRenderer(from: headerDict, to: &header)
        Self.applyEditablePlaylistHeaderRenderer(from: headerDict, to: &header)

        return header
    }

    private static func applyDetailHeaderRenderer(from headerDict: [String: Any], to header: inout HeaderData) {
        guard let renderer = headerDict["musicDetailHeaderRenderer"] as? [String: Any] else { return }

        if let text = ParsingHelpers.extractTitle(from: renderer) {
            header.title = text
        }

        if let descData = renderer["description"] as? [String: Any],
           let runs = descData["runs"] as? [[String: Any]]
        {
            header.description = runs.compactMap { $0["text"] as? String }.joined()
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: renderer)
        header.thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        if let subtitleData = renderer["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            header.author = runs.compactMap { $0["text"] as? String }.first
        }

        if let secondSubtitleData = renderer["secondSubtitle"] as? [String: Any],
           let runs = secondSubtitleData["runs"] as? [[String: Any]]
        {
            header.duration = runs.compactMap { $0["text"] as? String }.joined()
        }
    }

    private static func applyImmersiveHeaderRenderer(from headerDict: [String: Any], to header: inout HeaderData) {
        guard let renderer = headerDict["musicImmersiveHeaderRenderer"] as? [String: Any] else { return }

        if header.title == "Unknown Playlist",
           let text = ParsingHelpers.extractTitle(from: renderer)
        {
            header.title = text
        }

        if header.thumbnailURL == nil {
            let thumbnails = ParsingHelpers.extractThumbnails(from: renderer)
            header.thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        }

        if header.description == nil,
           let descData = renderer["description"] as? [String: Any],
           let runs = descData["runs"] as? [[String: Any]]
        {
            header.description = runs.compactMap { $0["text"] as? String }.joined()
        }

        if header.author == nil,
           let subtitleData = renderer["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            header.author = runs.compactMap { $0["text"] as? String }.first
        }
    }

    private static func applyVisualHeaderRenderer(from headerDict: [String: Any], to header: inout HeaderData) {
        guard let renderer = headerDict["musicVisualHeaderRenderer"] as? [String: Any] else { return }

        if header.title == "Unknown Playlist",
           let text = ParsingHelpers.extractTitle(from: renderer)
        {
            header.title = text
        }

        if header.thumbnailURL == nil {
            let thumbnails = ParsingHelpers.extractThumbnails(from: renderer)
            header.thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        }
    }

    private static func applyEditablePlaylistHeaderRenderer(from headerDict: [String: Any], to header: inout HeaderData) {
        guard let editableHeader = headerDict["musicEditablePlaylistDetailHeaderRenderer"] as? [String: Any],
              let nestedHeaderData = editableHeader["header"] as? [String: Any],
              let detailHeader = nestedHeaderData["musicDetailHeaderRenderer"] as? [String: Any]
        else { return }

        if header.title == "Unknown Playlist",
           let text = ParsingHelpers.extractTitle(from: detailHeader)
        {
            header.title = text
        }

        if header.thumbnailURL == nil {
            let thumbnails = ParsingHelpers.extractThumbnails(from: detailHeader)
            header.thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        }

        if header.author == nil,
           let subtitleData = detailHeader["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            header.author = runs.compactMap { $0["text"] as? String }.first
        }
    }

    // MARK: - Track Parsing

    private static func parsePlaylistTracks(_ data: [String: Any], fallbackThumbnailURL: URL?) -> [Song] {
        var tracks: [Song] = []

        if let contents = data["contents"] as? [String: Any] {
            // Try singleColumnBrowseResultsRenderer path
            if let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
               let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
               let firstTab = tabs.first,
               let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
               let tabContent = tabRenderer["content"] as? [String: Any],
               let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
               let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
            {
                tracks.append(contentsOf: self.parseTracksFromSections(sectionContents, fallbackThumbnailURL: fallbackThumbnailURL))
            }

            // Try twoColumnBrowseResultsRenderer path
            if tracks.isEmpty,
               let twoColumnRenderer = contents["twoColumnBrowseResultsRenderer"] as? [String: Any]
            {
                if let secondaryContents = twoColumnRenderer["secondaryContents"] as? [String: Any],
                   let sectionListRenderer = secondaryContents["sectionListRenderer"] as? [String: Any],
                   let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
                {
                    tracks.append(contentsOf: self.parseTracksFromSections(sectionContents, fallbackThumbnailURL: fallbackThumbnailURL))
                }

                if tracks.isEmpty,
                   let tabs = twoColumnRenderer["tabs"] as? [[String: Any]],
                   let firstTab = tabs.first,
                   let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
                   let tabContent = tabRenderer["content"] as? [String: Any],
                   let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
                   let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
                {
                    tracks.append(contentsOf: self.parseTracksFromSections(sectionContents, fallbackThumbnailURL: fallbackThumbnailURL))
                }
            }
        }

        // Try recursive search if no tracks found
        if tracks.isEmpty {
            if let contents = data["contents"] as? [String: Any] {
                for (_, value) in contents {
                    if let renderer = value as? [String: Any] {
                        tracks.append(contentsOf: self.findTracksRecursively(in: renderer, depth: 0, fallbackThumbnailURL: fallbackThumbnailURL))
                        if !tracks.isEmpty {
                            break
                        }
                    }
                }
            }
        }

        return tracks
    }

    private static func parseTracksFromSections(_ sections: [[String: Any]], fallbackThumbnailURL: URL?) -> [Song] {
        var tracks: [Song] = []

        for sectionData in sections {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let track = parseTrackItem(itemData, fallbackThumbnailURL: fallbackThumbnailURL) {
                        tracks.append(track)
                    }
                }
            }

            if let playlistShelfRenderer = sectionData["musicPlaylistShelfRenderer"] as? [String: Any],
               let playlistContents = playlistShelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in playlistContents {
                    if let track = parseTrackItem(itemData, fallbackThumbnailURL: fallbackThumbnailURL) {
                        tracks.append(track)
                    }
                }
            }
        }

        return tracks
    }

    private static func parseTrackItem(_ data: [String: Any], fallbackThumbnailURL: URL?) -> Song? {
        guard let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] else {
            return nil
        }

        guard let videoId = ParsingHelpers.extractVideoId(from: responsiveRenderer) else {
            return nil
        }

        let title = ParsingHelpers.extractTitleFromFlexColumns(responsiveRenderer) ?? "Unknown"
        let artists = ParsingHelpers.extractArtistsFromFlexColumns(responsiveRenderer)
        let thumbnails = ParsingHelpers.extractThumbnails(from: responsiveRenderer)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) } ?? fallbackThumbnailURL
        let duration = ParsingHelpers.extractDurationFromFlexColumns(responsiveRenderer)
        let album = ParsingHelpers.extractAlbumFromFlexColumns(responsiveRenderer)

        return Song(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            duration: duration,
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )
    }

    private static func findTracksRecursively(in data: [String: Any], depth: Int, fallbackThumbnailURL: URL?) -> [Song] {
        guard depth < 10 else { return [] }

        var tracks: [Song] = []

        if let contents = data["contents"] as? [[String: Any]] {
            for item in contents {
                if let track = parseTrackItem(item, fallbackThumbnailURL: fallbackThumbnailURL) {
                    tracks.append(track)
                }
            }
        }

        if tracks.isEmpty {
            for (_, value) in data {
                if let dict = value as? [String: Any] {
                    tracks.append(contentsOf: self.findTracksRecursively(in: dict, depth: depth + 1, fallbackThumbnailURL: fallbackThumbnailURL))
                } else if let array = value as? [[String: Any]] {
                    for item in array {
                        tracks.append(contentsOf: self.findTracksRecursively(in: item, depth: depth + 1, fallbackThumbnailURL: fallbackThumbnailURL))
                    }
                }
                if !tracks.isEmpty { break }
            }
        }

        return tracks
    }

    // MARK: - Helper Parsers

    private static func parsePlaylistFromTwoRowRenderer(_ data: [String: Any]) -> Playlist? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            return nil
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitle(from: data) ?? "Unknown Playlist"

        return Playlist(
            id: browseId,
            title: title,
            description: nil,
            thumbnailURL: thumbnailURL,
            trackCount: nil,
            author: ParsingHelpers.extractSubtitle(from: data)
        )
    }

    private static func parsePlaylistFromResponsiveRenderer(_ data: [String: Any]) -> Playlist? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String,
              browseId.hasPrefix("VL") || browseId.hasPrefix("PL")
        else {
            return nil
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown Playlist"

        return Playlist(
            id: browseId,
            title: title,
            description: nil,
            thumbnailURL: thumbnailURL,
            trackCount: nil,
            author: ParsingHelpers.extractSubtitleFromFlexColumns(data)
        )
    }

    // MARK: - Queue Response Parsing

    /// Parses tracks from a music/get_queue response.
    /// This endpoint returns ALL tracks for a playlist in a single request (no pagination needed).
    static func parseQueueTracks(_ data: [String: Any]) -> [Song] {
        guard let queueDatas = data["queueDatas"] as? [[String: Any]] else {
            self.logger.debug("No queueDatas found in queue response")
            return []
        }

        Self.logger.debug("Parsing queue response with \(queueDatas.count) items")

        var tracks: [Song] = []

        for queueData in queueDatas {
            guard let content = queueData["content"] as? [String: Any] else {
                continue
            }

            // Try to get the playlistPanelVideoRenderer - it can be:
            // 1. Directly in content: content.playlistPanelVideoRenderer
            // 2. Wrapped: content.playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer
            let renderer: [String: Any]?
            if let directRenderer = content["playlistPanelVideoRenderer"] as? [String: Any] {
                renderer = directRenderer
            } else if let wrapper = content["playlistPanelVideoWrapperRenderer"] as? [String: Any],
                      let primaryRenderer = wrapper["primaryRenderer"] as? [String: Any],
                      let wrappedRenderer = primaryRenderer["playlistPanelVideoRenderer"] as? [String: Any]
            {
                renderer = wrappedRenderer
            } else {
                continue
            }

            guard let renderer, let videoId = renderer["videoId"] as? String else {
                continue
            }

            // Extract title
            let title = (renderer["title"] as? [String: Any])?["runs"]
                .flatMap { ($0 as? [[String: Any]])?.first?["text"] as? String }
                ?? "Unknown"

            // Extract artist from shortBylineText
            let artistRuns = (renderer["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]
            let artistName = artistRuns?.first?["text"] as? String ?? "Unknown Artist"

            // Extract artist ID if available
            var artistId: String?
            if let firstRun = artistRuns?.first,
               let navEndpoint = firstRun["navigationEndpoint"] as? [String: Any],
               let browseEndpoint = navEndpoint["browseEndpoint"] as? [String: Any]
            {
                artistId = browseEndpoint["browseId"] as? String
            }

            // Extract duration
            let durationText = (renderer["lengthText"] as? [String: Any])?["runs"]
                .flatMap { ($0 as? [[String: Any]])?.first?["text"] as? String }

            // Extract thumbnail
            let thumbnails = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            let thumbnailURL = thumbnails?.last?["url"]
                .flatMap { $0 as? String }
                .flatMap { URL(string: $0) }

            let artist = Artist(
                id: artistId ?? "",
                name: artistName,
                thumbnailURL: nil
            )

            // Convert duration text to TimeInterval
            let durationSeconds: TimeInterval? = durationText.flatMap { ParsingHelpers.parseDuration($0) }

            let song = Song(
                id: videoId,
                title: title,
                artists: [artist],
                album: nil,
                duration: durationSeconds,
                thumbnailURL: thumbnailURL,
                videoId: videoId
            )

            tracks.append(song)
        }

        Self.logger.debug("Parsed \(tracks.count) tracks from queue response")
        return tracks
    }
}
