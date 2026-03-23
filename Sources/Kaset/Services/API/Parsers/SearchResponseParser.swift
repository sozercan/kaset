import Foundation

/// Parser for search responses from YouTube Music API.
enum SearchResponseParser {
    private static let logger = DiagnosticsLogger.api

    /// Parses a search response.
    static func parse(_ data: [String: Any]) -> SearchResponse {
        var songs: [Song] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []

        // Navigate to contents
        guard let contents = data["contents"] as? [String: Any],
              let tabbedSearchResults = contents["tabbedSearchResultsRenderer"] as? [String: Any],
              let tabs = tabbedSearchResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            Self.logger.debug("SearchResponseParser: Failed to parse response structure. Top keys: \(data.keys.sorted())")
            return SearchResponse.empty
        }

        for sectionData in sectionContents {
            // Parse musicCardShelfRenderer (Top Result section)
            if let cardShelfRenderer = sectionData["musicCardShelfRenderer"] as? [String: Any] {
                if let item = parseCardShelfRenderer(cardShelfRenderer) {
                    Self.appendItem(item, songs: &songs, albums: &albums, artists: &artists, playlists: &playlists)
                }
            }

            // Parse musicShelfRenderer (regular results)
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData) {
                        Self.appendItem(item, songs: &songs, albums: &albums, artists: &artists, playlists: &playlists)
                    }
                }
            }
        }

        return SearchResponse(songs: songs, albums: albums, artists: artists, playlists: playlists)
    }

    /// Helper to append a search result item to the appropriate array.
    private static func appendItem(
        _ item: SearchResultItem,
        songs: inout [Song],
        albums: inout [Album],
        artists: inout [Artist],
        playlists: inout [Playlist]
    ) {
        switch item {
        case let .song(song):
            songs.append(song)
        case let .album(album):
            albums.append(album)
        case let .artist(artist):
            artists.append(artist)
        case let .playlist(playlist):
            playlists.append(playlist)
        case .podcastShow:
            // Podcast shows not parsed in general search
            break
        }
    }

    /// Parses a filtered songs-only search response.
    /// Filtered searches have a simpler structure without tabs.
    static func parseSongsOnly(_ data: [String: Any]) -> [Song] {
        var songs: [Song] = []

        // Filtered search has a simpler structure - no tabs
        guard let contents = data["contents"] as? [String: Any],
              let sectionListRenderer = contents["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            // Try tabbed structure as fallback
            let response = self.parse(data)
            return response.songs
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .song(song) = item
                    {
                        songs.append(song)
                    }
                }
            }
        }

        return songs
    }

    // MARK: - Item Parsing

    /// Parses a musicCardShelfRenderer (Top Result section).
    /// This renderer contains a single prominent result with title, subtitle, and browse endpoint.
    private static func parseCardShelfRenderer(_ data: [String: Any]) -> SearchResultItem? {
        // Extract title and navigation from the title runs
        guard let titleData = data["title"] as? [String: Any],
              let runs = titleData["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let title = firstRun["text"] as? String,
              let navigationEndpoint = firstRun["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            return nil
        }

        // Extract thumbnail
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        // Extract subtitle
        var subtitle: String?
        if let subtitleData = data["subtitle"] as? [String: Any],
           let subtitleRuns = subtitleData["runs"] as? [[String: Any]]
        {
            subtitle = subtitleRuns.compactMap { $0["text"] as? String }.joined()
        }

        // Extract pageType for accurate type detection
        let pageType = self.extractPageType(from: browseEndpoint)

        // Determine type based on pageType first, then fall back to browseId prefix
        if pageType == "MUSIC_PAGE_TYPE_ALBUM" || browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            let album = Album(
                id: browseId,
                title: title,
                artists: nil,
                thumbnailURL: thumbnailURL,
                year: nil,
                trackCount: nil
            )
            return .album(album)
        } else if pageType == "MUSIC_PAGE_TYPE_ARTIST" || pageType == "MUSIC_PAGE_TYPE_USER_CHANNEL" || browseId.hasPrefix("UC") {
            let artist = Artist(id: browseId, name: title, thumbnailURL: thumbnailURL)
            return .artist(artist)
        } else if pageType == "MUSIC_PAGE_TYPE_PLAYLIST" || browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
            let playlist = Playlist(
                id: browseId,
                title: title,
                description: nil,
                thumbnailURL: thumbnailURL,
                trackCount: nil,
                author: subtitle
            )
            return .playlist(playlist)
        }

        return nil
    }

    private static func parseSearchResultItem(_ data: [String: Any]) -> SearchResultItem? {
        guard let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] else {
            return nil
        }

        // Try to get videoId for songs
        if let playlistItemData = responsiveRenderer["playlistItemData"] as? [String: Any],
           let videoId = playlistItemData["videoId"] as? String
        {
            return self.parseSongFromResponsiveRenderer(responsiveRenderer, videoId: videoId)
        }

        // Check navigation endpoint for other types
        if let navigationEndpoint = responsiveRenderer["navigationEndpoint"] as? [String: Any],
           let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String
        {
            let thumbnails = ParsingHelpers.extractThumbnails(from: responsiveRenderer)
            let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
            let title = ParsingHelpers.extractTitleFromFlexColumns(responsiveRenderer) ?? "Unknown"
            let subtitle = ParsingHelpers.extractSubtitleFromFlexColumns(responsiveRenderer)

            // Extract pageType from browseEndpointContextSupportedConfigs for accurate type detection
            let pageType = self.extractPageType(from: browseEndpoint)

            // Determine type based on pageType first, then fall back to browseId prefix
            if pageType == "MUSIC_PAGE_TYPE_ALBUM" || browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
                let album = Album(
                    id: browseId,
                    title: title,
                    artists: nil,
                    thumbnailURL: thumbnailURL,
                    year: nil,
                    trackCount: nil
                )
                return .album(album)
            } else if pageType == "MUSIC_PAGE_TYPE_ARTIST" || pageType == "MUSIC_PAGE_TYPE_USER_CHANNEL" || browseId.hasPrefix("UC") {
                let artist = Artist(id: browseId, name: title, thumbnailURL: thumbnailURL)
                return .artist(artist)
            } else if pageType == "MUSIC_PAGE_TYPE_PLAYLIST" || browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
                let playlist = Playlist(
                    id: browseId,
                    title: title,
                    description: nil,
                    thumbnailURL: thumbnailURL,
                    trackCount: nil,
                    author: subtitle
                )
                return .playlist(playlist)
            }
        }

        return nil
    }

    // MARK: - Helpers

    private static func extractPageType(from browseEndpoint: [String: Any]) -> String? {
        if let contextConfigs = browseEndpoint["browseEndpointContextSupportedConfigs"] as? [String: Any],
           let musicConfig = contextConfigs["browseEndpointContextMusicConfig"] as? [String: Any],
           let type = musicConfig["pageType"] as? String
        {
            return type
        }
        return nil
    }

    private static func parseSongFromResponsiveRenderer(
        _ data: [String: Any],
        videoId: String
    ) -> SearchResultItem? {
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown"
        let artists = ParsingHelpers.extractArtistsFromFlexColumns(data)
        let album = ParsingHelpers.extractAlbumFromFlexColumns(data)

        let song = Song(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            duration: nil,
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )
        return .song(song)
    }

    // MARK: - Filtered Search Parsing

    /// Extracts the continuation token from a filtered search response.
    private static func extractContinuationToken(from sectionListRenderer: [String: Any]) -> String? {
        // Check for continuations array
        if let continuations = sectionListRenderer["continuations"] as? [[String: Any]],
           let firstContinuation = continuations.first,
           let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
           let token = nextContinuationData["continuation"] as? String
        {
            return token
        }
        return nil
    }

    /// Helper to get sectionListRenderer from filtered search response.
    private static func getSectionListRenderer(from data: [String: Any]) -> [String: Any]? {
        // Try filtered search structure first (no tabs)
        if let contents = data["contents"] as? [String: Any],
           let sectionListRenderer = contents["sectionListRenderer"] as? [String: Any]
        {
            return sectionListRenderer
        }

        // Try tabbed structure as fallback
        if let contents = data["contents"] as? [String: Any],
           let tabbedSearchResults = contents["tabbedSearchResultsRenderer"] as? [String: Any],
           let tabs = tabbedSearchResults["tabs"] as? [[String: Any]],
           let firstTab = tabs.first,
           let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
           let tabContent = tabRenderer["content"] as? [String: Any],
           let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any]
        {
            return sectionListRenderer
        }

        return nil
    }

    /// Parses albums from a filtered search response with continuation token.
    static func parseAlbumsOnly(_ data: [String: Any]) -> ([Album], String?) {
        var albums: [Album] = []

        guard let sectionListRenderer = getSectionListRenderer(from: data),
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return ([], nil)
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .album(album) = item
                    {
                        albums.append(album)
                    }
                }
            }
        }

        let token = Self.extractContinuationToken(from: sectionListRenderer)
        return (albums, token)
    }

    /// Parses artists from a filtered search response with continuation token.
    static func parseArtistsOnly(_ data: [String: Any]) -> ([Artist], String?) {
        var artists: [Artist] = []

        guard let sectionListRenderer = getSectionListRenderer(from: data),
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return ([], nil)
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .artist(artist) = item
                    {
                        artists.append(artist)
                    }
                }
            }
        }

        let token = Self.extractContinuationToken(from: sectionListRenderer)
        return (artists, token)
    }

    /// Parses playlists from a filtered search response with continuation token.
    static func parsePlaylistsOnly(_ data: [String: Any]) -> ([Playlist], String?) {
        var playlists: [Playlist] = []

        guard let sectionListRenderer = getSectionListRenderer(from: data),
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return ([], nil)
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .playlist(playlist) = item
                    {
                        playlists.append(playlist)
                    }
                }
            }
        }

        let token = Self.extractContinuationToken(from: sectionListRenderer)
        return (playlists, token)
    }

    /// Parses podcasts from a filtered search response with continuation token.
    static func parsePodcastsOnly(_ data: [String: Any]) -> ([PodcastShow], String?) {
        var podcasts: [PodcastShow] = []

        guard let sectionListRenderer = getSectionListRenderer(from: data),
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return ([], nil)
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let show = Self.parsePodcastShowFromSearchResult(itemData) {
                        podcasts.append(show)
                    }
                }
            }
        }

        let token = Self.extractContinuationToken(from: sectionListRenderer)
        return (podcasts, token)
    }

    /// Parses a podcast show from a search result item.
    private static func parsePodcastShowFromSearchResult(_ data: [String: Any]) -> PodcastShow? {
        guard let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] else {
            return nil
        }

        // Check navigation endpoint for browse ID
        guard let navigationEndpoint = responsiveRenderer["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String,
              browseId.hasPrefix("MPSPP")
        else {
            return nil
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: responsiveRenderer)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitleFromFlexColumns(responsiveRenderer) ?? "Unknown Podcast"
        let author = ParsingHelpers.extractSubtitleFromFlexColumns(responsiveRenderer)

        return PodcastShow(
            id: browseId,
            title: title,
            author: author,
            description: nil,
            thumbnailURL: thumbnailURL,
            episodeCount: nil
        )
    }

    /// Parses songs from a filtered search response with continuation token.
    static func parseSongsWithContinuation(_ data: [String: Any]) -> ([Song], String?) {
        var songs: [Song] = []

        guard let sectionListRenderer = getSectionListRenderer(from: data),
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return ([], nil)
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .song(song) = item
                    {
                        songs.append(song)
                    }
                }
            }
        }

        let token = Self.extractContinuationToken(from: sectionListRenderer)
        return (songs, token)
    }

    /// Parses a search continuation response.
    /// Returns a SearchResponse with all item types and optional continuation token.
    static func parseContinuation(_ data: [String: Any]) -> SearchResponse {
        var songs: [Song] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
        var podcastShows: [PodcastShow] = []
        var continuationToken: String?

        // Continuation responses have a different structure
        if let continuationContents = data["continuationContents"] as? [String: Any],
           let musicShelfContinuation = continuationContents["musicShelfContinuation"] as? [String: Any]
        {
            // Parse items
            if let contents = musicShelfContinuation["contents"] as? [[String: Any]] {
                for itemData in contents {
                    // Try to parse as podcast show first (for podcast search continuation)
                    if let show = Self.parsePodcastShowFromSearchResult(itemData) {
                        podcastShows.append(show)
                    } else if let item = parseSearchResultItem(itemData) {
                        Self.appendItem(item, songs: &songs, albums: &albums, artists: &artists, playlists: &playlists)
                    }
                }
            }

            // Extract next continuation token
            if let continuations = musicShelfContinuation["continuations"] as? [[String: Any]],
               let firstContinuation = continuations.first,
               let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
               let token = nextContinuationData["continuation"] as? String
            {
                continuationToken = token
            }
        }

        return SearchResponse(
            songs: songs,
            albums: albums,
            artists: artists,
            playlists: playlists,
            podcastShows: podcastShows,
            continuationToken: continuationToken
        )
    }
}
