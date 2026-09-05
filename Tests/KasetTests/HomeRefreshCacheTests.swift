import Foundation
import Testing
@testable import Kaset

// MARK: - HomeRefreshCacheTests

@Suite(.serialized, .tags(.api), .timeLimit(.minutes(1)))
@MainActor
struct HomeRefreshCacheTests {
    @Test("YouTube Music force refresh bypasses and replaces the Home cache")
    func musicHomeForceRefreshReplacesCache() async throws {
        let session = MockURLProtocol.makeMockSession()
        let requestCount = LockedCounter()
        MockURLProtocol.setRequestHandler(for: session) { request in
            let ordinal = requestCount.increment()
            let payload = Self.musicHomePayload(title: "Section \(ordinal)")
            return try Self.response(for: request, payload: payload)
        }
        defer { MockURLProtocol.reset(session: session) }

        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()
        let resolver = YTMusicAPIKeyResolver(session: session, environment: { name in
            name == YTMusicAPIKeyResolver.environmentVariable ? "mock-token" : nil
        })
        let client = YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            apiKeyResolver: resolver,
            cache: APICache()
        )

        let initial = try await client.getHome(forceRefresh: false)
        let cached = try await client.getHome(forceRefresh: false)
        let refreshed = try await client.getHome(forceRefresh: true)
        let refreshedCache = try await client.getHome(forceRefresh: false)

        #expect(initial.sections.first?.title == "Section 1")
        #expect(cached.sections.first?.title == "Section 1")
        #expect(refreshed.sections.first?.title == "Section 2")
        #expect(refreshedCache.sections.first?.title == "Section 2")
        #expect(requestCount.count == 2)
    }

    @Test("YouTube force refresh bypasses and replaces the Home cache")
    func youtubeHomeForceRefreshReplacesCache() async throws {
        let session = MockURLProtocol.makeMockSession()
        let requestCount = LockedCounter()
        MockURLProtocol.setRequestHandler(for: session) { request in
            let ordinal = requestCount.increment()
            let payload = Self.youtubeHomePayload(title: "Shelf \(ordinal)")
            return try Self.response(for: request, payload: payload)
        }
        defer { MockURLProtocol.reset(session: session) }

        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()
        let client = YouTubeClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            cache: APICache()
        )

        let initial = try await client.getHomeBundle(forceRefresh: false)
        let cached = try await client.getHomeBundle(forceRefresh: false)
        let refreshed = try await client.getHomeBundle(forceRefresh: true)
        let refreshedCache = try await client.getHomeBundle(forceRefresh: false)

        #expect(initial.shelves.first?.title == "Shelf 1")
        #expect(cached.shelves.first?.title == "Shelf 1")
        #expect(refreshed.shelves.first?.title == "Shelf 2")
        #expect(refreshedCache.shelves.first?.title == "Shelf 2")
        #expect(requestCount.count == 2)
    }

    @Test("A stale YouTube Music Home response cannot replace a forced refresh continuation")
    func musicHomeForceRefreshFencesStaleInitialResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeRefreshControlledURLProtocol.self]
        let session = URLSession(configuration: configuration)
        HomeRefreshControlledURLProtocol.reset()
        defer {
            session.invalidateAndCancel()
            HomeRefreshControlledURLProtocol.reset()
        }

        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()
        let resolver = YTMusicAPIKeyResolver(session: session, environment: { name in
            name == YTMusicAPIKeyResolver.environmentVariable ? "mock-token" : nil
        })
        let client = YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            apiKeyResolver: resolver,
            cache: APICache()
        )

        let staleTask = Task {
            try await client.getHome(forceRefresh: false)
        }
        let staleRequest = await HomeRefreshControlledURLProtocol.nextRequest()

        let freshTask = Task {
            try await client.getHome(forceRefresh: true)
        }
        let freshRequest = await HomeRefreshControlledURLProtocol.nextRequest()

        try HomeRefreshControlledURLProtocol.respond(
            freshRequest,
            data: JSONSerialization.data(
                withJSONObject: Self.musicHomePayload(title: "Fresh", continuation: "fresh-page")
            )
        )
        _ = try await freshTask.value

        try HomeRefreshControlledURLProtocol.respond(
            staleRequest,
            data: JSONSerialization.data(
                withJSONObject: Self.musicHomePayload(title: "Stale", continuation: "stale-page")
            )
        )
        _ = try await staleTask.value

        let continuationTask = Task {
            try await client.getHomeContinuation()
        }
        let continuationRequest = await HomeRefreshControlledURLProtocol.nextRequest()
        let continuationBody = try Self.requestBody(from: continuationRequest.request)
        #expect(continuationBody["continuation"] as? String == "fresh-page")

        try HomeRefreshControlledURLProtocol.respond(
            continuationRequest,
            data: Self.musicHomeContinuationPayload()
        )
        _ = try await continuationTask.value
        #expect(HomeRefreshControlledURLProtocol.requestCount == 3)
    }

    @Test("A stale YouTube Music continuation cannot replace a forced refresh continuation")
    func musicHomeForceRefreshFencesInFlightContinuation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeRefreshControlledURLProtocol.self]
        let session = URLSession(configuration: configuration)
        HomeRefreshControlledURLProtocol.reset()
        defer {
            session.invalidateAndCancel()
            HomeRefreshControlledURLProtocol.reset()
        }

        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()
        let resolver = YTMusicAPIKeyResolver(session: session, environment: { name in
            name == YTMusicAPIKeyResolver.environmentVariable ? "mock-token" : nil
        })
        let client = YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            apiKeyResolver: resolver,
            cache: APICache()
        )

        let seedTask = Task {
            try await client.getHome(forceRefresh: false)
        }
        let seedRequest = await HomeRefreshControlledURLProtocol.nextRequest()
        try HomeRefreshControlledURLProtocol.respond(
            seedRequest,
            data: JSONSerialization.data(
                withJSONObject: Self.musicHomePayload(title: "Seed", continuation: "old-page")
            )
        )
        _ = try await seedTask.value

        let staleContinuationTask = Task {
            try await client.getHomeContinuation()
        }
        let staleContinuationRequest = await HomeRefreshControlledURLProtocol.nextRequest()

        let freshTask = Task {
            try await client.getHome(forceRefresh: true)
        }
        let freshRequest = await HomeRefreshControlledURLProtocol.nextRequest()
        try HomeRefreshControlledURLProtocol.respond(
            freshRequest,
            data: JSONSerialization.data(
                withJSONObject: Self.musicHomePayload(title: "Fresh", continuation: "fresh-page")
            )
        )
        _ = try await freshTask.value

        try HomeRefreshControlledURLProtocol.respond(
            staleContinuationRequest,
            data: Self.musicHomeContinuationPayload(continuation: "stale-next-page")
        )
        let staleSections = try await staleContinuationTask.value
        #expect(staleSections == nil)

        let continuationTask = Task {
            try await client.getHomeContinuation()
        }
        let continuationRequest = await HomeRefreshControlledURLProtocol.nextRequest()
        let continuationBody = try Self.requestBody(from: continuationRequest.request)
        #expect(continuationBody["continuation"] as? String == "fresh-page")

        try HomeRefreshControlledURLProtocol.respond(
            continuationRequest,
            data: Self.musicHomeContinuationPayload()
        )
        _ = try await continuationTask.value
        #expect(HomeRefreshControlledURLProtocol.requestCount == 4)
    }

    @Test("YouTube Music refresh immediately invalidates the previous continuation")
    func musicHomeForceRefreshClearsPreviousContinuation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeRefreshControlledURLProtocol.self]
        let session = URLSession(configuration: configuration)
        HomeRefreshControlledURLProtocol.reset()
        defer {
            session.invalidateAndCancel()
            HomeRefreshControlledURLProtocol.reset()
        }

        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()
        let resolver = YTMusicAPIKeyResolver(session: session, environment: { name in
            name == YTMusicAPIKeyResolver.environmentVariable ? "mock-token" : nil
        })
        let client = YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            apiKeyResolver: resolver,
            cache: APICache()
        )

        let seedTask = Task {
            try await client.getHome(forceRefresh: false)
        }
        let seedRequest = await HomeRefreshControlledURLProtocol.nextRequest()
        try HomeRefreshControlledURLProtocol.respond(
            seedRequest,
            data: JSONSerialization.data(
                withJSONObject: Self.musicHomePayload(title: "Seed", continuation: "old-page")
            )
        )
        _ = try await seedTask.value

        let freshTask = Task {
            try await client.getHome(forceRefresh: true)
        }
        let freshRequest = await HomeRefreshControlledURLProtocol.nextRequest()

        let continuationDuringRefresh = try await client.getHomeContinuation()
        #expect(continuationDuringRefresh == nil)
        #expect(HomeRefreshControlledURLProtocol.requestCount == 2)

        try HomeRefreshControlledURLProtocol.respond(
            freshRequest,
            data: JSONSerialization.data(
                withJSONObject: Self.musicHomePayload(title: "Fresh", continuation: "fresh-page")
            )
        )
        _ = try await freshTask.value

        let continuationTask = Task {
            try await client.getHomeContinuation()
        }
        let continuationRequest = await HomeRefreshControlledURLProtocol.nextRequest()
        let continuationBody = try Self.requestBody(from: continuationRequest.request)
        #expect(continuationBody["continuation"] as? String == "fresh-page")

        try HomeRefreshControlledURLProtocol.respond(
            continuationRequest,
            data: Self.musicHomeContinuationPayload()
        )
        _ = try await continuationTask.value
        #expect(HomeRefreshControlledURLProtocol.requestCount == 3)
    }

    @Test("A stale YouTube continuation cannot replace a forced refresh continuation")
    func youtubeHomeForceRefreshFencesInFlightContinuation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeRefreshControlledURLProtocol.self]
        let session = URLSession(configuration: configuration)
        HomeRefreshControlledURLProtocol.reset()
        defer {
            session.invalidateAndCancel()
            HomeRefreshControlledURLProtocol.reset()
        }

        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()
        let client = YouTubeClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            cache: APICache()
        )

        let seedTask = Task {
            try await client.getHomeBundle(forceRefresh: false)
        }
        let seedRequest = await HomeRefreshControlledURLProtocol.nextRequest()
        try HomeRefreshControlledURLProtocol.respond(
            seedRequest,
            data: JSONSerialization.data(
                withJSONObject: Self.youtubeHomePayload(title: "Seed", continuation: "old-page")
            )
        )
        _ = try await seedTask.value

        let staleContinuationTask = Task {
            try await client.getHomeFeedContinuation()
        }
        let staleContinuationRequest = await HomeRefreshControlledURLProtocol.nextRequest()

        let freshTask = Task {
            try await client.getHomeBundle(forceRefresh: true)
        }
        let freshRequest = await HomeRefreshControlledURLProtocol.nextRequest()
        try HomeRefreshControlledURLProtocol.respond(
            freshRequest,
            data: JSONSerialization.data(
                withJSONObject: Self.youtubeHomePayload(title: "Fresh", continuation: "fresh-page")
            )
        )
        _ = try await freshTask.value

        try HomeRefreshControlledURLProtocol.respond(
            staleContinuationRequest,
            data: Self.youtubeHomeContinuationPayload(continuation: "stale-next-page")
        )
        let staleFeed = try await staleContinuationTask.value
        #expect(staleFeed == nil)

        let continuationTask = Task {
            try await client.getHomeFeedContinuation()
        }
        let continuationRequest = await HomeRefreshControlledURLProtocol.nextRequest()
        let continuationBody = try Self.requestBody(from: continuationRequest.request)
        #expect(continuationBody["continuation"] as? String == "fresh-page")

        try HomeRefreshControlledURLProtocol.respond(
            continuationRequest,
            data: Self.youtubeHomeContinuationPayload()
        )
        _ = try await continuationTask.value
        #expect(HomeRefreshControlledURLProtocol.requestCount == 4)
    }

    @Test("YouTube refresh keeps deferred topic rails cache-bypassed")
    func youtubeRefreshForcesDeferredTopicRails() async {
        let client = MockYouTubeClient()
        let viewModel = YouTubeHomeViewModel(client: client)
        client.homeFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        client.homeChips = (0 ..< 4).map { index in
            YouTubeHomeChip(title: "Topic \(index)", continuation: "tok-\(index)")
        }
        client.homeTopicFeeds = Dictionary(uniqueKeysWithValues: (0 ..< 4).map { index in
            ("tok-\(index)", YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 2), continuation: nil))
        })

        await viewModel.load()
        await viewModel.refresh()

        #expect(client.requestedTopicForceRefreshes == [false, false, true, true])
        #expect(viewModel.hasMoreTopicRails)

        await viewModel.loadMoreTopicRails()

        #expect(client.requestedTopicForceRefreshes == [false, false, true, true, true, true])
        #expect(viewModel.hasMoreTopicRails == false)
    }

    @Test("A stale YouTube topic response cannot overwrite a forced refresh")
    func youtubeTopicForceRefreshFencesStaleCacheWrite() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeRefreshControlledURLProtocol.self]
        let session = URLSession(configuration: configuration)
        HomeRefreshControlledURLProtocol.reset()
        defer {
            session.invalidateAndCancel()
            HomeRefreshControlledURLProtocol.reset()
        }

        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()
        let client = YouTubeClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            cache: APICache()
        )

        let staleTask = Task {
            try await client.getHomeTopicFeed(continuation: "topic", forceRefresh: false)
        }
        let staleRequest = await HomeRefreshControlledURLProtocol.nextRequest()

        let freshTask = Task {
            try await client.getHomeTopicFeed(continuation: "topic", forceRefresh: true)
        }
        let freshRequest = await HomeRefreshControlledURLProtocol.nextRequest()

        try HomeRefreshControlledURLProtocol.respond(
            freshRequest,
            data: Self.youtubeTopicPayload(videoID: "fresh")
        )
        let refreshed = try await freshTask.value

        try HomeRefreshControlledURLProtocol.respond(
            staleRequest,
            data: Self.youtubeTopicPayload(videoID: "stale")
        )
        _ = try await staleTask.value

        try HomeRefreshControlledURLProtocol.setAutomaticResponse(
            Self.youtubeTopicPayload(videoID: "unexpected-network-request")
        )
        let cached = try await client.getHomeTopicFeed(continuation: "topic", forceRefresh: false)

        #expect(refreshed.videos.first?.videoId == "fresh")
        #expect(cached.videos.first?.videoId == "fresh")
        #expect(HomeRefreshControlledURLProtocol.requestCount == 2)
    }

    nonisolated static func response(
        for request: URLRequest,
        payload: [String: Any]
    ) throws -> (HTTPURLResponse, Data) {
        let url = try #require(request.url)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, data)
    }

    nonisolated static func musicHomePayload(
        title: String,
        continuation: String? = nil
    ) -> [String: Any] {
        let continuations: [[String: Any]] = if let continuation {
            [[
                "nextContinuationData": [
                    "continuation": continuation,
                ],
            ]]
        } else {
            []
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "title": ["runs": [["text": title]]],
                                            "contents": [[
                                                "musicResponsiveListItemRenderer": [
                                                    "playlistItemData": ["videoId": "video"],
                                                    "flexColumns": [[
                                                        "musicResponsiveListItemFlexColumnRenderer": [
                                                            "text": ["runs": [["text": "Song"]]],
                                                        ],
                                                    ]],
                                                ],
                                            ]],
                                        ],
                                    ]],
                                    "continuations": continuations,
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    nonisolated static func musicHomeContinuationPayload(continuation: String? = nil) throws -> Data {
        var sectionListContinuation: [String: Any] = ["contents": []]
        if let continuation {
            sectionListContinuation["continuations"] = [[
                "nextContinuationData": [
                    "continuation": continuation,
                ],
            ]]
        }

        return try JSONSerialization.data(withJSONObject: [
            "continuationContents": [
                "sectionListContinuation": sectionListContinuation,
            ],
        ])
    }

    nonisolated static func requestBody(from request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }

            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                result.append(buffer, count: count)
            }
            data = result
        } else {
            throw URLError(.cannotDecodeRawData)
        }

        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    nonisolated static func youtubeHomePayload(
        title: String,
        continuation: String? = nil
    ) -> [String: Any] {
        var contents: [[String: Any]] = [[
            "richSectionRenderer": [
                "content": [
                    "richShelfRenderer": [
                        "title": ["runs": [["text": title]]],
                        "contents": [[
                            "richItemRenderer": [
                                "content": [
                                    "videoRenderer": [
                                        "videoId": "video",
                                        "title": ["runs": [["text": "Video"]]],
                                    ],
                                ],
                            ],
                        ]],
                    ],
                ],
            ],
        ]]
        if let continuation {
            contents.append(Self.youtubeContinuationItem(continuation))
        }

        return [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "richGridRenderer": [
                                    "contents": contents,
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    nonisolated static func youtubeHomeContinuationPayload(continuation: String? = nil) throws -> Data {
        let items = continuation.map { [Self.youtubeContinuationItem($0)] } ?? []
        return try JSONSerialization.data(withJSONObject: [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": items,
                ],
            ]],
        ])
    }

    nonisolated static func youtubeContinuationItem(_ continuation: String) -> [String: Any] {
        [
            "continuationItemRenderer": [
                "continuationEndpoint": [
                    "continuationCommand": [
                        "token": continuation,
                    ],
                ],
            ],
        ]
    }

    nonisolated static func youtubeTopicPayload(videoID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": [[
                        "richItemRenderer": [
                            "content": [
                                "videoRenderer": [
                                    "videoId": videoID,
                                    "title": ["runs": [["text": "Video \(videoID)"]]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ]],
        ])
    }
}

// MARK: - HomeRefreshControlledURLProtocol

private final class HomeRefreshControlledURLProtocol: URLProtocol {
    private static let lock = NSLock()
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var pendingRequests: [HomeRefreshControlledURLProtocol] = []
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var automaticResponse: Data?
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var observedRequestCount = 0

    static var requestCount: Int {
        lock.withLock { Self.observedRequestCount }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let automaticResponse: Data? = Self.lock.withLock {
            Self.observedRequestCount += 1
            if let automaticResponse = Self.automaticResponse {
                return automaticResponse
            }
            Self.pendingRequests.append(self)
            return nil
        }

        if let automaticResponse {
            Self.respond(self, data: automaticResponse)
        }
    }

    override func stopLoading() {}

    @MainActor
    static func nextRequest() async -> HomeRefreshControlledURLProtocol {
        while true {
            let request: HomeRefreshControlledURLProtocol? = Self.lock.withLock {
                if !Self.pendingRequests.isEmpty {
                    return Self.pendingRequests.removeFirst()
                }
                return nil
            }
            if let request {
                return request
            }
            await Task.yield()
        }
    }

    static func setAutomaticResponse(_ data: Data) {
        self.lock.withLock {
            Self.automaticResponse = data
        }
    }

    static func reset() {
        self.lock.withLock {
            Self.pendingRequests = []
            Self.automaticResponse = nil
            Self.observedRequestCount = 0
        }
    }

    static func respond(_ protocolInstance: HomeRefreshControlledURLProtocol, data: Data) {
        guard let url = protocolInstance.request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            protocolInstance.client?.urlProtocol(
                protocolInstance,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        protocolInstance.client?.urlProtocol(
            protocolInstance,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        protocolInstance.client?.urlProtocol(protocolInstance, didLoad: data)
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }
}
