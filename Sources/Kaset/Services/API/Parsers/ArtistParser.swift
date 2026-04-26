// swiftlint:disable file_length

import Foundation
import os

/// Parser for artist-related responses from YouTube Music API.
enum ArtistParser { // swiftlint:disable:this type_body_length
    private static let logger = DiagnosticsLogger.api

    private struct CarouselSectionItems {
        var albums: [Album] = []
        var singles: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
    }

    /// Parses artist detail from browse response.
    static func parseArtistDetail(_ data: [String: Any], artistId: String) -> ArtistDetail { // swiftlint:disable:this function_body_length cyclomatic_complexity
        var buckets = ShelfBuckets()
        var songsSectionTitle: String?
        var orderedSections: [ArtistDetailSection] = []
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
                // Parse songs from musicShelfRenderer.
                if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
                   let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
                {
                    songsSectionTitle = songsSectionTitle ?? ParsingHelpers.extractTitle(from: shelfRenderer)
                    buckets.songs.append(contentsOf: self.parseTracksFromItems(shelfContents))

                    // Check if there are more songs available via bottomEndpoint.
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

                // Parse carousel shelves — classify per-item by renderer + browseId/pageType,
                // with the shelf title as a tiebreaker (e.g. Albums vs Singles & EPs).
                if let carouselRenderer = sectionData["musicCarouselShelfRenderer"] as? [String: Any],
                   let carouselContents = carouselRenderer["contents"] as? [[String: Any]]
                {
                    let shelfTitle = self.extractCarouselShelfTitle(from: carouselRenderer)
                    var shelfKind: ArtistShelfKind?
                    var sectionItems = CarouselSectionItems()

                    for itemData in carouselContents {
                        let albumCount = buckets.albums.count
                        let singleCount = buckets.singles.count
                        let playlistCount = buckets.playlists.count
                        let relatedArtistCount = buckets.relatedArtists.count

                        let kind = self.classifyCarouselItem(
                            itemData,
                            shelfTitle: shelfTitle,
                            buckets: &buckets
                        )
                        if shelfKind == nil { shelfKind = kind }

                        switch kind {
                        case .albums:
                            if buckets.albums.count > albumCount,
                               let album = buckets.albums.last
                            {
                                sectionItems.albums.append(album)
                            }
                        case .singles:
                            if buckets.singles.count > singleCount,
                               let single = buckets.singles.last
                            {
                                sectionItems.singles.append(single)
                            }
                        case .playlistsByArtist:
                            if buckets.playlists.count > playlistCount,
                               let playlist = buckets.playlists.last
                            {
                                sectionItems.playlists.append(playlist)
                            }
                        case .relatedArtists:
                            if buckets.relatedArtists.count > relatedArtistCount,
                               let artist = buckets.relatedArtists.last
                            {
                                sectionItems.artists.append(artist)
                            }
                        default:
                            break
                        }
                    }

                    // Record the shelf's "See all" endpoint against the first
                    // bucket an item landed in.
                    if let shelfKind,
                       let endpoint = self.extractShelfMoreEndpoint(from: carouselRenderer)
                    {
                        buckets.moreEndpoints[shelfKind] = endpoint
                    }

                    if !sectionItems.albums.isEmpty {
                        orderedSections.append(ArtistDetailSection(
                            title: shelfTitle ?? "Albums",
                            content: .albums(sectionItems.albums)
                        ))
                    }

                    if !sectionItems.singles.isEmpty {
                        orderedSections.append(ArtistDetailSection(
                            title: shelfTitle ?? "Singles & EPs",
                            content: .albums(sectionItems.singles)
                        ))
                    }

                    if !sectionItems.playlists.isEmpty {
                        orderedSections.append(ArtistDetailSection(
                            title: shelfTitle ?? "Playlists",
                            content: .playlists(sectionItems.playlists)
                        ))
                    }

                    if !sectionItems.artists.isEmpty {
                        orderedSections.append(ArtistDetailSection(
                            title: shelfTitle ?? "Artists",
                            content: .artists(sectionItems.artists)
                        ))
                    }
                }
            }
        }

        let artist = Artist(
            id: artistId,
            name: headerResult.name,
            thumbnailURL: headerResult.thumbnailURL,
            profileKind: headerResult.profileKind
        )

        return ArtistDetail(
            artist: artist,
            description: headerResult.description,
            songs: buckets.songs,
            songsSectionTitle: songsSectionTitle,
            orderedSections: orderedSections,
            albums: buckets.albums,
            singles: buckets.singles,
            episodes: buckets.episodes,
            playlistsByArtist: buckets.playlists,
            relatedArtists: buckets.relatedArtists,
            podcasts: buckets.podcasts,
            moreEndpoints: buckets.moreEndpoints,
            thumbnailURL: headerResult.thumbnailURL,
            channelId: headerResult.channelId,
            isSubscribed: headerResult.isSubscribed,
            subscriberCount: headerResult.subscriberCount,
            subscribedButtonText: headerResult.subscribedButtonText,
            unsubscribedButtonText: headerResult.unsubscribedButtonText,
            monthlyAudience: headerResult.monthlyAudience,
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
        var moreEndpoints: [ArtistShelfKind: ShelfMoreEndpoint] = [:]
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

    /// Extracts the shelf's "See all" / "More" browse endpoint, if present.
    /// Only returns endpoints whose `pageType` we recognize — unknown
    /// pageTypes are dropped so the UI never surfaces a destination we
    /// don't know how to render.
    private static func extractShelfMoreEndpoint(from data: [String: Any]) -> ShelfMoreEndpoint? {
        guard let header = data["header"] as? [String: Any],
              let basicHeader = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any],
              let moreButton = basicHeader["moreContentButton"] as? [String: Any],
              let buttonRenderer = moreButton["buttonRenderer"] as? [String: Any]
        else {
            return nil
        }

        let endpointContainer = (buttonRenderer["command"] as? [String: Any])
            ?? (buttonRenderer["navigationEndpoint"] as? [String: Any])

        guard let browseEndpoint = endpointContainer?["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            return nil
        }

        let params = browseEndpoint["params"] as? String

        // The pageType lives under browseEndpointContextSupportedConfigs.
        guard let supportedConfigs = browseEndpoint["browseEndpointContextSupportedConfigs"] as? [String: Any],
              let musicConfig = supportedConfigs["browseEndpointContextMusicConfig"] as? [String: Any],
              let pageTypeRaw = musicConfig["pageType"] as? String,
              let pageType = ShelfMoreEndpoint.PageType(rawValue: pageTypeRaw)
        else {
            return nil
        }

        return ShelfMoreEndpoint(browseId: browseId, params: params, pageType: pageType)
    }

    // MARK: - Episodes list (ARTIST pageType with 304-char params)

    /// Parses the "See all episodes" response for a `MUSIC_PAGE_TYPE_ARTIST`
    /// destination — a single `gridRenderer` of `musicMultiRowListItemRenderer`
    /// items. Reuses the same per-item shape that appears in the artist page's
    /// Latest-episodes carousel, so `parseEpisodeFromMultiRowRenderer` does the
    /// per-item work.
    static func parseArtistEpisodesGrid(_ data: [String: Any]) -> [ArtistEpisode] {
        guard let contents = data["contents"] as? [String: Any],
              let singleColumn = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumn["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionList = tabContent["sectionListRenderer"] as? [String: Any],
              let sections = sectionList["contents"] as? [[String: Any]]
        else {
            return []
        }

        var episodes: [ArtistEpisode] = []
        for section in sections {
            guard let grid = section["gridRenderer"] as? [String: Any],
                  let items = grid["items"] as? [[String: Any]]
            else {
                continue
            }
            for itemData in items {
                if let multiRow = itemData["musicMultiRowListItemRenderer"] as? [String: Any],
                   let episode = self.parseEpisodeFromMultiRowRenderer(multiRow)
                {
                    episodes.append(episode)
                }
            }
        }
        return episodes
    }

    // MARK: - Discography (ARTIST_DISCOGRAPHY pageType)

    /// Parses a discography browse response — a `gridRenderer` of
    /// `musicTwoRowItemRenderer` album cards.
    static func parseArtistDiscography(_ data: [String: Any]) -> [Album] {
        guard let contents = data["contents"] as? [String: Any],
              let singleColumn = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumn["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionList = tabContent["sectionListRenderer"] as? [String: Any],
              let sections = sectionList["contents"] as? [[String: Any]]
        else {
            return []
        }

        var albums: [Album] = []
        for section in sections {
            guard let grid = section["gridRenderer"] as? [String: Any],
                  let items = grid["items"] as? [[String: Any]]
            else {
                continue
            }
            for itemData in items {
                if let twoRow = itemData["musicTwoRowItemRenderer"] as? [String: Any],
                   let album = self.parseAlbumFromTwoRowRenderer(twoRow)
                {
                    albums.append(album)
                }
            }
        }
        return albums
    }

    /// Returns `true` when a shelf title indicates a singles/EPs shelf.
    private static func shelfTitleIndicatesSingles(_ title: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return title.contains("single") || title.contains(" ep") || title.hasPrefix("ep")
    }

    /// Routes a carousel item into the matching bucket based on its renderer
    /// shape and (for album-shaped items) the shelf title. Returns the
    /// `ArtistShelfKind` it matched (or `nil` if nothing applied) so the
    /// caller can attribute the shelf's `moreContentButton` to the right kind.
    @discardableResult
    private static func classifyCarouselItem(
        _ itemData: [String: Any],
        shelfTitle: String?,
        buckets: inout ShelfBuckets
    ) -> ArtistShelfKind? {
        // Episodes / video uploads on the artist channel (including live radios).
        if let multiRow = itemData["musicMultiRowListItemRenderer"] as? [String: Any],
           let episode = self.parseEpisodeFromMultiRowRenderer(multiRow)
        {
            buckets.episodes.append(episode)
            return .episodes
        }

        guard let twoRow = itemData["musicTwoRowItemRenderer"] as? [String: Any],
              let navigationEndpoint = twoRow["navigationEndpoint"] as? [String: Any]
        else {
            return nil
        }

        // Podcast shows (MPSPP browseIds) are not regular artist pages and
        // need their own model/parser.
        if let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String,
           browseId.hasPrefix("MPSPP")
        {
            if let show = self.parsePodcastShowFromTwoRowRenderer(twoRow, browseId: browseId) {
                buckets.podcasts.append(show)
                return .podcasts
            }
            return nil
        }

        guard let carouselItem = self.parseCarouselItemFromTwoRowRenderer(twoRow) else {
            // Videos shelf (watchEndpoint with videoId) is intentionally deferred —
            // see Phase 3a scope notes.
            return nil
        }

        switch carouselItem {
        case let .album(album):
            if self.shelfTitleIndicatesSingles(shelfTitle) {
                buckets.singles.append(album)
                return .singles
            }
            buckets.albums.append(album)
            return .albums
        case let .playlist(playlist):
            buckets.playlists.append(playlist)
            return .playlistsByArtist
        case let .artist(artist):
            buckets.relatedArtists.append(artist)
            return .relatedArtists
        }
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
            author: author.map { Artist.inline(name: $0, namespace: "playlist-author") }
        )
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

    // MARK: - Header Parsing

    /// Holds parsed header information for an artist.
    private struct HeaderParseResult {
        var name: String = "Unknown Artist"
        var description: String?
        var thumbnailURL: URL?
        var profileKind: ArtistProfileKind = .unknown
        var channelId: String?
        var isSubscribed: Bool = false
        var subscriberCount: String?
        var subscribedButtonText: String?
        var unsubscribedButtonText: String?
        var monthlyAudience: String?
        var mixPlaylistId: String?
        var mixVideoId: String?
    }

    private static func parseArtistHeader(_ data: [String: Any], artistId: String) -> HeaderParseResult {
        var result = HeaderParseResult()
        result.channelId = artistId.hasPrefix("UC") ? artistId : nil
        result.profileKind = Artist.profileKind(forPageType: self.extractPageType(from: data))

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

            if let monthlyListenerCount = immersiveHeader["monthlyListenerCount"] as? [String: Any] {
                result.monthlyAudience = self.parseMonthlyAudience(from: monthlyListenerCount)
            }

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
            if let shortSubscriberCountText = subscribeButtonRenderer["shortSubscriberCountText"] as? [String: Any],
               let runs = shortSubscriberCountText["runs"] as? [[String: Any]]
            {
                result.subscriberCount = runs.compactMap { $0["text"] as? String }.joined()
            } else if let subscriberCountText = subscribeButtonRenderer["subscriberCountText"] as? [String: Any],
                      let runs = subscriberCountText["runs"] as? [[String: Any]]
            {
                result.subscriberCount = runs.compactMap { $0["text"] as? String }.joined()
            }

            if let subscribedButtonText = subscribeButtonRenderer["subscribedButtonText"] as? [String: Any],
               let runs = subscribedButtonText["runs"] as? [[String: Any]]
            {
                result.subscribedButtonText = runs.compactMap { $0["text"] as? String }.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let unsubscribedButtonText = subscribeButtonRenderer["unsubscribedButtonText"] as? [String: Any],
               let runs = unsubscribedButtonText["runs"] as? [[String: Any]]
            {
                result.unsubscribedButtonText = runs.compactMap { $0["text"] as? String }.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func parseMonthlyAudience(from data: [String: Any]) -> String? {
        guard let runs = data["runs"] as? [[String: Any]] else { return nil }
        let text = runs.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        return text
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
            let isPlayable = ParsingHelpers.isPlayableMusicItem(from: responsiveRenderer)

            let track = Song(
                id: videoId,
                title: title,
                artists: artists,
                album: album,
                duration: duration,
                thumbnailURL: thumbnailURL,
                videoId: videoId,
                isPlayable: isPlayable
            )
            tracks.append(track)
        }

        return tracks
    }

    private enum CarouselItem {
        case album(Album)
        case playlist(Playlist)
        case artist(Artist)
    }

    private static func parseCarouselItemFromTwoRowRenderer(_ data: [String: Any]) -> CarouselItem? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            return nil
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitle(from: data) ?? "Unknown"
        let pageType = ParsingHelpers.extractPageType(from: browseEndpoint)
        let subtitleText = self.parseCarouselSubtitle(from: data)

        if let subtitleData = data["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
                // Year is typically the last item in subtitle
                let year = runs.last?["text"] as? String
                return .album(Album(
                    id: browseId,
                    title: title,
                    artists: nil,
                    thumbnailURL: thumbnailURL,
                    year: year,
                    trackCount: nil
                ))
            }

            if Self.isPlaylistBrowseId(browseId, browseEndpoint: browseEndpoint) {
                let author = ParsingHelpers.extractFirstNavigableArtist(from: runs)
                    ?? runs.compactMap { run -> Artist? in
                        guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !text.isEmpty,
                              text != "•"
                        else {
                            return nil
                        }
                        return Artist.inline(name: text, namespace: "playlist-author")
                    }.first

                return .playlist(Playlist(
                    id: browseId,
                    title: title,
                    description: nil,
                    thumbnailURL: thumbnailURL,
                    trackCount: nil,
                    author: author
                ))
            }

            if ParsingHelpers.isArtistPageType(pageType) || Artist.isNavigableId(browseId) {
                return .artist(Artist(
                    id: browseId,
                    name: title,
                    thumbnailURL: thumbnailURL,
                    subtitle: subtitleText,
                    profileKind: Artist.profileKind(forPageType: pageType)
                ))
            }
        }

        if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            return .album(Album(
                id: browseId,
                title: title,
                artists: nil,
                thumbnailURL: thumbnailURL,
                year: nil,
                trackCount: nil
            ))
        }

        if Self.isPlaylistBrowseId(browseId, browseEndpoint: browseEndpoint) {
            return .playlist(Playlist(
                id: browseId,
                title: title,
                description: nil,
                thumbnailURL: thumbnailURL,
                trackCount: nil,
                author: nil
            ))
        }

        if ParsingHelpers.isArtistPageType(pageType) || Artist.isNavigableId(browseId) {
            return .artist(Artist(
                id: browseId,
                name: title,
                thumbnailURL: thumbnailURL,
                subtitle: subtitleText,
                profileKind: Artist.profileKind(forPageType: pageType)
            ))
        }

        return nil
    }

    private static func extractPageType(from data: [String: Any]) -> String? {
        if let pageType = data["pageType"] as? String {
            return pageType
        }

        if let browseConfig = data["browseEndpointContextSupportedConfigs"] as? [String: Any],
           let musicConfig = browseConfig["browseEndpointContextMusicConfig"] as? [String: Any],
           let pageType = musicConfig["pageType"] as? String
        {
            return pageType
        }

        if let header = data["header"] as? [String: Any] {
            for rendererKey in ["musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer"] {
                if let renderer = header[rendererKey] as? [String: Any],
                   let pageType = renderer["pageType"] as? String
                {
                    return pageType
                }
            }
        }

        return nil
    }

    private static func parseCarouselSubtitle(from data: [String: Any]) -> String? {
        guard let subtitle = data["subtitle"] as? [String: Any],
              let runs = subtitle["runs"] as? [[String: Any]]
        else {
            return nil
        }

        let text = runs.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func isPlaylistBrowseId(_ browseId: String, browseEndpoint: [String: Any]) -> Bool {
        let pageType = ParsingHelpers.extractPageType(from: browseEndpoint)
        return pageType == "MUSIC_PAGE_TYPE_PLAYLIST"
            || browseId.hasPrefix("VL")
            || browseId.hasPrefix("PL")
            || browseId.hasPrefix("RD")
    }
}
