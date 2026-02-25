// swiftlint:disable file_length
import Foundation
import os

// swiftlint:disable type_body_length
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
        self.parseLibraryContent(data).playlists
    }

    /// Result type for library content parsing containing both playlists and podcast shows.
    struct LibraryContent {
        let playlists: [Playlist]
        let podcastShows: [PodcastShow]
    }

    /// Parses library content from browse response, returning both playlists and podcast shows.
    static func parseLibraryContent(_ data: [String: Any]) -> LibraryContent {
        var playlists: [Playlist] = []
        var podcastShows: [PodcastShow] = []

        // Navigate to contents
        guard let contents = data["contents"] as? [String: Any],
              let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any]
        else {
            return LibraryContent(playlists: [], podcastShows: [])
        }

        guard let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return LibraryContent(playlists: [], podcastShows: [])
        }

        for sectionData in sectionContents {
            // Try gridRenderer
            if let gridRenderer = sectionData["gridRenderer"] as? [String: Any],
               let items = gridRenderer["items"] as? [[String: Any]]
            {
                for itemData in items {
                    if let twoRowRenderer = itemData["musicTwoRowItemRenderer"] as? [String: Any] {
                        Self.parseLibraryItem(
                            twoRowRenderer,
                            playlists: &playlists,
                            podcastShows: &podcastShows
                        )
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
                            if let responsiveRenderer = shelfItem["musicResponsiveListItemRenderer"] as? [String: Any] {
                                Self.parseLibraryItemFromResponsive(
                                    responsiveRenderer,
                                    playlists: &playlists,
                                    podcastShows: &podcastShows
                                )
                            }
                        }
                    }
                }
            }

            // Try musicShelfRenderer directly
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for shelfItem in shelfContents {
                    if let responsiveRenderer = shelfItem["musicResponsiveListItemRenderer"] as? [String: Any] {
                        Self.parseLibraryItemFromResponsive(
                            responsiveRenderer,
                            playlists: &playlists,
                            podcastShows: &podcastShows
                        )
                    }
                }
            }
        }

        return LibraryContent(playlists: playlists, podcastShows: podcastShows)
    }

    /// Parses a library item from twoRowRenderer, adding to the appropriate array.
    private static func parseLibraryItem(
        _ data: [String: Any],
        playlists: inout [Playlist],
        podcastShows: inout [PodcastShow]
    ) {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            self.logger.debug("parseLibraryItem: No browseId found")
            return
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitle(from: data) ?? "Unknown"
        let subtitle = ParsingHelpers.extractSubtitle(from: data)

        Self.logger.info("parseLibraryItem: browseId=\(browseId, privacy: .public), title=\(title, privacy: .public)")

        if browseId.hasPrefix("MPSPP") {
            // Podcast show
            let show = PodcastShow(
                id: browseId,
                title: title,
                author: subtitle,
                description: nil,
                thumbnailURL: thumbnailURL,
                episodeCount: nil
            )
            podcastShows.append(show)
            Self.logger.info("parseLibraryItem: Added podcast show: \(title)")
        } else if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RDCLAK") {
            // Playlist (VL prefix for saved playlists, PL for playlist IDs, RDCLAK for radio playlists)
            let playlist = Playlist(
                id: browseId,
                title: title,
                description: nil,
                thumbnailURL: thumbnailURL,
                trackCount: nil,
                author: subtitle
            )
            playlists.append(playlist)
            Self.logger.info("parseLibraryItem: Added playlist: \(title)")
        }
    }

    /// Parses a library item from responsiveRenderer, adding to the appropriate array.
    private static func parseLibraryItemFromResponsive(
        _ data: [String: Any],
        playlists: inout [Playlist],
        podcastShows: inout [PodcastShow]
    ) {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            self.logger.debug("parseLibraryItemFromResponsive: No browseId found, keys: \(Array(data.keys))")
            return
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown"
        let subtitle = ParsingHelpers.extractSubtitleFromFlexColumns(data)

        Self.logger.info("parseLibraryItemFromResponsive: browseId=\(browseId), title=\(title)")

        if browseId.hasPrefix("MPSPP") {
            // Podcast show
            let show = PodcastShow(
                id: browseId,
                title: title,
                author: subtitle,
                description: nil,
                thumbnailURL: thumbnailURL,
                episodeCount: nil
            )
            podcastShows.append(show)
            Self.logger.info("parseLibraryItemFromResponsive: Added podcast show: \(title)")
        } else if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
            // Playlist
            let playlist = Playlist(
                id: browseId,
                title: title,
                description: nil,
                thumbnailURL: thumbnailURL,
                trackCount: nil,
                author: subtitle
            )
            playlists.append(playlist)
            Self.logger.info("parseLibraryItemFromResponsive: Added playlist: \(title)")
        } else {
            Self.logger.info("parseLibraryItemFromResponsive: Skipping unknown prefix: \(browseId)")
        }
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
        self.logger.debug("Parsing playlist continuation. Top-level keys: \(Array(data.keys))")

        // Try each format in order until we find tracks
        var result = Self.parseContinuationContentsFormat(data)

        // Try 2025 format if no tracks found
        if result.tracks.isEmpty {
            result = Self.parse2025ContinuationFormat(data)
        }

        let hasToken = result.continuationToken != nil
        Self.logger.debug("Playlist continuation parsed: \(result.tracks.count) tracks, has next token: \(hasToken)")

        return result
    }

    /// Parses legacy continuationContents format.
    private static func parseContinuationContentsFormat(_ data: [String: Any]) -> PlaylistContinuationResponse {
        guard let continuationContents = data["continuationContents"] as? [String: Any] else {
            return PlaylistContinuationResponse(tracks: [], continuationToken: nil)
        }

        Self.logger.debug("Found continuationContents, keys: \(Array(continuationContents.keys))")

        // Try musicShelfContinuation
        if let result = Self.parseShelfContinuation(continuationContents, key: "musicShelfContinuation") {
            return result
        }

        // Try musicPlaylistShelfContinuation
        if let result = Self.parseShelfContinuation(continuationContents, key: "musicPlaylistShelfContinuation") {
            return result
        }

        // Try sectionListContinuation
        if let result = Self.parseSectionListContinuation(continuationContents) {
            return result
        }

        return PlaylistContinuationResponse(tracks: [], continuationToken: nil)
    }

    /// Parses a shelf continuation (musicShelfContinuation or musicPlaylistShelfContinuation).
    private static func parseShelfContinuation(_ container: [String: Any], key: String) -> PlaylistContinuationResponse? {
        guard let shelfContinuation = container[key] as? [String: Any],
              let contents = shelfContinuation["contents"] as? [[String: Any]]
        else {
            return nil
        }

        Self.logger.debug("Found \(key) with \(contents.count) items")
        let tracks = Self.parseTracksFromContents(contents)

        // Try legacy format first, then 2025 format
        let token = Self.extractTokenFromRenderer(shelfContinuation) ?? Self.extractTokenFromContents(contents)

        return PlaylistContinuationResponse(tracks: tracks, continuationToken: token)
    }

    /// Parses sectionListContinuation format.
    private static func parseSectionListContinuation(_ container: [String: Any]) -> PlaylistContinuationResponse? {
        guard let sectionListContinuation = container["sectionListContinuation"] as? [String: Any],
              let sectionContents = sectionListContinuation["contents"] as? [[String: Any]]
        else {
            return nil
        }

        Self.logger.debug("Found sectionListContinuation with \(sectionContents.count) sections")

        var tracks: [Song] = []
        var token: String?

        for sectionData in sectionContents {
            if let (sectionTracks, sectionToken) = Self.parseShelfFromSection(sectionData, key: "musicPlaylistShelfRenderer") {
                tracks.append(contentsOf: sectionTracks)
                token = token ?? sectionToken
            }
            if let (sectionTracks, sectionToken) = Self.parseShelfFromSection(sectionData, key: "musicShelfRenderer") {
                tracks.append(contentsOf: sectionTracks)
                token = token ?? sectionToken
            }
        }

        // Check for continuation at sectionListContinuation level
        if token == nil {
            token = Self.extractTokenFromRenderer(sectionListContinuation)
        }

        return tracks.isEmpty ? nil : PlaylistContinuationResponse(tracks: tracks, continuationToken: token)
    }

    /// Parses a shelf renderer from a section.
    private static func parseShelfFromSection(_ sectionData: [String: Any], key: String) -> ([Song], String?)? {
        guard let shelfRenderer = sectionData[key] as? [String: Any],
              let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
        else {
            return nil
        }

        Self.logger.debug("Found \(key) in sectionListContinuation with \(shelfContents.count) items")
        let tracks = Self.parseTracksFromContents(shelfContents)
        let token = Self.extractTokenFromRenderer(shelfRenderer) ?? Self.extractTokenFromContents(shelfContents)

        return (tracks, token)
    }

    /// Parses 2025 format continuation response.
    private static func parse2025ContinuationFormat(_ data: [String: Any]) -> PlaylistContinuationResponse {
        guard let onResponseReceivedActions = data["onResponseReceivedActions"] as? [[String: Any]],
              let firstAction = onResponseReceivedActions.first,
              let appendAction = firstAction["appendContinuationItemsAction"] as? [String: Any],
              let continuationItems = appendAction["continuationItems"] as? [[String: Any]]
        else {
            return PlaylistContinuationResponse(tracks: [], continuationToken: nil)
        }

        Self.logger.debug("Using 2025 format continuation response with \(continuationItems.count) items")
        let tracks = Self.parseTracksFromContents(continuationItems)
        let token = Self.extractTokenFromContents(continuationItems)

        return PlaylistContinuationResponse(tracks: tracks, continuationToken: token)
    }

    /// Parses tracks from a contents array.
    private static func parseTracksFromContents(_ contents: [[String: Any]]) -> [Song] {
        contents.compactMap { self.parseTrackItem($0, fallbackThumbnailURL: nil) }
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
        if let token = Self.extractTokenFromSingleColumnRenderer(contents) {
            return token
        }

        // Try twoColumnBrowseResultsRenderer path
        if let token = Self.extractTokenFromTwoColumnRenderer(contents) {
            return token
        }

        Self.logger.debug("No continuation token found in playlist response")
        return nil
    }

    /// Extracts token from singleColumnBrowseResultsRenderer.
    private static func extractTokenFromSingleColumnRenderer(_ contents: [String: Any]) -> String? {
        guard let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any]
        else {
            return nil
        }

        // First check for continuation at sectionListRenderer level
        if let token = Self.extractTokenFromRenderer(sectionListRenderer) {
            Self.logger.debug("Found continuation token at sectionListRenderer level")
            return token
        }

        // Check section contents
        if let sectionContents = sectionListRenderer["contents"] as? [[String: Any]] {
            return Self.extractTokenFromSectionContents(sectionContents)
        }

        return nil
    }

    /// Extracts token from twoColumnBrowseResultsRenderer.
    private static func extractTokenFromTwoColumnRenderer(_ contents: [String: Any]) -> String? {
        guard let twoColumnRenderer = contents["twoColumnBrowseResultsRenderer"] as? [String: Any] else {
            return nil
        }

        Self.logger.debug("Found twoColumnBrowseResultsRenderer, keys: \(Array(twoColumnRenderer.keys))")

        // Try secondaryContents path
        if let token = Self.extractTokenFromSecondaryContents(twoColumnRenderer) {
            return token
        }

        // Try tabs path
        if let token = Self.extractTokenFromTabs(twoColumnRenderer) {
            return token
        }

        return nil
    }

    /// Extracts token from secondaryContents.
    private static func extractTokenFromSecondaryContents(_ twoColumnRenderer: [String: Any]) -> String? {
        guard let secondaryContents = twoColumnRenderer["secondaryContents"] as? [String: Any],
              let sectionListRenderer = secondaryContents["sectionListRenderer"] as? [String: Any]
        else {
            return nil
        }

        // First check for continuation at sectionListRenderer level
        if let token = Self.extractTokenFromRenderer(sectionListRenderer) {
            Self.logger.debug("Found continuation token at secondaryContents sectionListRenderer level")
            return token
        }

        if let sectionContents = sectionListRenderer["contents"] as? [[String: Any]] {
            Self.logger.debug("Found secondaryContents with \(sectionContents.count) sections")
            return Self.extractTokenFromSectionContents(sectionContents)
        }

        return nil
    }

    /// Extracts token from tabs path.
    private static func extractTokenFromTabs(_ twoColumnRenderer: [String: Any]) -> String? {
        guard let tabs = twoColumnRenderer["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return nil
        }

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

        return nil
    }

    /// Extracts token from section contents array.
    private static func extractTokenFromSectionContents(_ sectionContents: [[String: Any]]) -> String? {
        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any] {
                self.logger.debug("Found musicShelfRenderer, has continuations: \(shelfRenderer["continuations"] != nil)")
                if let token = extractTokenFromRenderer(shelfRenderer) {
                    self.logger.debug("Found continuation token in musicShelfRenderer")
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
                if let shelfContents = playlistShelfRenderer["contents"] as? [[String: Any]],
                   let token = Self.extractTokenFromContents(shelfContents)
                {
                    return token
                }
            }
        }
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
        let tracks = queueDatas.compactMap { Self.parseQueueItem($0) }
        Self.logger.debug("Parsed \(tracks.count) tracks from queue response")
        return tracks
    }

    /// Parses a single queue item into a Song.
    private static func parseQueueItem(_ queueData: [String: Any]) -> Song? {
        guard let content = queueData["content"] as? [String: Any],
              let renderer = extractQueueRenderer(from: content),
              let videoId = renderer["videoId"] as? String
        else {
            return nil
        }

        let title = (renderer["title"] as? [String: Any])?["runs"]
            .flatMap { ($0 as? [[String: Any]])?.first?["text"] as? String }
            ?? "Unknown"

        let artistRuns = (renderer["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let artistName = artistRuns?.first?["text"] as? String ?? "Unknown Artist"
        let artistId = Self.extractArtistId(from: artistRuns)

        let durationText = (renderer["lengthText"] as? [String: Any])?["runs"]
            .flatMap { ($0 as? [[String: Any]])?.first?["text"] as? String }

        let thumbnails = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbnails?.last?["url"]
            .flatMap { $0 as? String }
            .flatMap { URL(string: $0) }

        return Song(
            id: videoId,
            title: title,
            artists: [Artist(id: artistId ?? "", name: artistName, thumbnailURL: nil)],
            album: nil,
            duration: durationText.flatMap { ParsingHelpers.parseDuration($0) },
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )
    }

    /// Extracts the playlistPanelVideoRenderer from queue content.
    private static func extractQueueRenderer(from content: [String: Any]) -> [String: Any]? {
        if let directRenderer = content["playlistPanelVideoRenderer"] as? [String: Any] {
            return directRenderer
        }
        if let wrapper = content["playlistPanelVideoWrapperRenderer"] as? [String: Any],
           let primaryRenderer = wrapper["primaryRenderer"] as? [String: Any],
           let wrappedRenderer = primaryRenderer["playlistPanelVideoRenderer"] as? [String: Any]
        {
            return wrappedRenderer
        }
        return nil
    }

    /// Extracts artist ID from runs array.
    private static func extractArtistId(from artistRuns: [[String: Any]]?) -> String? {
        guard let firstRun = artistRuns?.first,
              let navEndpoint = firstRun["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navEndpoint["browseEndpoint"] as? [String: Any]
        else {
            return nil
        }
        return browseEndpoint["browseId"] as? String
    }
}

// swiftlint:enable type_body_length
