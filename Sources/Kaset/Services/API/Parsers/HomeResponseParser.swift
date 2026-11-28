import Foundation

enum HomeResponseParser {
    private static let logger = DiagnosticsLogger.api

    static func parse(_ data: [String: Any]) -> HomeResponse {
        var sections: [HomeSection] = []

        guard let contents = data["contents"] as? [String: Any],
              let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            self.logger.debug("HomeResponseParser: No standard structure found. Top keys: \(data.keys.sorted())")
            if let contents = data["contents"] as? [String: Any] {
                self.logger.debug("HomeResponseParser: Contents keys: \(contents.keys.sorted())")
            }
            return HomeResponse(sections: [])
        }

        sections.reserveCapacity(sectionContents.count)
        for sectionData in sectionContents {
            if let section = parseHomeSection(sectionData) {
                sections.append(section)
            }
        }

        return HomeResponse(sections: sections)
    }

    static func parseContinuation(_ data: [String: Any]) -> [HomeSection] {
        var sections: [HomeSection] = []

        if let continuationContents = data["continuationContents"] as? [String: Any] {
            if let sectionListContinuation = continuationContents["sectionListContinuation"] as? [String: Any],
               let contents = sectionListContinuation["contents"] as? [[String: Any]]
            {
                for sectionData in contents {
                    if let section = parseHomeSection(sectionData) {
                        sections.append(section)
                    }
                }
            }

            if let shelfContinuation = continuationContents["musicShelfContinuation"] as? [String: Any] {
                if let section = parseMusicShelf(shelfContinuation) {
                    sections.append(section)
                }
            }
        }

        return sections
    }

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

    static func parseHomeSection(_ data: [String: Any]) -> HomeSection? {
        if let carouselRenderer = data["musicCarouselShelfRenderer"] as? [String: Any] {
            return self.parseMusicCarouselShelf(carouselRenderer)
        }

        if let shelfRenderer = data["musicShelfRenderer"] as? [String: Any] {
            return self.parseMusicShelf(shelfRenderer)
        }

        if let cardShelfRenderer = data["musicCardShelfRenderer"] as? [String: Any] {
            return self.parseMusicCardShelf(cardShelfRenderer)
        }

        if let immersiveCarouselRenderer = data["musicImmersiveCarouselShelfRenderer"] as? [String: Any] {
            return self.parseMusicImmersiveCarouselShelf(immersiveCarouselRenderer)
        }

        if let gridRenderer = data["gridRenderer"] as? [String: Any] {
            return self.parseGridRenderer(gridRenderer)
        }

        if let itemSectionRenderer = data["itemSectionRenderer"] as? [String: Any],
           let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
        {
            for itemContent in itemContents {
                if let section = parseHomeSection(itemContent) {
                    return section
                }
            }
        }

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
        items.reserveCapacity(contents.count)
        for itemData in contents {
            if let item = parseHomeSectionItem(itemData) {
                items.append(item)
            }
        }

        guard !items.isEmpty else { return nil }

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
        items.reserveCapacity(contents.count)
        for itemData in contents {
            if let item = parseHomeSectionItem(itemData) {
                items.append(item)
            }
        }

        guard !items.isEmpty else { return nil }

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
        items.reserveCapacity(contents.count)
        for itemData in contents {
            if let item = parseHomeSectionItem(itemData) {
                items.append(item)
            }
        }

        guard !items.isEmpty else { return nil }

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
        items.reserveCapacity(contents.count)
        for itemData in contents {
            if let item = parseHomeSectionItem(itemData) {
                items.append(item)
            }
        }

        guard !items.isEmpty else { return nil }

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
        sectionItems.reserveCapacity(items.count)
        for itemData in items {
            if let item = parseHomeSectionItem(itemData) {
                sectionItems.append(item)
            }
        }

        guard !sectionItems.isEmpty else { return nil }

        let firstItemId = sectionItems.first.map { Self.extractItemId($0) } ?? ""
        let stableId = ParsingHelpers.stableId(title: title, components: firstItemId)

        return HomeSection(id: stableId, title: title, items: sectionItems, isChart: ParsingHelpers.isChartSection(title))
    }

    static func parseHomeSectionItem(_ data: [String: Any]) -> HomeSectionItem? {
        if let twoRowRenderer = data["musicTwoRowItemRenderer"] as? [String: Any] {
            return self.parseTwoRowItem(twoRowRenderer)
        }

        if let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] {
            return self.parseResponsiveListItem(responsiveRenderer)
        }

        if let buttonRenderer = data["musicNavigationButtonRenderer"] as? [String: Any] {
            return self.parseNavigationButton(buttonRenderer)
        }

        return nil
    }

    private static func parseNavigationButton(_ data: [String: Any]) -> HomeSectionItem? {
        guard let buttonText = data["buttonText"] as? [String: Any],
              let runs = buttonText["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let title = firstRun["text"] as? String
        else {
            return nil
        }

        guard let clickCommand = data["clickCommand"] as? [String: Any],
              let browseEndpoint = clickCommand["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            return nil
        }

        let params = browseEndpoint["params"] as? String
        let uniqueId = params != nil ? "\(browseId)_\(params!)" : browseId

        var thumbnailURL: URL?
        if let iconImage = data["iconImage"] as? [String: Any],
           let thumbnails = iconImage["thumbnails"] as? [[String: Any]],
           let lastThumb = thumbnails.last,
           let urlString = lastThumb["url"] as? String
        {
            thumbnailURL = URL(string: ParsingHelpers.normalizeURL(urlString))
        }

        var colorHex: String?
        if let solid = data["solid"] as? [String: Any],
           let colorValue = solid["leftStripeColor"] as? Int
        {
            let rgb = colorValue & 0x00FF_FFFF
            colorHex = String(format: "#%06X", rgb)
        }

        let playlist = Playlist(
            id: uniqueId,
            title: title,
            description: colorHex,
            thumbnailURL: thumbnailURL,
            trackCount: nil,
            author: nil,
            moodCategoryEndpoint: MoodCategory.isMoodCategory(browseId)
                ? MoodCategoryEndpoint(browseId: browseId, params: params)
                : nil
        )
        return .playlist(playlist)
    }

    private static func parseTwoRowItem(_ data: [String: Any]) -> HomeSectionItem? {
        let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: data)

        guard let title = ParsingHelpers.extractTitle(from: data) else {
            return nil
        }

        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any] else {
            return nil
        }

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
                videoId: videoId,
                musicVideoType: ParsingHelpers.extractMusicVideoType(from: data),
                isExplicit: ParsingHelpers.extractIsExplicit(from: data)
            )
            return .song(song)
        }

        if let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String
        {
            let pageType = ParsingHelpers.extractPageType(from: browseEndpoint)
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
            if let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
               let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
               let browseId = browseEndpoint["browseId"] as? String
            {
                let pageType = ParsingHelpers.extractPageType(from: browseEndpoint)
                return self.parseResponsiveListItemAsBrowse(data, browseId: browseId, pageType: pageType)
            }
            return nil
        }

        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown"
        let artists = ParsingHelpers.extractArtistsFromFlexColumns(data)
        let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: data)
        let duration = ParsingHelpers.extractDurationFromFlexColumns(data)
        let album = ParsingHelpers.extractAlbumFromFlexColumns(data)

        let song = Song(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            duration: duration,
            thumbnailURL: thumbnailURL,
            videoId: videoId,
            musicVideoType: ParsingHelpers.extractMusicVideoType(from: data),
            isExplicit: ParsingHelpers.extractIsExplicit(from: data)
        )
        return .song(song)
    }

    private static func parseResponsiveListItemAsBrowse(
        _ data: [String: Any],
        browseId: String,
        pageType: String?
    ) -> HomeSectionItem? {
        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown"
        let thumbnailURL = ParsingHelpers.extractThumbnailURL(from: data)

        guard let itemType = self.determineBrowseItemType(browseId: browseId, pageType: pageType) else {
            return nil
        }

        switch itemType {
        case .album:
            let album = Album(
                id: browseId,
                title: title,
                artists: ParsingHelpers.extractArtistsFromFlexColumns(data),
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
                author: ParsingHelpers.extractPlaylistAuthorFromFlexColumns(data)
            )
            return .playlist(playlist)

        case .artist:
            let artist = Artist(
                id: browseId,
                name: title,
                thumbnailURL: thumbnailURL,
                profileKind: Artist.profileKind(forPageType: pageType)
            )
            return .artist(artist)
        }
    }

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

    private enum BrowseItemType {
        case album
        case playlist
        case artist
    }

    private static func determineBrowseItemType(browseId: String, pageType: String?) -> BrowseItemType? {
        if pageType == "MUSIC_PAGE_TYPE_ALBUM" {
            return .album
        }
        if pageType == "MUSIC_PAGE_TYPE_PLAYLIST" {
            return .playlist
        }
        if ParsingHelpers.isArtistPageType(pageType) {
            return .artist
        }

        if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            return .album
        }
        if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") {
            return .playlist
        }
        if Artist.isNavigableId(browseId) {
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
                author: ParsingHelpers.extractPlaylistAuthor(from: data)
            )
            return .playlist(playlist)

        case .artist:
            let artist = Artist(
                id: browseId,
                name: title,
                thumbnailURL: thumbnailURL,
                profileKind: Artist.profileKind(forPageType: pageType)
            )
            return .artist(artist)
        }
    }
}
