import Foundation
import os

// MARK: - YouTubeClient

/// Client for making authenticated requests to regular YouTube's internal
/// InnerTube API (`www.youtube.com/youtubei/v1`, `WEB` client).
///
/// Parallel to `YTMusicClient` by design: the request scaffolding is
/// intentionally duplicated rather than shared so the proven music path
/// stays untouched. The critical difference is the origin — SAPISIDHASH
/// and the `Origin`/`Referer`/`X-Origin` headers must all use
/// `https://www.youtube.com`, not the music origin.
///
/// Unlike the music client, no API key is attached: the `key=` query
/// parameter is no longer required by InnerTube (confirmed June 2026).
@MainActor
final class YouTubeClient: YouTubeClientProtocol {
    private let authService: AuthService
    private let webKitManager: WebKitManager
    private let session: URLSession
    private let logger = DiagnosticsLogger.api

    /// Provider for the current brand account ID (mirrors `YTMusicClient`).
    var brandIdProvider: (() -> String?)?

    /// Provider for the current account identity used only to scope cache keys.
    ///
    /// `brandIdProvider` is nil for primary accounts, so personalized YouTube
    /// caches also need the selected account identity to avoid reusing primary
    /// account responses across sign-in/account changes.
    var accountCacheIdentityProvider: (() -> String?)?

    /// YouTube API base URL.
    private static let baseURL = "https://www.youtube.com/youtubei/v1"

    /// Request origin — also the SAPISIDHASH input origin.
    static let origin = "https://www.youtube.com"

    /// Client version for WEB (live value observed June 2026; InnerTube
    /// accepts moderately stale versions).
    private static let clientVersion = "2.20260611.01.00"

    /// Cache-key prefix so YouTube entries never collide with music
    /// invalidation patterns ("browse:", "next:", …).
    private static let cachePrefix = "yt:"

    private var homeContinuation: String?
    private var searchContinuation: String?

    var hasMoreHomeFeed: Bool {
        self.homeContinuation != nil
    }

    init(
        authService: AuthService,
        webKitManager: WebKitManager = .shared,
        session: URLSession? = nil
    ) {
        self.authService = authService
        self.webKitManager = webKitManager

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "Accept-Encoding": "gzip, deflate, br",
            ]
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.urlCache = URLCache.shared
            configuration.requestCachePolicy = .useProtocolCachePolicy
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Home Feed

    func getHomeFeed() async throws -> YouTubeFeed {
        self.logger.info("Fetching YouTube home feed")

        let data = try await self.request(
            "browse",
            body: ["browseId": "FEwhat_to_watch"],
            ttl: APICache.TTL.home
        )
        let feed = YouTubeFeedParser.parse(data)
        self.homeContinuation = feed.continuation
        self.logger.info("YouTube home feed loaded: \(feed.videos.count) videos, hasMore: \(feed.continuation != nil)")
        return feed
    }

    func getHomeFeedContinuation() async throws -> YouTubeFeed? {
        guard let continuation = self.homeContinuation else {
            return nil
        }

        let data = try await self.request("browse", body: ["continuation": continuation])
        let feed = YouTubeFeedParser.parseContinuation(data)
        self.homeContinuation = feed.continuation
        self.logger.info("YouTube home continuation: \(feed.videos.count) videos")
        return feed
    }

    func getHomeChips() async throws -> [YouTubeHomeChip] {
        // Chips ride along in the home feed response; the shared TTL means this
        // is a cache hit right after the home grid loads (cf. getShorts()).
        let data = try await self.request(
            "browse",
            body: ["browseId": "FEwhat_to_watch"],
            ttl: APICache.TTL.home
        )
        let chips = YouTubeFeedParser.parseChips(data)
        self.logger.info("YouTube home chips: \(chips.count) topics")
        return chips
    }

    func getHomeShelves() async throws -> [YouTubeHomeSection] {
        // Same cached home response; extracts the response's own titled shelves.
        let data = try await self.request(
            "browse",
            body: ["browseId": "FEwhat_to_watch"],
            ttl: APICache.TTL.home
        )
        let shelves = YouTubeFeedParser.parseHomeShelves(data)
        self.logger.info("YouTube home shelves: \(shelves.count)")
        return shelves
    }

    func getHomeTopicFeed(continuation: String) async throws -> YouTubeFeed {
        // A chip browse uses the same `browse` continuation wire shape as
        // pagination, but returns a fresh topic-filtered grid (reload
        // semantics) with its own trailing continuation token.
        let data = try await self.request("browse", body: ["continuation": continuation])
        return YouTubeFeedParser.parseContinuation(data)
    }

    // MARK: - Search

    func search(query: String, filter: YouTubeSearchFilter) async throws -> YouTubeSearchResponse {
        self.logger.info("Searching YouTube (filter: \(filter.rawValue))")

        var body: [String: Any] = ["query": query]
        if let params = filter.params {
            body["params"] = params
        }

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        var response = YouTubeSearchParser.parse(data)
        self.searchContinuation = response.continuation
        response.continuation = self.searchContinuation
        self.logger.info(
            "YouTube search: \(response.videos.count) videos, \(response.channels.count) channels, \(response.playlists.count) playlists"
        )
        return response
    }

    func getSearchContinuation() async throws -> YouTubeSearchResponse? {
        guard let continuation = self.searchContinuation else {
            return nil
        }

        let data = try await self.request("search", body: ["continuation": continuation])
        let response = YouTubeSearchParser.parseContinuation(data)
        self.searchContinuation = response.continuation
        return response
    }

    // MARK: - Watch

    func getWatchNext(videoId: String) async throws -> WatchNextData {
        self.logger.info("Fetching watch-next data")

        let data = try await self.request("next", body: ["videoId": videoId])
        return WatchNextParser.parse(data)
    }

    func getComments(continuation: String) async throws -> YouTubeCommentsPage {
        self.logger.info("Fetching YouTube comments page")

        let data = try await self.request("next", body: ["continuation": continuation])
        return YouTubeCommentsParser.parse(data)
    }

    func postComment(text: String, createCommentParams: String) async throws {
        self.logger.info("Posting YouTube comment")

        let body: [String: Any] = [
            "commentText": text,
            "createCommentParams": createCommentParams,
        ]
        _ = try await self.request("comment/create_comment", body: body, retry: false)
    }

    func performCommentAction(_ action: String) async throws {
        self.logger.info("Performing comment action")

        let body: [String: Any] = ["actions": [action]]
        _ = try await self.request("comment/perform_comment_action", body: body, retry: false)
    }

    // MARK: - Browse

    func getChannel(channelId: String) async throws -> YouTubeChannelDetail {
        self.logger.info("Fetching YouTube channel page")

        let data = try await self.request(
            "browse",
            body: ["browseId": channelId],
            ttl: APICache.TTL.artist
        )
        guard let detail = ChannelPageParser.parse(data, channelId: channelId) else {
            throw YTMusicError.parseError(message: "Could not parse channel page")
        }
        return detail
    }

    func getPlaylist(playlistId: String) async throws -> YouTubePlaylistDetail {
        self.logger.info("Fetching YouTube playlist page")

        let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL\(playlistId)"
        let data = try await self.request(
            "browse",
            body: ["browseId": browseId],
            ttl: APICache.TTL.playlist
        )
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        return YouTubePlaylistPageParser.parse(data, playlistId: id)
    }

    func getDestinationFeed(_ destination: YouTubeDestination) async throws -> YouTubeFeed {
        self.logger.info("Fetching YouTube destination feed: \(destination.rawValue)")

        let data = try await self.request(
            "browse",
            body: ["browseId": destination.browseId],
            ttl: APICache.TTL.home
        )
        return YouTubeFeedParser.parse(data)
    }

    func getFeedContinuation(continuation: String) async throws -> YouTubeFeed {
        let data = try await self.request("browse", body: ["continuation": continuation])
        return YouTubeFeedParser.parseContinuation(data)
    }

    func getShorts() async throws -> [YouTubeVideo] {
        self.logger.info("Fetching YouTube Shorts")

        // Shorts ride along in the home feed response; the shared TTL means
        // this is a cache hit right after the home grid loads.
        let data = try await self.request(
            "browse",
            body: ["browseId": "FEwhat_to_watch"],
            ttl: APICache.TTL.home
        )
        return YouTubeFeedParser.parse(data).shorts
    }

    // MARK: - Subscriptions & Library

    func getSubscriptionsFeed() async throws -> YouTubeFeed {
        self.logger.info("Fetching YouTube subscriptions feed")

        let data = try await self.request(
            "browse",
            body: ["browseId": "FEsubscriptions"],
            ttl: APICache.TTL.home
        )
        return YouTubeFeedParser.parse(data)
    }

    func getSubscribedChannels() async throws -> [YouTubeChannel] {
        self.logger.info("Fetching subscribed channels via guide")

        let data = try await self.request("guide", body: [:], ttl: APICache.TTL.library)
        return GuideParser.subscribedChannels(data)
    }

    func getHistory() async throws -> YouTubeFeed {
        self.logger.info("Fetching YouTube watch history")

        let data = try await self.request(
            "browse",
            body: ["browseId": "FEhistory"],
            ttl: APICache.TTL.search
        )
        return YouTubeFeedParser.parse(data)
    }

    func getUserPlaylists() async throws -> [YouTubePlaylist] {
        self.logger.info("Fetching YouTube user playlists")

        let data = try await self.request(
            "browse",
            body: ["browseId": "FEplaylist_aggregation"],
            ttl: APICache.TTL.library
        )
        return YouTubeFeedParser.collectPlaylists(data)
    }

    // MARK: - Actions

    func rateVideo(videoId: String, rating: YouTubeRating) async throws {
        self.logger.info("Rating YouTube video")

        let body: [String: Any] = ["target": ["videoId": videoId]]
        _ = try await self.request(rating.endpoint, body: body, retry: false)
        APICache.shared.invalidate(matching: Self.cachePrefix)
    }

    func setSubscribed(_ subscribed: Bool, channelId: String) async throws {
        self.logger.info("\(subscribed ? "Subscribing to" : "Unsubscribing from") channel")

        let endpoint = subscribed ? "subscription/subscribe" : "subscription/unsubscribe"
        let body: [String: Any] = ["channelIds": [channelId]]
        _ = try await self.request(endpoint, body: body, retry: false)
        APICache.shared.invalidate(matching: Self.cachePrefix)
    }

    func addToWatchLater(videoId: String) async throws {
        try await self.editWatchLater(actions: [
            ["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"],
        ])
    }

    func removeFromWatchLater(videoId: String) async throws {
        try await self.editWatchLater(actions: [
            ["removedVideoId": videoId, "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID"],
        ])
    }

    private func editWatchLater(actions: [[String: Any]]) async throws {
        self.logger.info("Editing Watch Later")

        let body: [String: Any] = [
            "playlistId": "WL",
            "actions": actions,
        ]
        _ = try await self.request("browse/edit_playlist", body: body, retry: false)
        APICache.shared.invalidate(matching: Self.cachePrefix)
    }

    // MARK: - Request Core

    /// Builds authentication headers with the YouTube (not music) origin.
    private func buildAuthHeaders() async throws -> [String: String] {
        guard let cookieHeader = await webKitManager.cookieHeader(for: "youtube.com") else {
            self.logger.error("No cookies found for youtube.com domain")
            throw YTMusicError.notAuthenticated
        }

        guard let sapisid = await webKitManager.getSAPISID() else {
            self.logger.error("SAPISID cookie not found or expired")
            throw YTMusicError.authExpired
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let sapisidhash = InnerTubeSupport.sapisidHash(
            sapisid: sapisid,
            origin: Self.origin,
            timestamp: timestamp
        )

        return [
            "Cookie": cookieHeader,
            "Authorization": "SAPISIDHASH \(sapisidhash)",
            "Origin": Self.origin,
            "Referer": Self.origin,
            "Content-Type": "application/json",
            // Kaset's account model is primary + brand accounts: selection is
            // expressed via context.user.onBehalfOfUser (brandIdProvider), not
            // the authuser index — same contract as YTMusicClient.
            "X-Goog-AuthUser": "0",
            "X-Origin": Self.origin,
        ]
    }

    /// Builds the standard `WEB` client context payload.
    private func buildContext() -> [String: Any] {
        var userDict: [String: Any] = [
            "lockedSafetyMode": false,
        ]

        if let brandId = self.brandIdProvider?() {
            userDict["onBehalfOfUser"] = brandId
        }

        return [
            "client": [
                "clientName": "WEB",
                "clientVersion": Self.clientVersion,
                "hl": SettingsManager.shared.contentLanguage.apiLanguageCode,
                "gl": "US",
                "browserName": "Safari",
                "browserVersion": "17.0",
                "osName": "Macintosh",
                "osVersion": "10_15_7",
                "platform": "DESKTOP",
                "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
            ],
            "user": userDict,
        ]
    }

    /// Makes an authenticated request with optional caching and retry.
    private func request(
        _ endpoint: String,
        body: [String: Any],
        ttl: TimeInterval? = nil,
        retry: Bool = true
    ) async throws -> [String: Any] {
        var fullBody = body
        fullBody["context"] = self.buildContext()

        let brandId = self.brandIdProvider?() ?? ""
        let accountScope = self.accountCacheIdentityProvider?()
        let cacheKey: String? = if ttl != nil, let accountScope, !accountScope.isEmpty {
            APICache.stableCacheKey(
                endpoint: Self.cachePrefix + endpoint,
                body: fullBody,
                brandId: Self.cacheScope(accountIdentity: accountScope, brandId: brandId)
            )
        } else {
            nil
        }

        // Validate the current auth session before returning any cached
        // personalized YouTube response. If the account identity is not loaded
        // yet, skip caching rather than falling back to a generic primary scope.
        if let cacheKey {
            _ = try await self.buildAuthHeaders()
            if let cached = APICache.shared.get(key: cacheKey) {
                self.logger.debug("Cache hit for \(Self.cachePrefix)\(endpoint)")
                return cached
            }
        }

        let json: [String: Any] = if retry {
            try await RetryPolicy.default.execute { [self] in
                try await self.performRequest(endpoint, fullBody: fullBody)
            }
        } else {
            try await self.performRequest(endpoint, fullBody: fullBody)
        }

        if let ttl, let cacheKey {
            APICache.shared.set(key: cacheKey, data: json, ttl: ttl)
        }

        return json
    }

    private static func cacheScope(accountIdentity: String, brandId: String) -> String {
        let brand = brandId.isEmpty ? "primary" : brandId
        return "account=\(accountIdentity);brand=\(brand)"
    }

    /// Performs the actual network request.
    private func performRequest(
        _ endpoint: String,
        fullBody: [String: Any]
    ) async throws -> [String: Any] {
        var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)")
        components?.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else {
            throw YTMusicError.unknown(message: "Invalid API URL for endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let headers = try await self.buildAuthHeaders()
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        self.logger.debug("Making YouTube request to \(endpoint)")

        let result = try await Self.performNetworkRequest(request: request, session: self.session)

        switch result {
        case let .success(data):
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw YTMusicError.parseError(message: "Response is not a JSON object")
            }
            return json
        case let .authError(statusCode):
            self.logger.error("YouTube auth error: HTTP \(statusCode)")
            self.authService.sessionExpired()
            throw YTMusicError.authExpired
        case let .httpError(statusCode):
            self.logger.error("YouTube API error: HTTP \(statusCode)")
            throw YTMusicError.apiError(message: "HTTP \(statusCode)", code: statusCode)
        case let .networkError(error):
            throw YTMusicError.networkError(underlying: error)
        }
    }

    // MARK: - Nonisolated Network Helper

    /// Result type for network requests to avoid throwing across actor boundaries.
    private enum NetworkResult {
        case success(Data)
        case authError(statusCode: Int)
        case httpError(statusCode: Int)
        case networkError(Error)
    }

    // Performs network request off the main thread.
    // swiftformat:disable:next modifierOrder
    nonisolated private static func performNetworkRequest(
        request: URLRequest,
        session: URLSession
    ) async throws -> NetworkResult {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError(URLError(.badServerResponse))
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .authError(statusCode: httpResponse.statusCode)
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                return .httpError(statusCode: httpResponse.statusCode)
            }

            return .success(data)
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return .networkError(error)
        }
    }
}
