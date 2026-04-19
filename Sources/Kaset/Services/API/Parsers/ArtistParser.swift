import Foundation
import os

/// Parser for artist-related responses from YouTube Music API.
enum ArtistParser {
    private static let logger = DiagnosticsLogger.api

    /// Parses artist detail from browse response.
    static func parseArtistDetail(_ data: [String: Any], artistId: String) -> ArtistDetail {
        var buckets = ShelfBuckets()
        var hasMoreSongs = false
        var songsBrowseId: String?
        var songsParams: String?

        // Parse header
        let headerResult = self.parseArtistHeader(data, artistId: artistId)

        // Parse content sections
        if let contents = data["contents"] as? [String: Any],
           let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
           let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
           let firstTab = tabs.first,
           let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
           let tabContent = tabRenderer["content"] as? [String: Any],
           let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
           let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        {
            for sectionData in sectionContents {
                // Parse songs from musicShelfRenderer
                if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
                   let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
                {
                    buckets.songs.append(contentsOf: self.parseTracksFromItems(shelfContents))

                    // Check if there are more songs available via bottomEndpoint
                    if let bottomEndpoint = shelfRenderer["bottomEndpoint"] as? [String: Any],
                       let browseEndpoint = bottomEndpoint["browseEndpoint"] as? [String: Any],
                       let browseId = browseEndpoint["browseId"] as? String
                    {
                        hasMoreSongs = true
                        songsBrowseId = browseId
                        songsParams = browseEndpoint["params"] as? String
                    } else if shelfRenderer["continuations"] != nil {
                        hasMoreSongs = true
                    }
                }

                // Parse carousel shelves — classify per-item by renderer + browseId prefix,
                // with the shelf title as a tiebreaker (e.g. Albums vs Singles & EPs).
                if let carouselRenderer = sectionData["musicCarouselShelfRenderer"] as? [String: Any],
                   let carouselContents = carouselRenderer["contents"] as? [[String: Any]]
                {
                    let shelfTitle = self.extractCarouselShelfTitle(from: carouselRenderer)
                    for itemData in carouselContents {
                        Self.classifyCarouselItem(
                            itemData,
                            shelfTitle: shelfTitle,
                            buckets: &buckets
                        )
                    }
                }
            }
        }

        let artist = Artist(id: artistId, name: headerResult.name, thumbnailURL: headerResult.thumbnailURL)

        return ArtistDetail(
            artist: artist,
            description: headerResult.description,
            songs: buckets.songs,
            albums: buckets.albums,
            singles: buckets.singles,
            episodes: buckets.episodes,
            playlistsByArtist: buckets.playlists,
            relatedArtists: buckets.relatedArtists,
            podcasts: buckets.podcasts,
            thumbnailURL: headerResult.thumbnailURL,
            channelId: headerResult.channelId,
            isSubscribed: headerResult.isSubscribed,
            subscriberCount: headerResult.subscriberCount,
            hasMoreSongs: hasMoreSongs,
            songsBrowseId: songsBrowseId,
            songsParams: songsParams,
            mixPlaylistId: headerResult.mixPlaylistId,
            mixVideoId: headerResult.mixVideoId
        )
    }

    // MARK: - Shelf Classification

    /// Accumulator for content routed out of artist-page carousel shelves.
    private struct ShelfBuckets {
        var songs: [Song] = []
        var albums: [Album] = []
        var singles: [Album] = []
        var episodes: [ArtistEpisode] = []
        var playlists: [Playlist] = []
        var relatedArtists: [Artist] = []
        var podcasts: [PodcastShow] = []
    }

    /// Reads the shelf header title if present.
    private static func extractCarouselShelfTitle(from data: [String: Any]) -> String? {
        guard let header = data["header"] as? [String: Any],
              let basicHeader = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
        else {
            return nil
        }
        return ParsingHelpers.extractTitle(from: basicHeader)
    }

    /// Returns `true` when a shelf title indicates a singles/EPs shelf.
    private static func shelfTitleIndicatesSingles(_ title: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return title.contains("single") || title.contains(" ep") || title.hasPrefix("ep")
    }

    /// Routes a carousel item into the matching bucket based on its renderer
    /// shape and (for album-shaped items) the shelf title.
    private static func classifyCarouselItem(
        _ itemData: [String: Any],
        shelfTitle: String?,
        buckets: inout ShelfBuckets
    ) {
        // Episodes / video uploads on the artist channel (including live radios).
        if let multiRow = itemData["musicMultiRowListItemRenderer"] as? [String: Any],
           let episode = Self.parseEpisodeFromMultiRowRenderer(multiRow)
        {
            buckets.episodes.append(episode)
            return
        }

        guard let twoRow = itemData["musicTwoRowItemRenderer"] as? [String: Any],
              let navigationEndpoint = twoRow["navigationEndpoint"] as? [String: Any]
        else {
            return
        }

        // Albums / Singles & EPs (MPRE/OLAK browseIds)
        if let album = Self.parseAlbumFromTwoRowRenderer(twoRow) {
            if Self.shelfTitleIndicatesSingles(shelfTitle) {
                buckets.singles.append(album)
            } else {
                buckets.albums.append(album)
            }
            return
        }

        // Podcast shows (MPSPP browseIds)
        if let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String,
           browseId.hasPrefix("MPSPP")
        {
            if let show = Self.parsePodcastShowFromTwoRowRenderer(twoRow, browseId: browseId) {
                buckets.podcasts.append(show)
            }
            return
        }

        // Related artists (UC browseIds in "Fans might also like")
        if let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String,
           browseId.hasPrefix("UC")
        {
            if let artist = Self.parseRelatedArtistFromTwoRowRenderer(twoRow, browseId: browseId) {
                buckets.relatedArtists.append(artist)
            }
            return
        }

        // Artist-curated playlists (VL/PL browseIds)
        if let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String,
           browseId.hasPrefix("VL") || browseId.hasPrefix("PL")
        {
            if let playlist = Self.parsePlaylistFromTwoRowRenderer(twoRow, browseId: browseId) {
                buckets.playlists.append(playlist)
            }
            return
        }

        // Videos shelf (watchEndpoint with videoId) is intentionally deferred —
        // see Phase 3a scope notes.
    }

    // MARK: - Item Parsers (carousel)

    /// Parses a Latest-episodes item. Video ID lives under `onTap.watchEndpoint`
    /// (not `navigationEndpoint`) for this renderer.
    private static func parseEpisodeFromMultiRowRenderer(_ data: [String: Any]) -> ArtistEpisode? {
        guard let onTap = data["onTap"] as? [String: Any],
              let watchEndpoint = onTap["watchEndpoint"] as? [String: Any],
              let videoId = watchEndpoint["videoId"] as? String,
              !videoId.isEmpty
        else {
            return nil
        }

        let title = (data["title"] as? [String: Any])
            .flatMap { ($0["runs"] as? [[String: Any]])?.first?["text"] as? String }
            ?? "Unknown"

        let subtitle = (data["subtitle"] as? [String: Any])
            .flatMap { subtitleData in
                (subtitleData["runs"] as? [[String: Any]])?
                    .compactMap { $0["text"] as? String }
                    .joined()
            }

        let description = (data["description"] as? [String: Any])
            .flatMap { descData in
                (descData["runs"] as? [[String: Any]])?
                    .compactMap { $0["text"] as? String }
                    .joined()
            }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        let isLive = (data["badges"] as? [[String: Any]])?
            .contains { $0["liveBadgeRenderer"] != nil } ?? false

        return ArtistEpisode(
            videoId: videoId,
            title: title,
            subtitle: (subtitle?.isEmpty == true) ? nil : subtitle,
            description: (description?.isEmpty == true) ? nil : description,
            thumbnailURL: thumbnailURL,
            isLive: isLive
        )
    }

    private static func parsePodcastShowFromTwoRowRenderer(
        _ data: [String: Any],
        browseId: String
    ) -> PodcastShow? {
        let title = ParsingHelpers.extractTitle(from: data) ?? "Unknown Show"
        let author = ParsingHelpers.extractSubtitle(from: data)
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        return PodcastShow(
            id: browseId,
            title: title,
            author: author,
            description: nil,
            thumbnailURL: thumbnailURL,
            episodeCount: nil
        )
    }

    private static func parseRelatedArtistFromTwoRowRenderer(
        _ data: [String: Any],
        browseId: String
    ) -> Artist? {
        guard let name = ParsingHelpers.extractTitle(from: data) else {
            return nil
        }
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        return Artist(id: browseId, name: name, thumbnailURL: thumbnailURL)
    }

    private static func parsePlaylistFromTwoRowRenderer(
        _ data: [String: Any],
        browseId: String
    ) -> Playlist? {
        guard let title = ParsingHelpers.extractTitle(from: data) else {
            return nil
        }
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let author = ParsingHelpers.extractSubtitle(from: data)

        return Playlist(
            id: browseId,
            title: title,
            description: nil,
            thumbnailURL: thumbnailURL,
            trackCount: nil,
            author: author
        )
    }

    // MARK: - Header Parsing

    /// Holds parsed header information for an artist.
    private struct HeaderParseResult {
        var name: String = "Unknown Artist"
        var description: String?
        var thumbnailURL: URL?
        var channelId: String?
        var isSubscribed: Bool = false
        var subscriberCount: String?
        var mixPlaylistId: String?
        var mixVideoId: String?
    }

    private static func parseArtistHeader(_ data: [String: Any], artistId: String) -> HeaderParseResult {
        var result = HeaderParseResult()
        result.channelId = artistId.hasPrefix("UC") ? artistId : nil

        // Try musicImmersiveHeaderRenderer (common for artist pages)
        if let header = data["header"] as? [String: Any],
           let immersiveHeader = header["musicImmersiveHeaderRenderer"] as? [String: Any]
        {
            if let text = ParsingHelpers.extractTitle(from: immersiveHeader) {
                result.name = text
            }

            if let descData = immersiveHeader["description"] as? [String: Any],
               let runs = descData["runs"] as? [[String: Any]]
            {
                result.description = runs.compactMap { $0["text"] as? String }.joined()
            }

            let thumbnails = ParsingHelpers.extractThumbnails(from: immersiveHeader)
            result.thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

            // Parse subscription button for channel ID and subscription status
            self.parseSubscriptionButton(from: immersiveHeader, into: &result)

            // Parse startRadioButton for mix (personalized radio)
            self.parseStartRadioButton(from: immersiveHeader, into: &result)
        }

        // Try musicVisualHeaderRenderer (alternative header format)
        if result.name == "Unknown Artist",
           let header = data["header"] as? [String: Any],
           let visualHeader = header["musicVisualHeaderRenderer"] as? [String: Any]
        {
            if let text = ParsingHelpers.extractTitle(from: visualHeader) {
                result.name = text
            }

            let thumbnails = ParsingHelpers.extractThumbnails(from: visualHeader)
            result.thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

            // Parse subscription button for channel ID and subscription status
            self.parseSubscriptionButton(from: visualHeader, into: &result)

            // Parse startRadioButton for mix (personalized radio)
            self.parseStartRadioButton(from: visualHeader, into: &result)
        }

        return result
    }

    // MARK: - Subscription Parsing

    private static func parseSubscriptionButton(from header: [String: Any], into result: inout HeaderParseResult) {
        // Look for subscriptionButton in header
        if let subscriptionButton = header["subscriptionButton"] as? [String: Any],
           let subscribeButtonRenderer = subscriptionButton["subscribeButtonRenderer"] as? [String: Any]
        {
            // Extract channel ID
            if let extractedChannelId = subscribeButtonRenderer["channelId"] as? String {
                result.channelId = extractedChannelId
            }

            // Check subscription status
            if let subscribed = subscribeButtonRenderer["subscribed"] as? Bool {
                result.isSubscribed = subscribed
            }

            // Extract subscriber count text
            if let subscriberCountText = subscribeButtonRenderer["subscriberCountText"] as? [String: Any],
               let runs = subscriberCountText["runs"] as? [[String: Any]]
            {
                result.subscriberCount = runs.compactMap { $0["text"] as? String }.joined()
            } else if let shortSubscriberCountText = subscribeButtonRenderer["shortSubscriberCountText"] as? [String: Any],
                      let runs = shortSubscriberCountText["runs"] as? [[String: Any]]
            {
                result.subscriberCount = runs.compactMap { $0["text"] as? String }.joined()
            }
        }

        // Alternative: look in menu for subscription status
        if let menu = header["menu"] as? [String: Any],
           let menuRenderer = menu["menuRenderer"] as? [String: Any],
           let items = menuRenderer["items"] as? [[String: Any]]
        {
            for item in items {
                if let toggleMenuItem = item["toggleMenuServiceItemRenderer"] as? [String: Any],
                   let defaultIcon = toggleMenuItem["defaultIcon"] as? [String: Any],
                   let iconType = defaultIcon["iconType"] as? String
                {
                    if iconType == "SUBSCRIBE" || iconType == "NOTIFICATION_OFF" {
                        result.isSubscribed = false
                    } else if iconType == "SUBSCRIBED" || iconType == "NOTIFICATION_ON" {
                        result.isSubscribed = true
                    }
                }
            }
        }
    }

    // MARK: - Start Radio Button Parsing

    /// Parses the startRadioButton to extract mix playlist ID and video ID.
    private static func parseStartRadioButton(from header: [String: Any], into result: inout HeaderParseResult) {
        // Look for startRadioButton in header
        // Path: startRadioButton.buttonRenderer.navigationEndpoint.watchPlaylistEndpoint
        guard let startRadioButton = header["startRadioButton"] as? [String: Any],
              let buttonRenderer = startRadioButton["buttonRenderer"] as? [String: Any],
              let navigationEndpoint = buttonRenderer["navigationEndpoint"] as? [String: Any]
        else {
            return
        }

        // Try watchPlaylistEndpoint first (used by artist mix buttons)
        if let watchPlaylistEndpoint = navigationEndpoint["watchPlaylistEndpoint"] as? [String: Any] {
            if let playlistId = watchPlaylistEndpoint["playlistId"] as? String {
                result.mixPlaylistId = playlistId
            }
            // watchPlaylistEndpoint doesn't have videoId - API picks random start
            return
        }

        // Fall back to watchEndpoint (used by some song radios)
        if let watchEndpoint = navigationEndpoint["watchEndpoint"] as? [String: Any] {
            if let playlistId = watchEndpoint["playlistId"] as? String {
                result.mixPlaylistId = playlistId
            }
            if let videoId = watchEndpoint["videoId"] as? String {
                result.mixVideoId = videoId
            }
        }
    }

    // MARK: - Content Parsing

    /// Parses songs from artist songs browse response.
    static func parseArtistSongs(_ data: [String: Any]) -> [Song] {
        var songs: [Song] = []

        // Try parsing from musicShelfRenderer in sectionListRenderer
        if let contents = data["contents"] as? [String: Any],
           let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
           let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
           let firstTab = tabs.first,
           let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
           let tabContent = tabRenderer["content"] as? [String: Any],
           let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
           let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        {
            for sectionData in sectionContents {
                if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
                   let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
                {
                    songs.append(contentsOf: self.parseTracksFromItems(shelfContents))
                }
            }
        }

        // Try parsing from musicPlaylistShelfRenderer (alternative format)
        if songs.isEmpty,
           let contents = data["contents"] as? [String: Any],
           let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
           let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
           let firstTab = tabs.first,
           let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
           let tabContent = tabRenderer["content"] as? [String: Any],
           let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
           let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        {
            for sectionData in sectionContents {
                if let playlistRenderer = sectionData["musicPlaylistShelfRenderer"] as? [String: Any],
                   let playlistContents = playlistRenderer["contents"] as? [[String: Any]]
                {
                    songs.append(contentsOf: self.parseTracksFromItems(playlistContents))
                }
            }
        }

        return songs
    }

    private static func parseTracksFromItems(_ items: [[String: Any]], fallbackThumbnailURL: URL? = nil) -> [Song] {
        var tracks: [Song] = []

        for itemData in items {
            guard let responsiveRenderer = itemData["musicResponsiveListItemRenderer"] as? [String: Any] else {
                continue
            }

            guard let videoId = ParsingHelpers.extractVideoId(from: responsiveRenderer) else {
                continue
            }

            let title = ParsingHelpers.extractTitleFromFlexColumns(responsiveRenderer) ?? "Unknown"
            let artists = ParsingHelpers.extractArtistsFromFlexColumns(responsiveRenderer)
            let thumbnails = ParsingHelpers.extractThumbnails(from: responsiveRenderer)
            let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) } ?? fallbackThumbnailURL
            let duration = ParsingHelpers.extractDurationFromFlexColumns(responsiveRenderer)
            let album = ParsingHelpers.extractAlbumFromFlexColumns(responsiveRenderer)

            let track = Song(
                id: videoId,
                title: title,
                artists: artists,
                album: album,
                duration: duration,
                thumbnailURL: thumbnailURL,
                videoId: videoId
            )
            tracks.append(track)
        }

        return tracks
    }

    private static func parseAlbumFromTwoRowRenderer(_ data: [String: Any]) -> Album? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String,
              browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK")
        else {
            return nil
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitle(from: data) ?? "Unknown Album"

        var year: String?
        if let subtitleData = data["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            // Year is typically the last item in subtitle
            year = runs.last?["text"] as? String
        }

        return Album(
            id: browseId,
            title: title,
            artists: nil,
            thumbnailURL: thumbnailURL,
            year: year,
            trackCount: nil
        )
    }
}
