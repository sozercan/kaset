import CryptoKit
import Foundation
import os

/// Client for making authenticated requests to YouTube Music's internal API.
@MainActor
final class YTMusicClient {
    private let authService: AuthService
    private let webKitManager: WebKitManager
    private let session: URLSession
    private let logger = DiagnosticsLogger.api

    /// YouTube Music API base URL.
    private static let baseURL = "https://music.youtube.com/youtubei/v1"

    /// API key used in requests (extracted from YouTube Music web client).
    private static let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"

    /// Client version for WEB_REMIX.
    private static let clientVersion = "1.20231204.01.00"

    init(authService: AuthService, webKitManager: WebKitManager = .shared) {
        self.authService = authService
        self.webKitManager = webKitManager

        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        ]
        session = URLSession(configuration: configuration)
    }

    // MARK: - Public API Methods

    /// Fetches the home page content.
    func getHome() async throws -> HomeResponse {
        logger.info("Fetching home page")

        let body: [String: Any] = [
            "browseId": "FEmusic_home",
        ]

        let data = try await request("browse", body: body)
        return parseHomeResponse(data)
    }

    /// Searches for content.
    func search(query: String) async throws -> SearchResponse {
        logger.info("Searching for: \(query)")

        let body: [String: Any] = [
            "query": query,
        ]

        let data = try await request("search", body: body)
        return parseSearchResponse(data)
    }

    /// Fetches the user's library playlists.
    func getLibraryPlaylists() async throws -> [Playlist] {
        logger.info("Fetching library playlists")

        let body: [String: Any] = [
            "browseId": "FEmusic_liked_playlists",
        ]

        let data = try await request("browse", body: body)
        return parseLibraryPlaylists(data)
    }

    /// Fetches playlist details including tracks.
    func getPlaylist(id: String) async throws -> PlaylistDetail {
        logger.info("Fetching playlist: \(id)")

        // Handle different ID formats:
        // - VL... = playlist (already has prefix)
        // - PL... = playlist (needs VL prefix)
        // - RD... = radio/mix (use as-is for watch endpoint)
        // - OLAK... = album (use as-is)
        let browseId: String = if id.hasPrefix("VL") || id.hasPrefix("RD") || id.hasPrefix("OLAK") || id.hasPrefix("UC") {
            id
        } else if id.hasPrefix("PL") {
            "VL\(id)"
        } else {
            "VL\(id)"
        }

        let body: [String: Any] = [
            "browseId": browseId,
        ]

        let data = try await request("browse", body: body)

        // Log top-level keys for debugging
        let topKeys = Array(data.keys)
        logger.debug("Playlist response top-level keys: \(topKeys)")

        return try parsePlaylistDetail(data, playlistId: id)
    }

    // MARK: - Private Methods

    /// Builds authentication headers for API requests.
    private func buildAuthHeaders() async throws -> [String: String] {
        guard let cookieHeader = await webKitManager.cookieHeader(for: "youtube.com") else {
            throw YTMusicError.notAuthenticated
        }

        guard let sapisid = await webKitManager.getSAPISID() else {
            throw YTMusicError.authExpired
        }

        // Compute SAPISIDHASH
        let origin = WebKitManager.origin
        let timestamp = Int(Date().timeIntervalSince1970)
        let hashInput = "\(timestamp) \(sapisid) \(origin)"
        let hash = Insecure.SHA1.hash(data: Data(hashInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let sapisidhash = "\(timestamp)_\(hash)"

        return [
            "Cookie": cookieHeader,
            "Authorization": "SAPISIDHASH \(sapisidhash)",
            "Origin": origin,
            "Referer": origin,
            "Content-Type": "application/json",
            "X-Goog-AuthUser": "0",
            "X-Origin": origin,
        ]
    }

    /// Builds the standard context payload.
    private func buildContext() -> [String: Any] {
        [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": Self.clientVersion,
                "hl": "en",
                "gl": "US",
                "experimentIds": [],
                "experimentsToken": "",
                "browserName": "Safari",
                "browserVersion": "17.0",
                "osName": "Macintosh",
                "osVersion": "10_15_7",
                "platform": "DESKTOP",
                "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "utcOffsetMinutes": -TimeZone.current.secondsFromGMT() / 60,
            ],
            "user": [
                "lockedSafetyMode": false,
            ],
        ]
    }

    /// Makes an authenticated request to the API.
    private func request(_ endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        let urlString = "\(Self.baseURL)/\(endpoint)?key=\(Self.apiKey)&prettyPrint=false"
        guard let url = URL(string: urlString) else {
            throw YTMusicError.unknown(message: "Invalid URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Add auth headers
        let headers = try await buildAuthHeaders()
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Build request body with context
        var fullBody = body
        fullBody["context"] = buildContext()

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        logger.debug("Making request to \(endpoint)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YTMusicError.networkError(underlying: URLError(.badServerResponse))
        }

        // Handle auth errors
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            logger.error("Auth error: HTTP \(httpResponse.statusCode)")
            authService.sessionExpired()
            throw YTMusicError.authExpired
        }

        // Handle other errors
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            logger.error("API error: HTTP \(httpResponse.statusCode)")
            throw YTMusicError.apiError(
                message: "HTTP \(httpResponse.statusCode)",
                code: httpResponse.statusCode
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMusicError.parseError(message: "Response is not a JSON object")
        }

        return json
    }

    // MARK: - Response Parsing

    private func parseHomeResponse(_ data: [String: Any]) -> HomeResponse {
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
            logger.warning("Could not parse home response structure")
            return HomeResponse(sections: [])
        }

        for sectionData in sectionContents {
            if let section = parseHomeSection(sectionData) {
                sections.append(section)
            }
        }

        logger.info("Parsed \(sections.count) home sections")
        return HomeResponse(sections: sections)
    }

    private func parseHomeSection(_ data: [String: Any]) -> HomeSection? {
        // Try musicCarouselShelfRenderer
        if let carouselRenderer = data["musicCarouselShelfRenderer"] as? [String: Any] {
            return parseMusicCarouselShelf(carouselRenderer)
        }

        // Try musicShelfRenderer
        if let shelfRenderer = data["musicShelfRenderer"] as? [String: Any] {
            return parseMusicShelf(shelfRenderer)
        }

        return nil
    }

    private func parseMusicCarouselShelf(_ data: [String: Any]) -> HomeSection? {
        // Get title
        let title: String = if let header = data["header"] as? [String: Any],
                               let headerRenderer = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any],
                               let titleData = headerRenderer["title"] as? [String: Any],
                               let runs = titleData["runs"] as? [[String: Any]],
                               let firstRun = runs.first,
                               let text = firstRun["text"] as? String
        {
            text
        } else {
            "Unknown Section"
        }

        // Parse items
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

        return HomeSection(id: UUID().uuidString, title: title, items: items)
    }

    private func parseMusicShelf(_ data: [String: Any]) -> HomeSection? {
        // Get title
        let title: String = if let titleData = data["title"] as? [String: Any],
                               let runs = titleData["runs"] as? [[String: Any]],
                               let firstRun = runs.first,
                               let text = firstRun["text"] as? String
        {
            text
        } else {
            "Unknown Section"
        }

        // Parse items
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

        return HomeSection(id: UUID().uuidString, title: title, items: items)
    }

    private func parseHomeSectionItem(_ data: [String: Any]) -> HomeSectionItem? {
        // Try musicTwoRowItemRenderer (albums, playlists)
        if let twoRowRenderer = data["musicTwoRowItemRenderer"] as? [String: Any] {
            return parseTwoRowItem(twoRowRenderer)
        }

        // Try musicResponsiveListItemRenderer (songs)
        if let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] {
            return parseResponsiveListItem(responsiveRenderer)
        }

        return nil
    }

    private func parseTwoRowItem(_ data: [String: Any]) -> HomeSectionItem? {
        // Extract common data
        let thumbnails = extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        // Get title
        guard let titleData = data["title"] as? [String: Any],
              let runs = titleData["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let title = firstRun["text"] as? String
        else {
            return nil
        }

        // Get navigation endpoint to determine type
        if let navigationEndpoint = data["navigationEndpoint"] as? [String: Any] {
            // Check for watchEndpoint (song/video)
            if let watchEndpoint = navigationEndpoint["watchEndpoint"] as? [String: Any],
               let videoId = watchEndpoint["videoId"] as? String
            {
                let song = Song(
                    id: videoId,
                    title: title,
                    artists: extractArtists(from: data),
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
                // Determine type based on browseId prefix
                if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
                    // Album
                    let album = Album(
                        id: browseId,
                        title: title,
                        artists: extractArtists(from: data),
                        thumbnailURL: thumbnailURL,
                        year: nil,
                        trackCount: nil
                    )
                    return .album(album)
                } else if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") {
                    // Playlist
                    let playlist = Playlist(
                        id: browseId,
                        title: title,
                        description: nil,
                        thumbnailURL: thumbnailURL,
                        trackCount: nil,
                        author: extractSubtitle(from: data)
                    )
                    return .playlist(playlist)
                } else if browseId.hasPrefix("UC") {
                    // Artist/Channel
                    let artist = Artist(
                        id: browseId,
                        name: title,
                        thumbnailURL: thumbnailURL
                    )
                    return .artist(artist)
                }
            }
        }

        return nil
    }

    private func parseResponsiveListItem(_ data: [String: Any]) -> HomeSectionItem? {
        // Extract playlistItemData for videoId
        if let playlistItemData = data["playlistItemData"] as? [String: Any],
           let videoId = playlistItemData["videoId"] as? String
        {
            let thumbnails = extractThumbnails(from: data)
            let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

            // Extract title from flexColumns
            var title = "Unknown"
            var artists: [Artist] = []

            if let flexColumns = data["flexColumns"] as? [[String: Any]] {
                for (index, column) in flexColumns.enumerated() {
                    if let renderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                       let textData = renderer["text"] as? [String: Any],
                       let runs = textData["runs"] as? [[String: Any]]
                    {
                        if index == 0 {
                            // First column is title
                            title = runs.compactMap { $0["text"] as? String }.joined()
                        } else if index == 1 {
                            // Second column typically contains artists
                            for run in runs {
                                if let text = run["text"] as? String,
                                   text != " • ", text != " & "
                                {
                                    if let endpoint = run["navigationEndpoint"] as? [String: Any],
                                       let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                                       let artistId = browseEndpoint["browseId"] as? String
                                    {
                                        artists.append(Artist(id: artistId, name: text))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            let song = Song(
                id: videoId,
                title: title,
                artists: artists,
                album: nil,
                duration: nil,
                thumbnailURL: thumbnailURL,
                videoId: videoId
            )
            return .song(song)
        }

        return nil
    }

    private func parseSearchResponse(_ data: [String: Any]) -> SearchResponse {
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
            logger.warning("Could not parse search response structure")
            return SearchResponse.empty
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData) {
                        switch item {
                        case let .song(song):
                            songs.append(song)
                        case let .album(album):
                            albums.append(album)
                        case let .artist(artist):
                            artists.append(artist)
                        case let .playlist(playlist):
                            playlists.append(playlist)
                        }
                    }
                }
            }
        }

        logger.info("Search found \(songs.count) songs, \(albums.count) albums, \(artists.count) artists, \(playlists.count) playlists")
        return SearchResponse(songs: songs, albums: albums, artists: artists, playlists: playlists)
    }

    private func parseSearchResultItem(_ data: [String: Any]) -> SearchResultItem? {
        guard let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] else {
            return nil
        }

        // Try to get videoId for songs
        if let playlistItemData = responsiveRenderer["playlistItemData"] as? [String: Any],
           let videoId = playlistItemData["videoId"] as? String
        {
            return parseSongFromResponsiveRenderer(responsiveRenderer, videoId: videoId)
        }

        // Check navigation endpoint for other types
        if let navigationEndpoint = responsiveRenderer["navigationEndpoint"] as? [String: Any],
           let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String
        {
            let thumbnails = extractThumbnails(from: responsiveRenderer)
            let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
            let title = extractTitleFromFlexColumns(responsiveRenderer)
            let subtitle = extractSubtitleFromFlexColumns(responsiveRenderer)

            if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
                let album = Album(
                    id: browseId,
                    title: title,
                    artists: nil,
                    thumbnailURL: thumbnailURL,
                    year: nil,
                    trackCount: nil
                )
                return .album(album)
            } else if browseId.hasPrefix("UC") {
                let artist = Artist(id: browseId, name: title, thumbnailURL: thumbnailURL)
                return .artist(artist)
            } else if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
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

    private func parseSongFromResponsiveRenderer(_ data: [String: Any], videoId: String) -> SearchResultItem? {
        let thumbnails = extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = extractTitleFromFlexColumns(data)
        let artists = extractArtistsFromFlexColumns(data)

        let song = Song(
            id: videoId,
            title: title,
            artists: artists,
            album: nil,
            duration: nil,
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )
        return .song(song)
    }

    private func parseLibraryPlaylists(_ data: [String: Any]) -> [Playlist] {
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
            logger.warning("Could not parse library playlists response structure")
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

        logger.info("Parsed \(playlists.count) library playlists")
        return playlists
    }

    private func parsePlaylistFromTwoRowRenderer(_ data: [String: Any]) -> Playlist? {
        // Get browse ID
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            return nil
        }

        let thumbnails = extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        // Get title
        let title: String = if let titleData = data["title"] as? [String: Any],
                               let runs = titleData["runs"] as? [[String: Any]],
                               let firstRun = runs.first,
                               let text = firstRun["text"] as? String
        {
            text
        } else {
            "Unknown Playlist"
        }

        return Playlist(
            id: browseId,
            title: title,
            description: nil,
            thumbnailURL: thumbnailURL,
            trackCount: nil,
            author: extractSubtitle(from: data)
        )
    }

    private func parsePlaylistFromResponsiveRenderer(_ data: [String: Any]) -> Playlist? {
        // Get browse ID
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String,
              browseId.hasPrefix("VL") || browseId.hasPrefix("PL")
        else {
            return nil
        }

        let thumbnails = extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = extractTitleFromFlexColumns(data)

        return Playlist(
            id: browseId,
            title: title,
            description: nil,
            thumbnailURL: thumbnailURL,
            trackCount: nil,
            author: extractSubtitleFromFlexColumns(data)
        )
    }

    private func parsePlaylistDetail(_ data: [String: Any], playlistId: String) throws -> PlaylistDetail {
        // Navigate to header
        var title = "Unknown Playlist"
        var description: String?
        var thumbnailURL: URL?
        var author: String?
        var duration: String?

        // Try musicDetailHeaderRenderer
        if let header = data["header"] as? [String: Any],
           let headerRenderer = header["musicDetailHeaderRenderer"] as? [String: Any]
        {
            // Title
            if let titleData = headerRenderer["title"] as? [String: Any],
               let runs = titleData["runs"] as? [[String: Any]],
               let firstRun = runs.first,
               let text = firstRun["text"] as? String
            {
                title = text
            }

            // Description
            if let descData = headerRenderer["description"] as? [String: Any],
               let runs = descData["runs"] as? [[String: Any]]
            {
                description = runs.compactMap { $0["text"] as? String }.joined()
            }

            // Thumbnail
            let thumbnails = extractThumbnails(from: headerRenderer)
            thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

            // Subtitle (author, track count, duration)
            if let subtitleData = headerRenderer["subtitle"] as? [String: Any],
               let runs = subtitleData["runs"] as? [[String: Any]]
            {
                let texts = runs.compactMap { $0["text"] as? String }
                author = texts.first
            }

            // Secondary subtitle (duration)
            if let secondSubtitleData = headerRenderer["secondSubtitle"] as? [String: Any],
               let runs = secondSubtitleData["runs"] as? [[String: Any]]
            {
                let texts = runs.compactMap { $0["text"] as? String }
                duration = texts.joined()
            }
        }

        // Try musicImmersiveHeaderRenderer (used for some playlists like mixes)
        if title == "Unknown Playlist",
           let header = data["header"] as? [String: Any],
           let immersiveHeader = header["musicImmersiveHeaderRenderer"] as? [String: Any]
        {
            if let titleData = immersiveHeader["title"] as? [String: Any],
               let runs = titleData["runs"] as? [[String: Any]],
               let firstRun = runs.first,
               let text = firstRun["text"] as? String
            {
                title = text
            }

            let thumbnails = extractThumbnails(from: immersiveHeader)
            thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

            if let descData = immersiveHeader["description"] as? [String: Any],
               let runs = descData["runs"] as? [[String: Any]]
            {
                description = runs.compactMap { $0["text"] as? String }.joined()
            }
        }

        // Try musicEditablePlaylistDetailHeaderRenderer (used for user playlists)
        if title == "Unknown Playlist",
           let header = data["header"] as? [String: Any],
           let editableHeader = header["musicEditablePlaylistDetailHeaderRenderer"] as? [String: Any],
           let headerData = editableHeader["header"] as? [String: Any],
           let detailHeader = headerData["musicDetailHeaderRenderer"] as? [String: Any]
        {
            if let titleData = detailHeader["title"] as? [String: Any],
               let runs = titleData["runs"] as? [[String: Any]],
               let firstRun = runs.first,
               let text = firstRun["text"] as? String
            {
                title = text
            }

            let thumbnails = extractThumbnails(from: detailHeader)
            thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

            if let subtitleData = detailHeader["subtitle"] as? [String: Any],
               let runs = subtitleData["runs"] as? [[String: Any]]
            {
                let texts = runs.compactMap { $0["text"] as? String }
                author = texts.first
            }
        }

        // Parse tracks
        var tracks: [Song] = []

        // Log contents structure for debugging
        if let contents = data["contents"] as? [String: Any] {
            let contentKeys = Array(contents.keys)
            logger.debug("Contents keys: \(contentKeys)")

            // Try singleColumnBrowseResultsRenderer path
            if let singleColumnBrowseResults = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
               let tabs = singleColumnBrowseResults["tabs"] as? [[String: Any]],
               let firstTab = tabs.first,
               let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
               let tabContent = tabRenderer["content"] as? [String: Any],
               let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
               let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
            {
                logger.debug("Found singleColumnBrowseResultsRenderer with \(sectionContents.count) sections")
                tracks.append(contentsOf: parseTracksFromSections(sectionContents))
            }

            // Try twoColumnBrowseResultsRenderer path (used by some playlists)
            if tracks.isEmpty,
               let twoColumnRenderer = contents["twoColumnBrowseResultsRenderer"] as? [String: Any],
               let secondaryContents = twoColumnRenderer["secondaryContents"] as? [String: Any],
               let sectionListRenderer = secondaryContents["sectionListRenderer"] as? [String: Any],
               let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
            {
                logger.debug("Found twoColumnBrowseResultsRenderer with \(sectionContents.count) sections")
                tracks.append(contentsOf: parseTracksFromSections(sectionContents))
            }
        }

        // If still no tracks, try to find them in continuationContents or other locations
        if tracks.isEmpty {
            logger.debug("No tracks found in standard locations, trying alternative paths")

            // Some responses put tracks directly in the section without the deep nesting
            if let contents = data["contents"] as? [String: Any] {
                for (key, value) in contents {
                    logger.debug("Trying contents key: \(key)")
                    if let renderer = value as? [String: Any] {
                        tracks.append(contentsOf: findTracksRecursively(in: renderer, depth: 0))
                        if !tracks.isEmpty {
                            break
                        }
                    }
                }
            }
        }

        logger.debug("Total tracks found: \(tracks.count)")

        let playlist = Playlist(
            id: playlistId,
            title: title,
            description: description,
            thumbnailURL: thumbnailURL,
            trackCount: tracks.count,
            author: author
        )

        logger.info("Parsed playlist '\(title)' with \(tracks.count) tracks")
        return PlaylistDetail(playlist: playlist, tracks: tracks, duration: duration)
    }

    /// Parses tracks from section contents.
    private func parseTracksFromSections(_ sections: [[String: Any]]) -> [Song] {
        var tracks: [Song] = []

        for sectionData in sections {
            // Try musicShelfRenderer
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                tracks.append(contentsOf: parseTracksFromItems(shelfContents))
            }

            // Try musicPlaylistShelfRenderer
            if let playlistShelf = sectionData["musicPlaylistShelfRenderer"] as? [String: Any],
               let shelfContents = playlistShelf["contents"] as? [[String: Any]]
            {
                tracks.append(contentsOf: parseTracksFromItems(shelfContents))
            }

            // Try musicCarouselShelfRenderer (sometimes used for related content)
            if let carouselShelf = sectionData["musicCarouselShelfRenderer"] as? [String: Any],
               let shelfContents = carouselShelf["contents"] as? [[String: Any]]
            {
                tracks.append(contentsOf: parseTracksFromItems(shelfContents))
            }
        }

        return tracks
    }

    /// Parses tracks from item array.
    private func parseTracksFromItems(_ items: [[String: Any]]) -> [Song] {
        var tracks: [Song] = []

        for itemData in items {
            if let responsiveRenderer = itemData["musicResponsiveListItemRenderer"] as? [String: Any] {
                if let song = parseSongFromResponsiveRenderer(responsiveRenderer) {
                    tracks.append(song)
                }
            }

            // Also try musicTwoRowItemRenderer (for some item formats)
            if let twoRowRenderer = itemData["musicTwoRowItemRenderer"] as? [String: Any] {
                if let song = parseSongFromTwoRowRenderer(twoRowRenderer) {
                    tracks.append(song)
                }
            }
        }

        return tracks
    }

    /// Parses a song from musicResponsiveListItemRenderer.
    private func parseSongFromResponsiveRenderer(_ data: [String: Any]) -> Song? {
        var videoId: String?

        // Try playlistItemData
        if let playlistItemData = data["playlistItemData"] as? [String: Any] {
            videoId = playlistItemData["videoId"] as? String
        }

        // Try flexColumns for videoId via navigationEndpoint
        if videoId == nil,
           let flexColumns = data["flexColumns"] as? [[String: Any]],
           let firstColumn = flexColumns.first,
           let musicResponsiveListItemFlexColumnRenderer = firstColumn["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let text = musicResponsiveListItemFlexColumnRenderer["text"] as? [String: Any],
           let runs = text["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let navEndpoint = firstRun["navigationEndpoint"] as? [String: Any],
           let watchEndpoint = navEndpoint["watchEndpoint"] as? [String: Any]
        {
            videoId = watchEndpoint["videoId"] as? String
        }

        // Try overlay
        if videoId == nil,
           let overlay = data["overlay"] as? [String: Any],
           let overlayRenderer = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = overlayRenderer["content"] as? [String: Any],
           let playButton = content["musicPlayButtonRenderer"] as? [String: Any],
           let playNav = playButton["playNavigationEndpoint"] as? [String: Any],
           let watchEndpoint = playNav["watchEndpoint"] as? [String: Any]
        {
            videoId = watchEndpoint["videoId"] as? String
        }

        guard let videoId else { return nil }

        let thumbs = extractThumbnails(from: data)
        let thumbURL = thumbs.last.flatMap { URL(string: $0) }
        let songTitle = extractTitleFromFlexColumns(data)
        let artists = extractArtistsFromFlexColumns(data)

        return Song(
            id: videoId,
            title: songTitle,
            artists: artists,
            album: nil,
            duration: nil,
            thumbnailURL: thumbURL,
            videoId: videoId
        )
    }

    /// Parses a song from musicTwoRowItemRenderer.
    private func parseSongFromTwoRowRenderer(_ data: [String: Any]) -> Song? {
        guard let navigationEndpoint = data["navigationEndpoint"] as? [String: Any],
              let watchEndpoint = navigationEndpoint["watchEndpoint"] as? [String: Any],
              let videoId = watchEndpoint["videoId"] as? String
        else {
            return nil
        }

        let thumbnails = extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        var title = "Unknown"
        if let titleData = data["title"] as? [String: Any],
           let runs = titleData["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            title = text
        }

        let artists = extractArtists(from: data)

        return Song(
            id: videoId,
            title: title,
            artists: artists,
            album: nil,
            duration: nil,
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )
    }

    /// Recursively finds tracks in a data structure.
    private func findTracksRecursively(in data: [String: Any], depth: Int) -> [Song] {
        guard depth < 10 else { return [] } // Prevent infinite recursion

        var tracks: [Song] = []

        // Check if this is a contents array we can parse
        if let contents = data["contents"] as? [[String: Any]] {
            tracks.append(contentsOf: parseTracksFromItems(contents))
        }

        // Recurse into nested structures
        for (key, value) in data {
            if key == "contents" { continue } // Already handled above

            if let dict = value as? [String: Any] {
                tracks.append(contentsOf: findTracksRecursively(in: dict, depth: depth + 1))
            } else if let array = value as? [[String: Any]] {
                for item in array {
                    tracks.append(contentsOf: findTracksRecursively(in: item, depth: depth + 1))
                }
            }

            if !tracks.isEmpty {
                return tracks // Found tracks, stop searching
            }
        }

        return tracks
    }

    // MARK: - Helper Methods

    private func extractThumbnails(from data: [String: Any]) -> [String] {
        if let thumbnail = data["thumbnail"] as? [String: Any] {
            if let musicThumbnailRenderer = thumbnail["musicThumbnailRenderer"] as? [String: Any],
               let thumbData = musicThumbnailRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumbData["thumbnails"] as? [[String: Any]]
            {
                return thumbnails.compactMap { $0["url"] as? String }
            }
            if let thumbnails = thumbnail["thumbnails"] as? [[String: Any]] {
                return thumbnails.compactMap { $0["url"] as? String }
            }
        }
        return []
    }

    private func extractArtists(from data: [String: Any]) -> [Artist] {
        var artists: [Artist] = []

        if let subtitleData = data["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            for run in runs {
                if let text = run["text"] as? String,
                   text != " • ", text != " & ", text != ", "
                {
                    if let endpoint = run["navigationEndpoint"] as? [String: Any],
                       let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                       let artistId = browseEndpoint["browseId"] as? String
                    {
                        artists.append(Artist(id: artistId, name: text))
                    } else if !text.isEmpty {
                        artists.append(Artist(id: UUID().uuidString, name: text))
                    }
                }
            }
        }

        return artists
    }

    private func extractSubtitle(from data: [String: Any]) -> String? {
        if let subtitleData = data["subtitle"] as? [String: Any],
           let runs = subtitleData["runs"] as? [[String: Any]]
        {
            let texts = runs.compactMap { $0["text"] as? String }
            return texts.joined()
        }
        return nil
    }

    private func extractTitleFromFlexColumns(_ data: [String: Any]) -> String {
        if let flexColumns = data["flexColumns"] as? [[String: Any]],
           let firstColumn = flexColumns.first,
           let renderer = firstColumn["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let textData = renderer["text"] as? [String: Any],
           let runs = textData["runs"] as? [[String: Any]]
        {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return "Unknown"
    }

    private func extractSubtitleFromFlexColumns(_ data: [String: Any]) -> String? {
        if let flexColumns = data["flexColumns"] as? [[String: Any]],
           flexColumns.count > 1,
           let secondColumn = flexColumns[safe: 1],
           let renderer = secondColumn["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let textData = renderer["text"] as? [String: Any],
           let runs = textData["runs"] as? [[String: Any]]
        {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    private func extractArtistsFromFlexColumns(_ data: [String: Any]) -> [Artist] {
        var artists: [Artist] = []

        if let flexColumns = data["flexColumns"] as? [[String: Any]],
           flexColumns.count > 1,
           let secondColumn = flexColumns[safe: 1],
           let renderer = secondColumn["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let textData = renderer["text"] as? [String: Any],
           let runs = textData["runs"] as? [[String: Any]]
        {
            for run in runs {
                if let text = run["text"] as? String,
                   text != " • ", text != " & ", text != ", "
                {
                    if let endpoint = run["navigationEndpoint"] as? [String: Any],
                       let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                       let artistId = browseEndpoint["browseId"] as? String
                    {
                        artists.append(Artist(id: artistId, name: text))
                    } else if !text.isEmpty {
                        artists.append(Artist(id: UUID().uuidString, name: text))
                    }
                }
            }
        }

        return artists
    }
}
