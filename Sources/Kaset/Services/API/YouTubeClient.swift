// swiftlint:disable file_length
import Foundation
import os
import YouTubeAskCore

@MainActor
final class YouTubeClient: YouTubeClientProtocol { // swiftlint:disable:this type_body_length
    private let authService: AuthService
    private let webKitManager: WebKitManager
    private let session: URLSession
    private let cache: APICache
    let askTransport: YouTubeAskTransport
    let askMessageIDGenerator: YouTubeAskMessageIDGenerator
    private let askRequestProfile: YouTubeAskRequestProfile?
    private let logger = DiagnosticsLogger.api

    var brandIdProvider: (() -> String?)?

    var accountCacheIdentityProvider: (() -> String?)?

    var askAccountBindingProvider: (() -> YouTubeAskAccountBinding?)?

    private static let baseURL = "https://www.youtube.com/youtubei/v1"

    static let origin = "https://www.youtube.com"

    private static let clientVersion = YouTubeAskRequestProfile.productionClientVersion

    private static let cachePrefix = "yt:"

    private var homeContinuation: String?
    private var homePaginationEpoch: UInt64 = 0
    private var searchContinuation: String?
    private var askSessionGeneration: UInt64 = 0
    private var consumedAskBootstraps: Set<UUID> = []
    private var consumedAskRevisions: Set<AskRevisionKey> = []

    var hasMoreHomeFeed: Bool {
        self.homeContinuation != nil
    }

    func resetSessionStateForAccountSwitch() {
        self.homePaginationEpoch &+= 1
        self.homeContinuation = nil
        self.searchContinuation = nil
        self.askSessionGeneration &+= 1
        self.consumedAskBootstraps = []
        self.consumedAskRevisions = []
    }

    init(
        authService: AuthService,
        webKitManager: WebKitManager = .shared,
        session: URLSession? = nil,
        askMessageIDGenerator: YouTubeAskMessageIDGenerator? = nil,
        askFeatureEnabled: Bool = false,
        cache: APICache = .shared
    ) {
        self.authService = authService
        self.webKitManager = webKitManager

        let resolvedSession: URLSession = if let session {
            session
        } else {
            URLSession(configuration: APISessionConfiguration.make())
        }
        self.session = resolvedSession
        self.cache = cache
        self.askTransport = YouTubeAskTransport(configuration: resolvedSession.configuration)
        self.askMessageIDGenerator = askMessageIDGenerator ?? YouTubeAskMessageIDGenerator()
        self.askRequestProfile = askFeatureEnabled ? .fixedProduction : nil
    }

    func getHomeFeed() async throws -> YouTubeFeed {
        self.logger.info("Fetching YouTube home feed")
        self.homePaginationEpoch &+= 1
        let paginationEpoch = self.homePaginationEpoch
        self.homeContinuation = nil

        let data = try await self.request(
            "browse",
            body: ["browseId": "FEwhat_to_watch"],
            ttl: APICache.TTL.home
        )
        let feed = YouTubeFeedParser.parse(data)
        if paginationEpoch == self.homePaginationEpoch {
            self.homeContinuation = feed.continuation
        }
        self.logger.info("YouTube home feed loaded: \(feed.videos.count) videos, hasMore: \(feed.continuation != nil)")
        return feed
    }

    func getHomeBundle(forceRefresh: Bool) async throws -> YouTubeHomeBundle {
        self.logger.info("Fetching YouTube home bundle (feed + chips + shelves)")
        self.homePaginationEpoch &+= 1
        let paginationEpoch = self.homePaginationEpoch
        self.homeContinuation = nil

        let bundle = try await self.homeBundle(forceRefresh: forceRefresh)
        try Task.checkCancellation()
        if paginationEpoch == self.homePaginationEpoch {
            self.homeContinuation = bundle.feed.continuation
        }
        self.logger.info(
            "YouTube home bundle: \(bundle.feed.videos.count) videos, \(bundle.chips.count) chips, \(bundle.shelves.count) shelves"
        )
        return bundle
    }

    private func homeBundle(forceRefresh: Bool) async throws -> YouTubeHomeBundle {
        let homeBody: [String: Any] = ["browseId": "FEwhat_to_watch"]
        let cacheGeneration = self.cache.generation
        let cacheWriteTicket = self.cache.prepareWrite(cacheGeneration: cacheGeneration)
        defer {
            if let cacheWriteTicket {
                self.cache.finishWrite(cacheWriteTicket)
            }
        }
        let homeAuth = try await self.buildRequestHeaders(authPolicy: .optional)
        let cacheKey = self.homeDataCacheKey(body: homeBody, authenticated: homeAuth.authenticated)

        if !forceRefresh, let cacheKey, let cached = self.cachedHomeData(key: cacheKey) {
            let bundle = try await Self.parseHomeBundle(from: cached)
            try self.validateAuthIdentity(
                authenticated: homeAuth.authenticated,
                generation: homeAuth.authIdentityGeneration
            )
            return bundle
        }

        let cacheWrite = cacheKey.flatMap { key in
            cacheWriteTicket.flatMap { self.cache.beginWrite(for: key, ticket: $0) }
        }

        let data = try await self.requestData("browse", body: homeBody, requestAuth: homeAuth)
        let bundle = try await Self.parseHomeBundle(from: data)
        try self.validateAuthIdentity(
            authenticated: homeAuth.authenticated,
            generation: homeAuth.authIdentityGeneration
        )
        try Task.checkCancellation()

        if let cacheKey,
           cacheKey == self.homeDataCacheKey(body: homeBody, authenticated: homeAuth.authenticated),
           let cacheWrite
        {
            self.cache.setDataIfCurrent(
                key: cacheKey,
                data: data,
                ttl: APICache.TTL.home,
                reservation: cacheWrite
            )
        }
        return bundle
    }

    private static func parseHomeBundle(from data: Data) async throws -> YouTubeHomeBundle {
        try await Task.detached(priority: .userInitiated) {
            try YouTubeFeedParser.parseHomeBundle(from: data)
        }.value
    }

    func getHomeFeedContinuation() async throws -> YouTubeFeed? {
        guard let continuation = self.homeContinuation else {
            return nil
        }
        let paginationEpoch = self.homePaginationEpoch

        let data = try await self.request("browse", body: ["continuation": continuation])
        let feed = YouTubeFeedParser.parseContinuation(data)
        guard paginationEpoch == self.homePaginationEpoch else {
            self.logger.info("Discarding stale YouTube home continuation after feed reload")
            return nil
        }
        self.homeContinuation = feed.continuation
        self.logger.info("YouTube home continuation: \(feed.videos.count) videos")
        return feed
    }

    func getHomeChips() async throws -> [YouTubeHomeChip] {
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
        let data = try await self.request(
            "browse",
            body: ["browseId": "FEwhat_to_watch"],
            ttl: APICache.TTL.home
        )
        let shelves = YouTubeFeedParser.parseHomeShelves(data)
        self.logger.info("YouTube home shelves: \(shelves.count)")
        return shelves
    }

    func getHomeTopicFeed(continuation: String, forceRefresh: Bool) async throws -> YouTubeFeed {
        let data = try await self.request(
            "browse",
            body: ["continuation": continuation],
            ttl: APICache.TTL.home,
            bypassCache: forceRefresh
        )
        return YouTubeFeedParser.parseContinuation(data)
    }

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

        let response = try await self.getSearchContinuation(continuation: continuation)
        if self.searchContinuation == continuation {
            self.searchContinuation = response?.continuation
        }
        return response
    }

    func getSearchContinuation(continuation: String) async throws -> YouTubeSearchResponse? {
        let data = try await self.request("search", body: ["continuation": continuation])
        return YouTubeSearchParser.parseContinuation(data)
    }

    func getWatchNext(videoId: String) async throws -> WatchNextData {
        self.logger.info("Fetching watch-next data")

        let data = try await self.request("next", body: ["videoId": videoId])
        return WatchNextParser.parse(data)
    }

    func getWatchPage(videoId: String) async throws -> YouTubeWatchPage {
        self.logger.info("Fetching YouTube watch page")

        let accountBinding = self.currentAskAccountBinding()
        let askGeneration = self.askSessionGeneration
        let requestAuth = try await self.buildRequestHeaders(authPolicy: .optional)
        let data = try await self.requestData(
            "next",
            body: ["videoId": videoId],
            requestAuth: requestAuth
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMusicError.parseError(message: "Watch response is not a JSON object")
        }

        let watchData = WatchNextParser.parse(json)
        guard requestAuth.authenticated,
              let authenticationGeneration = requestAuth.authIdentityGeneration,
              let accountBinding,
              askGeneration == self.askSessionGeneration,
              accountBinding == self.currentAskAccountBinding()
        else {
            return YouTubeWatchPage(data: watchData, askBootstrap: nil)
        }

        let parsedBootstrap: YouTubeAskParsedBootstrap?
        do {
            parsedBootstrap = try await Task.detached(priority: .userInitiated) {
                let envelope = try YouTubeAskWireDecoder.decode(data)
                return try YouTubeAskParser.parseBootstrap(from: envelope)
            }.value
            try self.validateAskIdentity(
                authenticationGeneration: authenticationGeneration,
                accountBinding: accountBinding,
                clientGeneration: askGeneration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.logger.warning("Ask bootstrap rejected by strict parser")
            return YouTubeWatchPage(data: watchData, askBootstrap: nil)
        }

        guard let parsedBootstrap else {
            return YouTubeWatchPage(data: watchData, askBootstrap: nil)
        }
        let bootstrap = YouTubeAskBootstrap.production(
            videoID: videoId,
            parsed: parsedBootstrap,
            authenticationGeneration: authenticationGeneration,
            accountBinding: accountBinding,
            clientGeneration: askGeneration
        )
        return YouTubeWatchPage(data: watchData, askBootstrap: bootstrap)
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

    func getPrivateFeedContinuation(continuation: String) async throws -> YouTubeFeed {
        let data = try await self.request("browse", body: ["continuation": continuation], authPolicy: .required)
        return YouTubeFeedParser.parseContinuation(data)
    }

    func getShorts() async throws -> [YouTubeVideo] {
        self.logger.info("Fetching YouTube Shorts")

        let bundle = try await self.homeBundle(forceRefresh: false)
        if !bundle.feed.shorts.isEmpty {
            return bundle.feed.shorts
        }

        let destinationShorts = await self.publicDestinationShorts()
        if !destinationShorts.isEmpty {
            return destinationShorts
        }

        return try await self.searchShortsFallback()
    }

    private func publicDestinationShorts() async -> [YouTubeVideo] {
        var collected: [YouTubeVideo] = []
        var seen = Set<String>()
        for destination in [YouTubeDestination.news, .sports, .gaming, .learning, .live] {
            do {
                let feed = try await self.getDestinationFeed(destination)
                for short in feed.shorts where seen.insert(short.videoId).inserted {
                    collected.append(short)
                }
                if collected.count >= 30 {
                    break
                }
            } catch {
                self.logger.debug("Shorts fallback destination failed: \(destination.rawValue, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            }
        }
        return Array(collected.prefix(30))
    }

    private func searchShortsFallback() async throws -> [YouTubeVideo] {
        let data = try await self.request("search", body: ["query": "#shorts"], ttl: APICache.TTL.search)
        let feed = YouTubeFeedParser.parse(data)
        var seen = Set<String>()
        return feed.shorts.filter { seen.insert($0.videoId).inserted }
    }

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

    func getHistory(forceRefresh: Bool) async throws -> YouTubeFeed {
        self.logger.info("Fetching YouTube watch history\(forceRefresh ? " (forced)" : "")")

        let data = try await self.request(
            "browse",
            body: ["browseId": "FEhistory"],
            ttl: APICache.TTL.search,
            bypassCache: forceRefresh
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

    func rateVideo(videoId: String, rating: YouTubeRating) async throws {
        self.logger.info("Rating YouTube video")

        let body: [String: Any] = ["target": ["videoId": videoId]]
        _ = try await self.request(rating.endpoint, body: body, retry: false)
        self.cache.invalidate(matching: Self.cachePrefix)
    }

    func setSubscribed(_ subscribed: Bool, channelId: String) async throws {
        self.logger.info("\(subscribed ? "Subscribing to" : "Unsubscribing from") channel")

        let endpoint = subscribed ? "subscription/subscribe" : "subscription/unsubscribe"
        let body: [String: Any] = ["channelIds": [channelId]]
        _ = try await self.request(endpoint, body: body, retry: false)
        self.cache.invalidate(matching: Self.cachePrefix)
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
        self.cache.invalidate(matching: Self.cachePrefix)
    }

    private enum RequestAuthPolicy {
        case optional
        case required
    }

    private struct RequestAuthHeaders {
        let headers: [String: String]
        let authenticated: Bool
        let authIdentityGeneration: UInt64?
    }

    private func authPolicy(forEndpoint endpoint: String, body: [String: Any]) -> RequestAuthPolicy {
        if Self.authRequiredActionEndpoints.contains(endpoint) {
            return .required
        }

        if endpoint == "guide" {
            return .required
        }

        if endpoint == "browse", let browseId = body["browseId"] as? String {
            if Self.authRequiredBrowseIds.contains(browseId)
                || browseId == "VLWL"
                || browseId == "VLLL"
            {
                return .required
            }
        }

        return .optional
    }

    private func buildRequestHeaders(authPolicy: RequestAuthPolicy) async throws -> RequestAuthHeaders {
        if self.authService.hasPersonalAccount {
            let authIdentityGeneration = self.authService.accountIdentityGeneration
            do {
                let headers = try await self.buildAuthHeaders()
                guard authIdentityGeneration == self.authService.accountIdentityGeneration,
                      self.authService.hasPersonalAccount
                else {
                    throw CancellationError()
                }
                return RequestAuthHeaders(
                    headers: headers,
                    authenticated: true,
                    authIdentityGeneration: authIdentityGeneration
                )
            } catch {
                if error is CancellationError {
                    throw error
                }
                try self.validateAuthIdentity(
                    authenticated: true,
                    generation: authIdentityGeneration
                )
                self.authService.sessionExpired(ifIdentityGenerationMatches: authIdentityGeneration)
                throw YTMusicError.authExpired
            }
        } else if authPolicy == .required {
            throw YTMusicError.notAuthenticated
        }

        return RequestAuthHeaders(
            headers: Self.unauthenticatedHeaders,
            authenticated: false,
            authIdentityGeneration: nil
        )
    }

    private static let unauthenticatedHeaders: [String: String] = [
        "Origin": origin,
        "Referer": origin,
        "Content-Type": "application/json",
    ]

    private static let authRequiredBrowseIds: Set<String> = [
        "FEsubscriptions",
        "FElibrary",
        "FEhistory",
        "FEplaylist_aggregation",
    ]

    private static let authRequiredActionEndpoints: Set<String> = [
        "like/like",
        "like/dislike",
        "like/removelike",
        "subscription/subscribe",
        "subscription/unsubscribe",
        "browse/edit_playlist",
        "comment/create_comment",
        "comment/perform_comment_action",
    ]

    private func buildAuthHeaders() async throws -> [String: String] {
        let authMaterial = await webKitManager.authMaterial(for: "youtube.com")
        self.logger.debug("Building YouTube auth headers - total cookies: \(authMaterial.totalCookieCount), youtube.com cookies: \(authMaterial.domainCookieCount)")

        guard let cookieHeader = authMaterial.cookieHeader else {
            self.logger.error("No cookies found for youtube.com domain")
            throw YTMusicError.notAuthenticated
        }

        guard let sapisid = authMaterial.sapisid else {
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
            "X-Goog-AuthUser": "0",
            "X-Origin": Self.origin,
        ]
    }

    private func buildContext(authenticated: Bool) -> [String: Any] {
        var userDict: [String: Any] = [
            "lockedSafetyMode": false,
        ]

        if authenticated, let brandId = self.brandIdProvider?() {
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
                "utcOffsetMinutes": InnerTubeSupport.utcOffsetMinutes(for: .current),
            ],
            "user": userDict,
        ]
    }

    private func request(
        _ endpoint: String,
        body: [String: Any],
        ttl: TimeInterval? = nil,
        retry: Bool = true,
        bypassCache: Bool = false,
        authPolicy explicitAuthPolicy: RequestAuthPolicy? = nil
    ) async throws -> [String: Any] {
        let cacheGeneration = self.cache.generation
        let cacheWriteTicket = ttl.flatMap { _ in
            self.cache.prepareWrite(cacheGeneration: cacheGeneration)
        }
        defer {
            if let cacheWriteTicket {
                self.cache.finishWrite(cacheWriteTicket)
            }
        }
        let authPolicy = explicitAuthPolicy ?? self.authPolicy(forEndpoint: endpoint, body: body)
        let requestAuth = try await self.buildRequestHeaders(authPolicy: authPolicy)

        var fullBody = body
        fullBody["context"] = self.buildContext(authenticated: requestAuth.authenticated)

        let cacheKey = self.cacheKey(
            forEndpoint: Self.cachePrefix + endpoint,
            body: fullBody,
            ttl: ttl,
            authenticated: requestAuth.authenticated
        )
        if let cacheKey, !bypassCache, let cached = self.cache.get(key: cacheKey) {
            self.logger.debug("Cache hit for \(Self.cachePrefix)\(endpoint)")
            return cached
        }

        let cacheWrite = cacheKey.flatMap { key in
            cacheWriteTicket.flatMap { self.cache.beginWrite(for: key, ticket: $0) }
        }

        let json: [String: Any] = if retry {
            try await RetryPolicy.default.execute { [self] in
                try await self.performRequest(
                    endpoint,
                    fullBody: fullBody,
                    headers: requestAuth.headers,
                    authenticated: requestAuth.authenticated,
                    authIdentityGeneration: requestAuth.authIdentityGeneration
                )
            }
        } else {
            try await self.performRequest(
                endpoint,
                fullBody: fullBody,
                headers: requestAuth.headers,
                authenticated: requestAuth.authenticated,
                authIdentityGeneration: requestAuth.authIdentityGeneration
            )
        }

        if let ttl, let cacheKey, let cacheWrite {
            self.cache.setIfCurrent(
                key: cacheKey,
                data: json,
                ttl: ttl,
                reservation: cacheWrite
            )
        }

        return json
    }

    private static func cacheScope(accountIdentity: String, brandId: String) -> String {
        let brand = brandId.isEmpty ? "primary" : brandId
        return "account=\(accountIdentity);brand=\(brand)"
    }

    private static let pendingAccountScope = "pending"

    private func cacheKey(
        forEndpoint endpoint: String,
        body: [String: Any],
        ttl: TimeInterval?,
        authenticated: Bool
    ) -> String? {
        guard ttl != nil else { return nil }
        if !authenticated {
            return APICache.stableCacheKey(endpoint: endpoint, body: body, brandId: "guest")
        }

        let brandId = self.brandIdProvider?() ?? ""
        let scopeIdentity = self.accountCacheIdentityProvider?().flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.pendingAccountScope
        return APICache.stableCacheKey(
            endpoint: endpoint,
            body: body,
            brandId: Self.cacheScope(accountIdentity: scopeIdentity, brandId: brandId)
        )
    }

    private func requestData(
        _ endpoint: String,
        body: [String: Any],
        retry: Bool = true,
        requestAuth precomputedAuth: RequestAuthHeaders? = nil
    ) async throws -> Data {
        let requestAuth: RequestAuthHeaders
        if let precomputedAuth {
            requestAuth = precomputedAuth
        } else {
            let authPolicy = self.authPolicy(forEndpoint: endpoint, body: body)
            requestAuth = try await self.buildRequestHeaders(authPolicy: authPolicy)
        }

        var fullBody = body
        fullBody["context"] = self.buildContext(authenticated: requestAuth.authenticated)

        if retry {
            return try await RetryPolicy.default.execute { [self] in
                try await self.performRequestData(
                    endpoint,
                    fullBody: fullBody,
                    headers: requestAuth.headers,
                    authenticated: requestAuth.authenticated,
                    authIdentityGeneration: requestAuth.authIdentityGeneration
                )
            }
        }
        return try await self.performRequestData(
            endpoint,
            fullBody: fullBody,
            headers: requestAuth.headers,
            authenticated: requestAuth.authenticated,
            authIdentityGeneration: requestAuth.authIdentityGeneration
        )
    }

    private func homeDataCacheKey(body: [String: Any], authenticated: Bool) -> String? {
        var fullBody = body
        fullBody["context"] = self.buildContext(authenticated: authenticated)
        return self.cacheKey(
            forEndpoint: Self.cachePrefix + "data:browse",
            body: fullBody,
            ttl: APICache.TTL.home,
            authenticated: authenticated
        )
    }

    private func cachedHomeData(key: String) -> Data? {
        if let cached = self.cache.getData(key: key) {
            self.logger.debug("Cache hit (data) for \(Self.cachePrefix)browse")
            return cached
        }
        return nil
    }

    private func performRequest(
        _ endpoint: String,
        fullBody: [String: Any],
        headers: [String: String],
        authenticated: Bool,
        authIdentityGeneration: UInt64?
    ) async throws -> [String: Any] {
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration
        )
        var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)")
        components?.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else {
            throw YTMusicError.unknown(message: "Invalid API URL for endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = authenticated

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        self.logger.debug("Making YouTube request to \(endpoint)")

        let result = try await Self.performNetworkRequest(request: request, session: self.session)
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration
        )

        switch result {
        case let .success(data):
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw YTMusicError.parseError(message: "Response is not a JSON object")
            }
            return json
        case let .authError(statusCode):
            self.logger.error("YouTube auth error: HTTP \(statusCode)")
            if authenticated {
                if let authIdentityGeneration {
                    self.authService.sessionExpired(ifIdentityGenerationMatches: authIdentityGeneration)
                }
                throw YTMusicError.authExpired
            }
            throw YTMusicError.notAuthenticated
        case let .httpError(statusCode):
            self.logger.error("YouTube API error: HTTP \(statusCode)")
            throw YTMusicError.apiError(message: "HTTP \(statusCode)", code: statusCode)
        case let .networkError(error):
            throw YTMusicError.networkError(underlying: error)
        }
    }

    private func performRequestData(
        _ endpoint: String,
        fullBody: [String: Any],
        headers: [String: String],
        authenticated: Bool,
        authIdentityGeneration: UInt64?
    ) async throws -> Data {
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration
        )
        var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)")
        components?.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else {
            throw YTMusicError.unknown(message: "Invalid API URL for endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = authenticated

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        self.logger.debug("Making YouTube request (data) to \(endpoint)")

        let result = try await Self.performNetworkRequest(request: request, session: self.session)
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration
        )

        switch result {
        case let .success(data):
            return data
        case let .authError(statusCode):
            self.logger.error("YouTube auth error: HTTP \(statusCode)")
            if authenticated {
                if let authIdentityGeneration {
                    self.authService.sessionExpired(ifIdentityGenerationMatches: authIdentityGeneration)
                }
                throw YTMusicError.authExpired
            }
            throw YTMusicError.notAuthenticated
        case let .httpError(statusCode):
            self.logger.error("YouTube API error: HTTP \(statusCode)")
            throw YTMusicError.apiError(message: "HTTP \(statusCode)", code: statusCode)
        case let .networkError(error):
            throw YTMusicError.networkError(underlying: error)
        }
    }

    private struct AskRevisionKey: Hashable {
        let conversationID: UUID
        let revision: UInt64
    }

    struct AskRequestSnapshot: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let videoID: String
        let authenticationGeneration: UInt64
        let accountBinding: YouTubeAskAccountBinding
        let clientGeneration: UInt64
        let headers: [String: String]
        let context: [String: Any]

        var description: String {
            "<redacted YouTube Ask request snapshot>"
        }

        var debugDescription: String {
            self.description
        }

        var customMirror: Mirror {
            Mirror(reflecting: self.description)
        }
    }

    func makeAskRequestSnapshot(videoID: String) async throws -> AskRequestSnapshot {
        guard self.authService.hasPersonalAccount,
              let accountBinding = self.currentAskAccountBinding()
        else {
            throw YouTubeAskClientError.authenticationRequired
        }
        let requestAuth: RequestAuthHeaders
        do {
            requestAuth = try await self.buildRequestHeaders(authPolicy: .required)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw YouTubeAskClientError.authenticationRequired
        }
        guard requestAuth.authenticated,
              let authenticationGeneration = requestAuth.authIdentityGeneration
        else {
            throw YouTubeAskClientError.authenticationRequired
        }
        let snapshot = AskRequestSnapshot(
            videoID: videoID,
            authenticationGeneration: authenticationGeneration,
            accountBinding: accountBinding,
            clientGeneration: self.askSessionGeneration,
            headers: requestAuth.headers,
            context: self.buildContext(authenticated: true)
        )
        try self.validateAskRequestSnapshot(snapshot)
        return snapshot
    }

    func validateAskRequestSnapshot(_ snapshot: AskRequestSnapshot) throws {
        try self.validateAskIdentity(
            authenticationGeneration: snapshot.authenticationGeneration,
            accountBinding: snapshot.accountBinding,
            clientGeneration: snapshot.clientGeneration
        )
    }

    func validateAskIdentity(
        authenticationGeneration: UInt64,
        accountBinding: YouTubeAskAccountBinding,
        clientGeneration: UInt64
    ) throws {
        guard self.authService.hasPersonalAccount,
              authenticationGeneration == self.authService.accountIdentityGeneration,
              clientGeneration == self.askSessionGeneration,
              accountBinding == self.currentAskAccountBinding()
        else {
            throw CancellationError()
        }
    }

    func makeAskRequest(
        endpoint: String,
        bodyData: Data,
        snapshot: AskRequestSnapshot,
        clickTrackingContextData: Data? = nil
    ) throws -> URLRequest {
        guard endpoint == "get_panel",
              var body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            throw YouTubeAskClientError.invalidResponse
        }
        var context = snapshot.context
        if let clickTrackingContextData {
            guard let clickTrackingContext = try JSONSerialization.jsonObject(
                with: clickTrackingContextData
            ) as? [String: Any],
                let clickTracking = clickTrackingContext["clickTracking"] as? [String: Any]
            else {
                throw YouTubeAskClientError.invalidResponse
            }
            context["clickTracking"] = clickTracking
        }
        body["context"] = context

        var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)")
        components?.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else {
            throw YouTubeAskClientError.invalidResponse
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        for (key, value) in snapshot.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func consumeAskBootstrap(conversationID: UUID) -> Bool {
        self.consumedAskBootstraps.insert(conversationID).inserted
    }

    func consumeAskRevision(
        conversationID: UUID,
        revision: UInt64
    ) -> Bool {
        self.consumedAskRevisions.insert(AskRevisionKey(
            conversationID: conversationID,
            revision: revision
        )).inserted
    }

    func handleAskAuthenticationFailure(snapshot: AskRequestSnapshot) {
        self.authService.sessionExpired(
            ifIdentityGenerationMatches: snapshot.authenticationGeneration
        )
    }

    func nextAskClientMessageID() -> String {
        self.askMessageIDGenerator.next()
    }

    private func currentAskAccountBinding() -> YouTubeAskAccountBinding? {
        guard self.askRequestProfile != nil, self.authService.hasPersonalAccount else { return nil }
        return self.askAccountBindingProvider?()
    }

    private func validateAuthIdentity(authenticated: Bool, generation: UInt64?) throws {
        guard authenticated else { return }
        guard let generation,
              generation == self.authService.accountIdentityGeneration,
              self.authService.hasPersonalAccount
        else {
            throw CancellationError()
        }
    }

    private enum NetworkResult {
        case success(Data)
        case authError(statusCode: Int)
        case httpError(statusCode: Int)
        case networkError(Error)
    }

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
