import CryptoKit
import Foundation
import os

/// Client for making authenticated requests to YouTube Music's internal API.
@MainActor
final class YTMusicClient: YTMusicClientProtocol {
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
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Public API Methods

    /// Maximum total continuations to prevent infinite loops.
    private static let maxTotalContinuations = 5

    /// Fetches the home page content (initial sections only for fast display).
    /// Call `getHomeContinuation` to load additional sections progressively.
    func getHome() async throws -> HomeResponse {
        self.logger.info("Fetching home page")

        let body: [String: Any] = [
            "browseId": "FEmusic_home",
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.home)
        let response = HomeResponseParser.parse(data)

        // Store continuation token for progressive loading
        let token = HomeResponseParser.extractContinuationToken(from: data)
        self._homeContinuationToken = token

        self.logger.info("Home page loaded: \(response.sections.count) initial sections, hasMore: \(token != nil)")
        return response
    }

    /// Internal storage for continuation token (reset on each getHome call).
    private var _homeContinuationToken: String?

    /// Fetches the next batch of home sections via continuation.
    /// Returns nil if no more sections are available.
    func getHomeContinuation() async throws -> [HomeSection]? {
        guard let token = _homeContinuationToken else {
            self.logger.debug("No home continuation token available")
            return nil
        }

        self.logger.info("Fetching home continuation")

        do {
            let continuationData = try await requestContinuation(token)
            let additionalSections = HomeResponseParser.parseContinuation(continuationData)
            self._homeContinuationToken = HomeResponseParser.extractContinuationTokenFromContinuation(continuationData)
            let hasMore = self._homeContinuationToken != nil

            self.logger.info("Home continuation loaded: \(additionalSections.count) sections, hasMore: \(hasMore)")
            return additionalSections
        } catch {
            self.logger.warning("Failed to fetch home continuation: \(error.localizedDescription)")
            self._homeContinuationToken = nil
            throw error
        }
    }

    /// Whether more home sections are available to load.
    var hasMoreHomeSections: Bool {
        self._homeContinuationToken != nil
    }

    /// Fetches the explore page content (initial sections only for fast display).
    func getExplore() async throws -> HomeResponse {
        self.logger.info("Fetching explore page")

        let body: [String: Any] = [
            "browseId": "FEmusic_explore",
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.home)
        let response = HomeResponseParser.parse(data)

        // Store continuation token for progressive loading
        let token = HomeResponseParser.extractContinuationToken(from: data)
        self._exploreContinuationToken = token

        self.logger.info("Explore page loaded: \(response.sections.count) initial sections, hasMore: \(token != nil)")
        return response
    }

    /// Internal storage for explore continuation token.
    private var _exploreContinuationToken: String?

    /// Fetches the next batch of explore sections via continuation.
    func getExploreContinuation() async throws -> [HomeSection]? {
        guard let token = _exploreContinuationToken else {
            self.logger.debug("No explore continuation token available")
            return nil
        }

        self.logger.info("Fetching explore continuation")

        do {
            let continuationData = try await requestContinuation(token)
            let additionalSections = HomeResponseParser.parseContinuation(continuationData)
            self._exploreContinuationToken = HomeResponseParser.extractContinuationTokenFromContinuation(continuationData)
            let hasMore = self._exploreContinuationToken != nil

            self.logger.info("Explore continuation loaded: \(additionalSections.count) sections, hasMore: \(hasMore)")
            return additionalSections
        } catch {
            self.logger.warning("Failed to fetch explore continuation: \(error.localizedDescription)")
            self._exploreContinuationToken = nil
            throw error
        }
    }

    /// Whether more explore sections are available to load.
    var hasMoreExploreSections: Bool {
        self._exploreContinuationToken != nil
    }

    /// Makes a continuation request.
    private func requestContinuation(_ token: String, ttl: TimeInterval? = APICache.TTL.home) async throws -> [String: Any] {
        let body: [String: Any] = [
            "continuation": token,
        ]
        return try await self.request("browse", body: body, ttl: ttl)
    }

    /// Searches for content.
    func search(query: String) async throws -> SearchResponse {
        self.logger.info("Searching for: \(query)")

        let body: [String: Any] = [
            "query": query,
        ]

        let data = try await request("search", body: body, ttl: APICache.TTL.search)
        let response = SearchResponseParser.parse(data)
        self.logger.info("Search found \(response.songs.count) songs, \(response.albums.count) albums, \(response.artists.count) artists, \(response.playlists.count) playlists")
        return response
    }

    /// Fetches search suggestions for autocomplete.
    func getSearchSuggestions(query: String) async throws -> [SearchSuggestion] {
        guard !query.isEmpty else {
            return []
        }

        self.logger.debug("Fetching search suggestions for: \(query)")

        let body: [String: Any] = [
            "input": query,
        ]

        // No caching for suggestions - they're ephemeral
        let data = try await request("music/get_search_suggestions", body: body)
        let suggestions = SearchSuggestionsParser.parse(data)
        self.logger.debug("Found \(suggestions.count) suggestions")
        return suggestions
    }

    /// Fetches the user's library playlists.
    func getLibraryPlaylists() async throws -> [Playlist] {
        self.logger.info("Fetching library playlists")

        let body: [String: Any] = [
            "browseId": "FEmusic_liked_playlists",
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.library)
        let playlists = PlaylistParser.parseLibraryPlaylists(data)
        self.logger.info("Parsed \(playlists.count) library playlists")
        return playlists
    }

    /// Fetches the user's liked songs.
    func getLikedSongs() async throws -> [Song] {
        self.logger.info("Fetching liked songs")

        let body: [String: Any] = [
            "browseId": "FEmusic_liked_videos",
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.library)
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "LM")
        self.logger.info("Parsed \(detail.tracks.count) liked songs")
        return detail.tracks
    }

    /// Fetches playlist details including tracks.
    func getPlaylist(id: String) async throws -> PlaylistDetail {
        self.logger.info("Fetching playlist: \(id)")

        // Handle different ID formats:
        // - VL... = playlist (already has prefix)
        // - PL... = playlist (needs VL prefix)
        // - RD... = radio/mix (use as-is)
        // - OLAK... = album (use as-is)
        // - MPRE... = album (use as-is)
        let browseId: String = if id.hasPrefix("VL") || id.hasPrefix("RD") || id.hasPrefix("OLAK") || id.hasPrefix("MPRE") || id.hasPrefix("UC") {
            id
        } else if id.hasPrefix("PL") {
            "VL\(id)"
        } else {
            "VL\(id)"
        }

        let body: [String: Any] = [
            "browseId": browseId,
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.playlist)

        // Log top-level keys for debugging
        let topKeys = Array(data.keys)
        self.logger.debug("Playlist response top-level keys: \(topKeys)")

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: id)
        self.logger.info("Parsed playlist '\(detail.title)' with \(detail.tracks.count) tracks")
        return detail
    }

    /// Fetches artist details including their songs and albums.
    func getArtist(id: String) async throws -> ArtistDetail {
        self.logger.info("Fetching artist: \(id)")

        let body: [String: Any] = [
            "browseId": id,
        ]

        let data = try await request("browse", body: body, ttl: APICache.TTL.artist)

        let topKeys = Array(data.keys)
        self.logger.debug("Artist response top-level keys: \(topKeys)")

        let detail = ArtistParser.parseArtistDetail(data, artistId: id)
        self.logger.info("Parsed artist '\(detail.artist.name)' with \(detail.songs.count) songs and \(detail.albums.count) albums")
        return detail
    }

    /// Fetches all songs for an artist using the songs browse endpoint.
    func getArtistSongs(browseId: String, params: String?) async throws -> [Song] {
        self.logger.info("Fetching artist songs: \(browseId)")

        var body: [String: Any] = [
            "browseId": browseId,
        ]

        if let params {
            body["params"] = params
        }

        let data = try await request("browse", body: body, ttl: APICache.TTL.artist)

        let songs = ArtistParser.parseArtistSongs(data)
        self.logger.info("Parsed \(songs.count) artist songs")
        return songs
    }

    // MARK: - Lyrics

    /// Fetches lyrics for a song by video ID.
    /// - Parameter videoId: The video ID of the song
    /// - Returns: Lyrics if available, or Lyrics.unavailable if not
    func getLyrics(videoId: String) async throws -> Lyrics {
        self.logger.info("Fetching lyrics for: \(videoId)")

        // Step 1: Get the lyrics browse ID from the "next" endpoint
        let nextBody: [String: Any] = [
            "videoId": videoId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        let nextData = try await request("next", body: nextBody)

        guard let lyricsBrowseId = extractLyricsBrowseId(from: nextData) else {
            self.logger.info("No lyrics available for: \(videoId)")
            return .unavailable
        }

        // Step 2: Fetch the actual lyrics using the browse ID
        let browseBody: [String: Any] = [
            "browseId": lyricsBrowseId,
        ]

        let browseData = try await request("browse", body: browseBody, ttl: APICache.TTL.lyrics)
        let lyrics = self.parseLyrics(from: browseData)
        self.logger.info("Fetched lyrics for \(videoId): \(lyrics.isAvailable ? "available" : "unavailable")")
        return lyrics
    }

    /// Extracts the lyrics browse ID from the "next" endpoint response.
    private func extractLyricsBrowseId(from data: [String: Any]) -> String? {
        guard let contents = data["contents"] as? [String: Any],
              let watchNextRenderer = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbedRenderer = watchNextRenderer["tabbedRenderer"] as? [String: Any],
              let watchNextTabbedResults = tabbedRenderer["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = watchNextTabbedResults["tabs"] as? [[String: Any]]
        else {
            return nil
        }

        // Find the lyrics tab (usually index 1, but search by content type to be safe)
        for tab in tabs {
            guard let tabRenderer = tab["tabRenderer"] as? [String: Any],
                  let endpoint = tabRenderer["endpoint"] as? [String: Any],
                  let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                  let browseId = browseEndpoint["browseId"] as? String,
                  browseId.hasPrefix("MPLYt")
            else {
                continue
            }
            return browseId
        }

        return nil
    }

    /// Parses lyrics from the browse endpoint response.
    private func parseLyrics(from data: [String: Any]) -> Lyrics {
        guard let contents = data["contents"] as? [String: Any],
              let sectionListRenderer = contents["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return .unavailable
        }

        for section in sectionContents {
            // Try musicDescriptionShelfRenderer (plain lyrics)
            if let shelfRenderer = section["musicDescriptionShelfRenderer"] as? [String: Any] {
                return self.parseLyricsFromShelf(shelfRenderer)
            }
        }

        return .unavailable
    }

    /// Parses lyrics from a musicDescriptionShelfRenderer.
    private func parseLyricsFromShelf(_ shelf: [String: Any]) -> Lyrics {
        // Extract the description (lyrics text)
        var lyricsText = ""
        if let description = shelf["description"] as? [String: Any],
           let runs = description["runs"] as? [[String: Any]]
        {
            lyricsText = runs.compactMap { $0["text"] as? String }.joined()
        }

        // Extract the footer (source attribution)
        var source: String?
        if let footer = shelf["footer"] as? [String: Any],
           let runs = footer["runs"] as? [[String: Any]]
        {
            source = runs.compactMap { $0["text"] as? String }.joined()
        }

        if lyricsText.isEmpty {
            return .unavailable
        }

        return Lyrics(text: lyricsText, source: source)
    }

    // MARK: - Song Metadata

    /// Fetches full song metadata including feedbackTokens for library management.
    /// Uses the `next` endpoint to get track details with library status.
    /// - Parameter videoId: The video ID of the song
    /// - Returns: A Song with full metadata including feedbackTokens and inLibrary status
    func getSong(videoId: String) async throws -> Song {
        self.logger.info("Fetching song metadata: \(videoId)")

        // Use the "next" endpoint which returns track info with feedbackTokens
        let body: [String: Any] = [
            "videoId": videoId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        let data = try await request("next", body: body, ttl: APICache.TTL.songMetadata)
        return try self.parseSongMetadata(data, videoId: videoId)
    }

    /// Parses song metadata from the "next" endpoint response.
    private func parseSongMetadata(_ data: [String: Any], videoId: String) throws -> Song {
        let panelVideoRenderer = try extractPanelVideoRenderer(from: data, videoId: videoId)

        let title = self.parseTitle(from: panelVideoRenderer)
        let artists = self.parseArtists(from: panelVideoRenderer)
        let thumbnailURL = self.parseThumbnail(from: panelVideoRenderer)
        let duration = self.parseDuration(from: panelVideoRenderer)
        let menuData = self.parseMenuData(from: panelVideoRenderer)

        self.logger.info("Parsed song '\(title)' - inLibrary: \(menuData.isInLibrary), hasTokens: \(menuData.feedbackTokens != nil)")

        return Song(
            id: videoId,
            title: title,
            artists: artists,
            album: nil,
            duration: duration,
            thumbnailURL: thumbnailURL,
            videoId: videoId,
            likeStatus: menuData.likeStatus,
            isInLibrary: menuData.isInLibrary,
            feedbackTokens: menuData.feedbackTokens
        )
    }

    // MARK: - Song Metadata Parsing Helpers

    /// Extracts the playlistPanelVideoRenderer from the next endpoint response.
    private func extractPanelVideoRenderer(from data: [String: Any], videoId: String) throws -> [String: Any] {
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
              let firstItem = playlistContents.first,
              let panelVideoRenderer = firstItem["playlistPanelVideoRenderer"] as? [String: Any]
        else {
            self.logger.warning("Could not parse song metadata structure for \(videoId)")
            throw YTMusicError.parseError(message: "Failed to parse song metadata")
        }
        return panelVideoRenderer
    }

    /// Parses the song title from the panel video renderer.
    private func parseTitle(from renderer: [String: Any]) -> String {
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
    private func parseArtists(from renderer: [String: Any]) -> [Artist] {
        var artists: [Artist] = []
        guard let bylineData = renderer["longBylineText"] as? [String: Any],
              let runs = bylineData["runs"] as? [[String: Any]]
        else { return artists }

        for run in runs {
            guard let text = run["text"] as? String,
                  text != " • ", text != " & ", text != ", ", text != " · "
            else { continue }

            let artistId: String = if let navEndpoint = run["navigationEndpoint"] as? [String: Any],
                                      let browseEndpoint = navEndpoint["browseEndpoint"] as? [String: Any],
                                      let browseId = browseEndpoint["browseId"] as? String
            {
                browseId
            } else {
                UUID().uuidString
            }
            artists.append(Artist(id: artistId, name: text))
        }
        return artists
    }

    /// Parses the thumbnail URL from the panel video renderer.
    private func parseThumbnail(from renderer: [String: Any]) -> URL? {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]],
              let lastThumb = thumbnails.last,
              let urlString = lastThumb["url"] as? String
        else { return nil }

        let normalizedURL = urlString.hasPrefix("//") ? "https:" + urlString : urlString
        return URL(string: normalizedURL)
    }

    /// Parses the duration from the panel video renderer.
    private func parseDuration(from renderer: [String: Any]) -> TimeInterval? {
        guard let lengthText = renderer["lengthText"] as? [String: Any],
              let runs = lengthText["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let text = firstRun["text"] as? String
        else { return nil }

        return ParsingHelpers.parseDuration(text)
    }

    /// Contains parsed menu data including feedback tokens, library status, and like status.
    private struct MenuParseResult {
        var feedbackTokens: FeedbackTokens?
        var isInLibrary: Bool
        var likeStatus: LikeStatus
    }

    /// Parses menu data (feedbackTokens, library status, like status) from the panel video renderer.
    private func parseMenuData(from renderer: [String: Any]) -> MenuParseResult {
        var result = MenuParseResult(feedbackTokens: nil, isInLibrary: false, likeStatus: .indifferent)

        guard let menu = renderer["menu"] as? [String: Any],
              let menuRenderer = menu["menuRenderer"] as? [String: Any],
              let items = menuRenderer["items"] as? [[String: Any]]
        else { return result }

        for item in items {
            self.parseMenuServiceItem(item, into: &result)
            self.parseToggleMenuItem(item, into: &result)
        }

        self.parseLikeStatus(from: menuRenderer, into: &result)
        return result
    }

    /// Parses a menuServiceItemRenderer for library tokens.
    private func parseMenuServiceItem(_ item: [String: Any], into result: inout MenuParseResult) {
        guard let menuServiceItem = item["menuServiceItemRenderer"] as? [String: Any],
              let icon = menuServiceItem["icon"] as? [String: Any],
              let iconType = icon["iconType"] as? String
        else { return }

        let token = self.extractFeedbackToken(from: menuServiceItem, key: "serviceEndpoint")

        switch iconType {
        case "LIBRARY_ADD", "BOOKMARK_BORDER":
            if let token { result.feedbackTokens = FeedbackTokens(add: token, remove: nil) }
        case "LIBRARY_REMOVE", "BOOKMARK":
            result.isInLibrary = true
            if let token { result.feedbackTokens = FeedbackTokens(add: nil, remove: token) }
        default:
            break
        }
    }

    /// Parses a toggleMenuServiceItemRenderer for library tokens.
    private func parseToggleMenuItem(_ item: [String: Any], into result: inout MenuParseResult) {
        guard let toggleItem = item["toggleMenuServiceItemRenderer"] as? [String: Any],
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
    private func extractFeedbackToken(from dict: [String: Any], key: String) -> String? {
        guard let endpoint = dict[key] as? [String: Any],
              let feedback = endpoint["feedbackEndpoint"] as? [String: Any]
        else { return nil }
        return feedback["feedbackToken"] as? String
    }

    /// Parses the like status from the menu renderer's top level buttons.
    private func parseLikeStatus(from menuRenderer: [String: Any], into result: inout MenuParseResult) {
        guard let topLevelButtons = menuRenderer["topLevelButtons"] as? [[String: Any]] else { return }

        for button in topLevelButtons {
            if let likeButtonRenderer = button["likeButtonRenderer"] as? [String: Any],
               let status = likeButtonRenderer["likeStatus"] as? String
            {
                result.likeStatus = switch status {
                case "LIKE": .like
                case "DISLIKE": .dislike
                default: .indifferent
                }
            }
        }
    }

    // MARK: - Like/Library Actions

    /// Rates a song (like/dislike/indifferent).
    /// - Parameters:
    ///   - videoId: The video ID of the song to rate
    ///   - rating: The rating to apply (like, dislike, or indifferent to remove rating)
    func rateSong(videoId: String, rating: LikeStatus) async throws {
        self.logger.info("Rating song \(videoId) with \(rating.rawValue)")

        let body: [String: Any] = [
            "target": ["videoId": videoId],
        ]

        // Endpoint varies by rating type
        let endpoint = switch rating {
        case .like:
            "like/like"
        case .dislike:
            "like/dislike"
        case .indifferent:
            "like/removelike"
        }

        _ = try await self.request(endpoint, body: body)
        self.logger.info("Successfully rated song \(videoId)")

        // Invalidate liked playlist cache so UI updates immediately
        APICache.shared.invalidate(matching: "browse:")
        // Invalidate song metadata cache (next: endpoint)
        APICache.shared.invalidate(matching: "next:")
    }

    /// Adds or removes a song from the user's library.
    /// - Parameter feedbackTokens: Tokens obtained from song metadata (use add token to add, remove token to remove)
    func editSongLibraryStatus(feedbackTokens: [String]) async throws {
        guard !feedbackTokens.isEmpty else {
            self.logger.warning("No feedback tokens provided for library edit")
            return
        }

        self.logger.info("Editing song library status with \(feedbackTokens.count) tokens")

        let body: [String: Any] = [
            "feedbackTokens": feedbackTokens,
        ]

        _ = try await self.request("feedback", body: body)
        self.logger.info("Successfully edited library status")

        // Invalidate library and song metadata cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
        APICache.shared.invalidate(matching: "next:")
    }

    /// Adds a playlist to the user's library using the like/like endpoint.
    /// This is equivalent to the "Add to Library" action in YouTube Music.
    /// - Parameter playlistId: The playlist ID to add to library
    func subscribeToPlaylist(playlistId: String) async throws {
        self.logger.info("Adding playlist to library: \(playlistId)")

        // Remove VL prefix if present for the API call
        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId

        let body: [String: Any] = [
            "target": ["playlistId": cleanId],
        ]

        _ = try await self.request("like/like", body: body)
        self.logger.info("Successfully added playlist \(playlistId) to library")

        // Invalidate library cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
    }

    /// Removes a playlist from the user's library using the like/removelike endpoint.
    /// This is equivalent to the "Remove from Library" action in YouTube Music.
    /// - Parameter playlistId: The playlist ID to remove from library
    func unsubscribeFromPlaylist(playlistId: String) async throws {
        self.logger.info("Removing playlist from library: \(playlistId)")

        // Remove VL prefix if present for the API call
        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId

        let body: [String: Any] = [
            "target": ["playlistId": cleanId],
        ]

        _ = try await self.request("like/removelike", body: body)
        self.logger.info("Successfully removed playlist \(playlistId) from library")

        // Invalidate library cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
    }

    /// Subscribes to an artist by channel ID.
    /// This is equivalent to the "Subscribe" action in YouTube Music.
    /// - Parameter channelId: The channel ID of the artist (e.g., UCxxxxx)
    func subscribeToArtist(channelId: String) async throws {
        self.logger.info("Subscribing to artist: \(channelId)")

        let body: [String: Any] = [
            "channelIds": [channelId],
        ]

        _ = try await self.request("subscription/subscribe", body: body)
        self.logger.info("Successfully subscribed to artist \(channelId)")

        // Invalidate artist cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
    }

    /// Unsubscribes from an artist by channel ID.
    /// This is equivalent to the "Unsubscribe" action in YouTube Music.
    /// - Parameter channelId: The channel ID of the artist (e.g., UCxxxxx)
    func unsubscribeFromArtist(channelId: String) async throws {
        self.logger.info("Unsubscribing from artist: \(channelId)")

        let body: [String: Any] = [
            "channelIds": [channelId],
        ]

        _ = try await self.request("subscription/unsubscribe", body: body)
        self.logger.info("Successfully unsubscribed from artist \(channelId)")

        // Invalidate artist cache so UI updates
        APICache.shared.invalidate(matching: "browse:")
    }

    // MARK: - Private Methods

    /// Builds authentication headers for API requests.
    private func buildAuthHeaders() async throws -> [String: String] {
        // Log available cookies for debugging auth issues
        let allCookies = await webKitManager.getAllCookies()
        let youtubeCookies = await webKitManager.getCookies(for: "youtube.com")
        self.logger.debug("Building auth headers - total cookies: \(allCookies.count), youtube.com cookies: \(youtubeCookies.count)")

        guard let cookieHeader = await webKitManager.cookieHeader(for: "youtube.com") else {
            self.logger.error("No cookies found for youtube.com domain")
            throw YTMusicError.notAuthenticated
        }

        guard let sapisid = await webKitManager.getSAPISID() else {
            self.logger.error("SAPISID cookie not found or expired")
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

    /// Makes an authenticated request to the API with optional caching and retry.
    private func request(_ endpoint: String, body: [String: Any], ttl: TimeInterval? = nil) async throws -> [String: Any] {
        // Generate stable cache key from endpoint and body
        let cacheKey = APICache.stableCacheKey(endpoint: endpoint, body: body)

        // Check cache first
        if ttl != nil, let cached = APICache.shared.get(key: cacheKey) {
            self.logger.debug("Cache hit for \(endpoint)")
            return cached
        }

        // Execute with retry policy
        let json = try await RetryPolicy.default.execute { [self] in
            try await self.performRequest(endpoint, body: body)
        }

        // Cache response if TTL specified
        if let ttl {
            APICache.shared.set(key: cacheKey, data: json, ttl: ttl)
        }

        return json
    }

    /// Performs the actual network request.
    private func performRequest(_ endpoint: String, body: [String: Any]) async throws -> [String: Any] {
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
        fullBody["context"] = self.buildContext()

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        self.logger.debug("Making request to \(endpoint)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YTMusicError.networkError(underlying: URLError(.badServerResponse))
        }

        // Handle auth errors
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            self.logger.error("Auth error: HTTP \(httpResponse.statusCode)")
            self.authService.sessionExpired()
            throw YTMusicError.authExpired
        }

        // Handle other errors
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            self.logger.error("API error: HTTP \(httpResponse.statusCode)")
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
}
