import Foundation
import os

/// Parser for artist-related responses from YouTube Music API.
enum ArtistParser {
    private static let logger = DiagnosticsLogger.api

    private struct CarouselAccumulator {
        var albumSections: [AlbumCarouselSection]
        var playlistSections: [PlaylistCarouselSection]
        var artistSections: [ArtistCarouselSection]
    }

    private struct CarouselSectionItems {
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
    }

    /// Parses artist detail from browse response.
    static func parseArtistDetail(_ data: [String: Any], artistId: String) -> ArtistDetail {
        var songs: [Song] = []
        var carouselAccumulator = CarouselAccumulator(
            albumSections: [],
            playlistSections: [],
            artistSections: []
        )
        var hasMoreSongs = false
        var songsBrowseId: String?
        var songsParams: String?

        // Parse header
        let headerResult = self.parseArtistHeader(data, artistId: artistId)

        // Parse content sections for songs and albums
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
                    songs.append(contentsOf: self.parseTracksFromItems(shelfContents))

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

                // Parse albums from musicCarouselShelfRenderer
                if let carouselRenderer = sectionData["musicCarouselShelfRenderer"] as? [String: Any],
                   let carouselContents = carouselRenderer["contents"] as? [[String: Any]]
                {
                    self.parseCarouselSection(
                        carouselRenderer,
                        contents: carouselContents,
                        accumulator: &carouselAccumulator
                    )
                }
            }
        }

        let artist = Artist(id: artistId, name: headerResult.name, thumbnailURL: headerResult.thumbnailURL)

        return ArtistDetail(
            artist: artist,
            description: headerResult.description,
            songs: songs,
            albumSections: carouselAccumulator.albumSections,
            playlistSections: carouselAccumulator.playlistSections,
            artistSections: carouselAccumulator.artistSections,
            thumbnailURL: headerResult.thumbnailURL,
            channelId: headerResult.channelId,
            isSubscribed: headerResult.isSubscribed,
            subscriberCount: headerResult.subscriberCount,
            monthlyAudience: headerResult.monthlyAudience,
            hasMoreSongs: hasMoreSongs,
            songsBrowseId: songsBrowseId,
            songsParams: songsParams,
            mixPlaylistId: headerResult.mixPlaylistId,
            mixVideoId: headerResult.mixVideoId
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
        var monthlyAudience: String?
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

    private static func parseMonthlyAudience(from data: [String: Any]) -> String? {
        guard let runs = data["runs"] as? [[String: Any]] else { return nil }
        let text = runs.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        for suffix in [" monthly audience", " monthly listeners"] where text.hasSuffix(suffix) {
            return String(text.dropLast(suffix.count))
        }

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

    private static func parseCarouselSection(
        _ renderer: [String: Any],
        contents: [[String: Any]],
        accumulator: inout CarouselAccumulator
    ) {
        let carouselSectionType = self.carouselSectionType(from: renderer)
        let sectionTitle = self.carouselTitle(from: renderer)
        var sectionItems = CarouselSectionItems()

        for itemData in contents {
            guard let twoRowRenderer = itemData["musicTwoRowItemRenderer"] as? [String: Any],
                  let carouselItem = self.parseCarouselItemFromTwoRowRenderer(twoRowRenderer)
            else {
                continue
            }

            self.appendCarouselItem(
                carouselItem,
                sectionType: carouselSectionType,
                sectionItems: &sectionItems
            )
        }

        if !sectionItems.albums.isEmpty {
            accumulator.albumSections.append(AlbumCarouselSection(
                title: sectionTitle ?? "Albums",
                albums: sectionItems.albums
            ))
        }

        if !sectionItems.playlists.isEmpty {
            accumulator.playlistSections.append(PlaylistCarouselSection(
                title: sectionTitle ?? "Playlists",
                playlists: sectionItems.playlists
            ))
        }

        guard !sectionItems.artists.isEmpty else { return }

        accumulator.artistSections.append(ArtistCarouselSection(
            title: sectionTitle ?? "Artists",
            artists: sectionItems.artists
        ))
    }

    private static func appendCarouselItem(
        _ item: CarouselItem,
        sectionType: CarouselSectionType,
        sectionItems: inout CarouselSectionItems
    ) {
        switch item {
        case let .album(album):
            sectionItems.albums.append(album)
        case let .playlist(playlist):
            if sectionType != .similarArtists {
                sectionItems.playlists.append(playlist)
            }
        case let .artist(artist):
            if sectionType != .featuredOn, sectionType != .playlists {
                sectionItems.artists.append(artist)
            }
        }
    }

    private enum CarouselItem {
        case album(Album)
        case playlist(Playlist)
        case artist(Artist)
    }

    private enum CarouselSectionType {
        case playlists
        case featuredOn
        case similarArtists
        case other
    }

    private static func carouselSectionType(from renderer: [String: Any]) -> CarouselSectionType {
        let title = self.carouselTitle(from: renderer)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if title.contains("featured"), title.contains("on") {
            return .featuredOn
        }
        if title.contains("fans"), title.contains("like") || title.contains("similar") {
            return .similarArtists
        }
        if title.contains("playlist") {
            return .playlists
        }
        return .other
    }

    private static func carouselTitle(from renderer: [String: Any]) -> String? {
        guard let header = renderer["header"] as? [String: Any],
              let basicHeader = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any],
              let title = ParsingHelpers.extractTitle(from: basicHeader)
        else {
            return nil
        }

        return title
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
                let author = ParsingHelpers.extractFirstNavigableArtist(from: runs)?.name
                    ?? runs.compactMap { run -> String? in
                        guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !text.isEmpty,
                              text != "•"
                        else {
                            return nil
                        }
                        return text
                    }.first

                return .playlist(Playlist(
                    id: browseId,
                    title: title,
                    description: nil,
                    thumbnailURL: thumbnailURL,
                    trackCount: nil,
                    author: author.map { Artist(id: UUID().uuidString, name: $0) }
                ))
            }

            if ParsingHelpers.isArtistPageType(pageType) || Artist.isNavigableId(browseId) {
                return .artist(Artist(
                    id: browseId,
                    name: title,
                    thumbnailURL: thumbnailURL,
                    subtitle: subtitleText
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
                subtitle: subtitleText
            ))
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
