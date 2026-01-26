import Foundation

/// Parser for home page and explore page responses from YouTube Music API.
enum HomeResponseParser {
    private static let logger = DiagnosticsLogger.api

    /// Parses the main home/explore response.
    static func parse(_ data: [String: Any]) -> HomeResponse {
        var sections: [HomeSection] = []

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
            // Log what top-level keys we have for debugging
            self.logger.debug("HomeResponseParser: No standard structure found. Top keys: \(data.keys.sorted())")
            if let contents = data["contents"] as? [String: Any] {
                self.logger.debug("HomeResponseParser: Contents keys: \(contents.keys.sorted())")
            }
            return HomeResponse(sections: [])
        }

        for sectionData in sectionContents {
            if let section = parseHomeSection(sectionData) {
                sections.append(section)
            }
        }

        return HomeResponse(sections: sections)
    }

    /// Parses a continuation response for additional sections.
    static func parseContinuation(_ data: [String: Any]) -> [HomeSection] {
        var sections: [HomeSection] = []

        // Try continuationContents
        if let continuationContents = data["continuationContents"] as? [String: Any] {
            // Try sectionListContinuation
            if let sectionListContinuation = continuationContents["sectionListContinuation"] as? [String: Any],
               let contents = sectionListContinuation["contents"] as? [[String: Any]]
            {
                for sectionData in contents {
                    if let section = parseHomeSection(sectionData) {
                        sections.append(section)
                    }
                }
            }

            // Try musicShelfContinuation
            if let shelfContinuation = continuationContents["musicShelfContinuation"] as? [String: Any] {
                if let section = parseMusicShelf(shelfContinuation) {
                    sections.append(section)
                }
            }
        }

        return sections
    }

    /// Extracts continuation token from the main response.
    static func extractContinuationToken(from data: [String: Any]) -> String? {
        guard let contents = data["contents"] as? [String: Any],
              let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let continuations = sectionListRenderer["continuations"] as? [[String: Any]],
              let firstContinuation = continuations.first,
              let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
              let token = nextContinuationData["continuation"] as? String
        else {
            return nil
        }
        return token
    }

    /// Extracts continuation token from a continuation response.
    static func extractContinuationTokenFromContinuation(_ data: [String: Any]) -> String? {
        if let continuationContents = data["continuationContents"] as? [String: Any],
           let sectionListContinuation = continuationContents["sectionListContinuation"] as? [String: Any],
           let continuations = sectionListContinuation["continuations"] as? [[String: Any]],
           let firstContinuation = continuations.first,
           let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
           let token = nextContinuationData["continuation"] as? String
        {
            return token
        }
        return nil
    }

    // MARK: - Section Parsing

    static func parseHomeSection(_ data: [String: Any]) -> HomeSection? {
        // Try musicCarouselShelfRenderer (most common - horizontal carousels)
        if let carouselRenderer = data["musicCarouselShelfRenderer"] as? [String: Any] {
            return self.parseMusicCarouselShelf(carouselRenderer)
        }

        // Try musicShelfRenderer (vertical song lists)
        if let shelfRenderer = data["musicShelfRenderer"] as? [String: Any] {
            return self.parseMusicShelf(shelfRenderer)
        }

        // Try musicCardShelfRenderer (large featured cards like mixes)
        if let cardShelfRenderer = data["musicCardShelfRenderer"] as? [String: Any] {
            return self.parseMusicCardShelf(cardShelfRenderer)
        }

        // Try musicImmersiveCarouselShelfRenderer (immersive carousels with backgrounds)
        if let immersiveCarouselRenderer = data["musicImmersiveCarouselShelfRenderer"] as? [String: Any] {
            return self.parseMusicImmersiveCarouselShelf(immersiveCarouselRenderer)
        }

        // Try gridRenderer (used for charts and grids)
        if let gridRenderer = data["gridRenderer"] as? [String: Any] {
            return self.parseGridRenderer(gridRenderer)
        }

        // Try itemSectionRenderer (wrapper for other renderers)
        if let itemSectionRenderer = data["itemSectionRenderer"] as? [String: Any],
           let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
        {
            for itemContent in itemContents {
                if let section = parseHomeSection(itemContent) {
                    return section
                }
            }
        }

        // Log unrecognized renderers for debugging
        let rendererKeys = data.keys.filter { $0.hasSuffix("Renderer") }
        if !rendererKeys.isEmpty {
            self.logger.debug("HomeResponseParser: Unrecognized renderer(s): \(rendererKeys)")
        }

        return nil
    }

    private static func parseMusicCarouselShelf(_ data: [String: Any]) -> HomeSection? {
        let title = self.extractCarouselTitle(from: data) ?? "Unknown Section"

        guard let contents = data["contents"] as? [[String: Any]] else {
            return nil
        }

        var items: [HomeSectionItem] = []
        for itemData in contents {
            if let item = parseHomeSectionItem(itemData) {
                items.append(item)
            }
        }

        guard !items.isEmpty else { return nil }

        // Generate stable ID from title and first item to avoid SwiftUI identity churn
        let firstItemId = items.first.map { Self.extractItemId($0) } ?? ""
        let stableId = ParsingHelpers.stableId(title: title, components: firstItemId)

        return HomeSection(
            id: stableId,
            title: title,
            items: items,
            isChart: ParsingHelpers.isChartSection(title)
        )
    }

    private static func parseMusicShelf(_ data: [String: Any]) -> HomeSection? {
        let title = ParsingHelpers.extractTitle(from: data) ?? "Unknown Section"

        guard let contents = data["contents"] as? [[String: Any]] else {
            return nil
        }

        var items: [HomeSectionItem] = []
        for itemData in contents {
            if let item = parseHomeSectionItem(itemData) {
                items.append(item)
            }
        }

        guard !items.isEmpty else { return nil }

        // Generate stable ID from title and first item to avoid SwiftUI identity churn
        let firstItemId = items.first.map { Self.extractItemId($0) } ?? ""
        let stableId = ParsingHelpers.stableId(title: title, components: firstItemId)

        return HomeSection(
            id: stableId,
            title: title,
            items: items,
            isChart: ParsingHelpers.isChartSection(title)
        )
    }

    private static func parseMusicCardShelf(_ data: [String: Any]) -> HomeSection? {
        let title: String = if let header = data["header"] as? [String: Any],
                               let headerRenderer = header["musicCardShelfHeaderBasicRenderer"] as? [String: Any],
                               let text = ParsingHelpers.extractTitle(from: headerRenderer)
        {
            text
        } else {
            "Featured"
        }

        guard let contents = data["contents"] as? [[String: Any]] else {
            return nil
        }

        var items: [HomeSectionItem] = []
        for itemData in contents {
            if let item = parseHomeSectionItem(itemData) {
                items.append(item)
            }
        }

        guard !items.isEmpty else { return nil }

        // Generate stable ID from title and first item to avoid SwiftUI identity churn
        let firstItemId = items.first.map { Self.extractItemId($0) } ?? ""
        let stableId = ParsingHelpers.stableId(title: title, components: firstItemId)

        return HomeSection(
            id: stableId,
            title: title,
            items: items,
            isChart: ParsingHelpers.isChartSection(title)
        )
    }

    private static func parseMusicImmersiveCarouselShelf(_ data: [String: Any]) -> HomeSection? {
        let title = self.extractCarouselTitle(from: data) ?? "Featured"

        guard let contents = data["contents"] as? [[String: Any]] else {
            return nil
        }

        var items: [HomeSectionItem] = []
        for itemData in contents {
            if let item = parseHomeSectionItem(itemData) {
                items.append(item)
            }
        }

        guard !items.isEmpty else { return nil }

        // Generate stable ID from title and first item to avoid SwiftUI identity churn
        let firstItemId = items.first.map { Self.extractItemId($0) } ?? ""
        let stableId = ParsingHelpers.stableId(title: title, components: firstItemId)

        return HomeSection(
            id: stableId,
            title: title,
            items: items,
            isChart: ParsingHelpers.isChartSection(title)
        )
    }

    private static func parseGridRenderer(_ data: [String: Any]) -> HomeSection? {
        let title: String = if let header = data["header"] as? [String: Any],
                               let headerRenderer = header["gridHeaderRenderer"] as? [String: Any],
                               let text = ParsingHelpers.extractTitle(from: headerRenderer)
        {
            text
        } else {
            "Charts"
        }

        guard let items = data["items"] as? [[String: Any]] else {
            return nil
        }

        var sectionItems: [HomeSectionItem] = []
        for itemData in items {
            if let item = parseHomeSectionItem(itemData) {
                sectionItems.append(item)
            }
        }

        guard !sectionItems.isEmpty else { return nil }

        // Generate stable ID from title and first item to avoid SwiftUI identity churn
        let firstItemId = sectionItems.first.map { Self.extractItemId($0) } ?? ""
        let stableId = ParsingHelpers.stableId(title: title, components: firstItemId)

        // Check if this is a chart section based on title, not renderer type
        return HomeSection(id: stableId, title: title, items: sectionItems, isChart: ParsingHelpers.isChartSection(title))
    }

    // MARK: - Item Parsing

    static func parseHomeSectionItem(_ data: [String: Any]) -> HomeSectionItem? {
        // Try musicTwoRowItemRenderer (albums, playlists)
        if let twoRowRenderer = data["musicTwoRowItemRenderer"] as? [String: Any] {
            return self.parseTwoRowItem(twoRowRenderer)
        }

        // Try musicResponsiveListItemRenderer (songs)
        if let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] {
            return self.parseResponsiveListItem(responsiveRenderer)
        }

        // Try musicNavigationButtonRenderer (moods/genres category buttons)
        if let buttonRenderer = data["musicNavigationButtonRenderer"] as? [String: Any] {
            return self.parseNavigationButton(buttonRenderer)
        }

        return nil
    }

    private static func parseNavigationButton(_ data: [String: Any]) -> HomeSectionItem? {
        // Extract title from buttonText
        guard let buttonText = data["buttonText"] as? [String: Any],
              let runs = buttonText["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let title = firstRun["text"] as? String
        else {
            return nil
        }

        // Extract browse endpoint
        guard let clickCommand = data["clickCommand"] as? [String: Any],
              let browseEndpoint = clickCommand["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            return nil
        }

        // Moods/genres browse IDs often start with "FEmusic_moods_and_genres_category"
        // but the actual content is a playlist. Create a unique ID using browseId + params
        // to avoid duplicate IDs when the same browseId appears in multiple sections.
        let params = browseEndpoint["params"] as? String
        let uniqueId = params != nil ? "\(browseId)_\(params!)" : browseId

        // Try to extract thumbnail URL (some navigation buttons have iconImage)
        var thumbnailURL: URL?
        if let iconImage = data["iconImage"] as? [String: Any],
           let thumbnails = iconImage["thumbnails"] as? [[String: Any]],
           let lastThumb = thumbnails.last,
           let urlString = lastThumb["url"] as? String
        {
            thumbnailURL = URL(string: ParsingHelpers.normalizeURL(urlString))
        }

        // Extract the leftStripeColor from solid block (mood/genre card color)
        // This is a 32-bit ARGB color value from the YouTube Music API
        var colorHex: String?
        if let solid = data["solid"] as? [String: Any],
           let colorValue = solid["leftStripeColor"] as? Int
        {
            // Convert to hex string (ARGB format from API, we'll use RGB portion)
            let rgb = colorValue & 0x00FF_FFFF
            colorHex = String(format: "#%06X", rgb)
        }

        let playlist = Playlist(
            id: uniqueId,
            title: title,
            description: colorHex, // Store color hex in description for mood cards
            thumbnailURL: thumbnailURL,
            trackCount: nil,
            author: nil
        )
        return .playlist(playlist)
    }

    private static func parseTwoRowItem(_ data: [String: Any]) -> HomeSectionItem? {
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        guard let title = ParsingHelpers.extractTitle(from: data) else {
            return nil
        }

        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any] else {
            return nil
        }

        // Check for watchEndpoint (song/video)
        if let watchEndpoint = navigationEndpoint["watchEndpoint"] as? [String: Any],
           let videoId = watchEndpoint["videoId"] as? String
        {
            let song = Song(
                id: videoId,
                title: title,
                artists: ParsingHelpers.extractArtists(from: data),
                album: nil,
                duration: nil,
                thumbnailURL: thumbnailURL,
                videoId: videoId
            )
            return .song(song)
        }

        // Check for browseEndpoint
        if let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String
        {
            let pageType = self.extractPageType(from: browseEndpoint)
            return self.createItemFromBrowseEndpoint(
                browseId: browseId,
                pageType: pageType,
                title: title,
                thumbnailURL: thumbnailURL,
                data: data
            )
        }

        return nil
    }

    private static func parseResponsiveListItem(_ data: [String: Any]) -> HomeSectionItem? {
        guard let videoId = ParsingHelpers.extractVideoId(from: data) else {
            // Might be a non-song item
            if let browseId = ParsingHelpers.extractBrowseId(from: data) {
                return self.parseResponsiveListItemAsBrowse(data, browseId: browseId)
            }
            return nil
        }

        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown"
        let artists = ParsingHelpers.extractArtistsFromFlexColumns(data)
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let duration = ParsingHelpers.extractDurationFromFlexColumns(data)
        let album = ParsingHelpers.extractAlbumFromFlexColumns(data)

        let song = Song(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            duration: duration,
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )
        return .song(song)
    }

    private static func parseResponsiveListItemAsBrowse(_ data: [String: Any], browseId: String) -> HomeSectionItem? {
        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown"
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        // Determine type from browseId prefix
        if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            let album = Album(
                id: browseId,
                title: title,
                artists: ParsingHelpers.extractArtistsFromFlexColumns(data),
                thumbnailURL: thumbnailURL,
                year: nil,
                trackCount: nil
            )
            return .album(album)
        } else if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
            let playlist = Playlist(
                id: browseId,
                title: title,
                description: nil,
                thumbnailURL: thumbnailURL,
                trackCount: nil,
                author: ParsingHelpers.extractSubtitleFromFlexColumns(data)
            )
            return .playlist(playlist)
        } else if browseId.hasPrefix("UC") {
            let artist = Artist(
                id: browseId,
                name: title,
                thumbnailURL: thumbnailURL
            )
            return .artist(artist)
        }

        return nil
    }

    // MARK: - Helpers

    /// Extracts a stable ID from a HomeSectionItem for identity purposes.
    private static func extractItemId(_ item: HomeSectionItem) -> String {
        switch item {
        case let .song(song): song.id
        case let .album(album): album.id
        case let .playlist(playlist): playlist.id
        case let .artist(artist): artist.id
        }
    }

    private static func extractCarouselTitle(from data: [String: Any]) -> String? {
        if let header = data["header"] as? [String: Any],
           let headerRenderer = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
        {
            return ParsingHelpers.extractTitle(from: headerRenderer)
        }
        return nil
    }

    private static func extractPageType(from browseEndpoint: [String: Any]) -> String? {
        if let contextConfigs = browseEndpoint["browseEndpointContextSupportedConfigs"] as? [String: Any],
           let musicConfig = contextConfigs["browseEndpointContextMusicConfig"] as? [String: Any],
           let type = musicConfig["pageType"] as? String
        {
            return type
        }
        return nil
    }

    private enum BrowseItemType {
        case album
        case playlist
        case artist
    }

    private static func determineBrowseItemType(browseId: String, pageType: String?) -> BrowseItemType? {
        // Check pageType first (most reliable)
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM":
            return .album
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
            return .artist
        default:
            break
        }

        // Fall back to browseId prefix
        if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            return .album
        }
        if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") {
            return .playlist
        }
        if browseId.hasPrefix("UC") {
            return .artist
        }

        return nil
    }

    private static func createItemFromBrowseEndpoint(
        browseId: String,
        pageType: String?,
        title: String,
        thumbnailURL: URL?,
        data: [String: Any]
    ) -> HomeSectionItem? {
        guard let itemType = determineBrowseItemType(browseId: browseId, pageType: pageType) else {
            return nil
        }

        switch itemType {
        case .album:
            let album = Album(
                id: browseId,
                title: title,
                artists: ParsingHelpers.extractArtists(from: data),
                thumbnailURL: thumbnailURL,
                year: nil,
                trackCount: nil
            )
            return .album(album)

        case .playlist:
            let playlist = Playlist(
                id: browseId,
                title: title,
                description: nil,
                thumbnailURL: thumbnailURL,
                trackCount: nil,
                author: ParsingHelpers.extractSubtitle(from: data)
            )
            return .playlist(playlist)

        case .artist:
            let artist = Artist(
                id: browseId,
                name: title,
                thumbnailURL: thumbnailURL
            )
            return .artist(artist)
        }
    }
}
