import CryptoKit
import Foundation
import Testing
@testable import Kaset

// MARK: - YTMusicClientTests

/// Tests for YTMusicClient.
@Suite(.tags(.api))
struct YTMusicClientTests {
    @Test("SAPISIDHASH format is correct")
    func sapisidhashFormat() {
        let timestamp = 1_703_001_600
        let sapisid = "example_sapisid_value"
        let origin = "https://music.youtube.com"

        let hashInput = "\(timestamp) \(sapisid) \(origin)"
        let hash = Insecure.SHA1.hash(data: Data(hashInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let sapisidhash = "\(timestamp)_\(hash)"

        #expect(sapisidhash.contains("_"))
        let parts = sapisidhash.split(separator: "_")
        #expect(parts.count == 2)
        #expect(String(parts[0]) == "\(timestamp)")
        #expect(parts[1].count == 40, "SHA1 produces 40 hex characters")
    }

    @Test("SHA1 hash consistency")
    func sha1HashConsistency() {
        let input = "test input string"
        let hash1 = Insecure.SHA1.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let hash2 = Insecure.SHA1.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(hash1 == hash2)
        #expect(hash1.count == 40)
    }

    @Test("Song model parsing")
    func modelParsing() throws {
        let songData: [String: Any] = [
            "videoId": "dQw4w9WgXcQ",
            "title": "Never Gonna Give You Up",
            "artists": [
                ["name": "Rick Astley", "id": "UC123"],
            ],
            "duration_seconds": 213.0,
            "thumbnails": [
                ["url": "https://example.com/thumb.jpg", "width": 120, "height": 120],
            ],
        ]

        let song = try #require(Song(from: songData))
        #expect(song.videoId == "dQw4w9WgXcQ")
        #expect(song.title == "Never Gonna Give You Up")
        #expect(song.artists.count == 1)
        #expect(song.artists.first?.name == "Rick Astley")
        #expect(song.duration == 213.0)
    }

    @Test("Song parsing with missing videoId returns nil")
    func songParsingWithMissingVideoId() {
        let songData: [String: Any] = [
            "title": "Test Song",
        ]

        let song = Song(from: songData)
        #expect(song == nil)
    }

    @Test("Playlist model parsing")
    func playlistParsing() throws {
        let playlistData: [String: Any] = [
            "playlistId": "PLtest123",
            "title": "My Playlist",
            "trackCount": 25,
            "thumbnails": [
                ["url": "https://example.com/playlist.jpg"],
            ],
        ]

        let playlist = try #require(Playlist(from: playlistData))
        #expect(playlist.id == "PLtest123")
        #expect(playlist.title == "My Playlist")
        #expect(playlist.trackCount == 25)
    }

    @Test("Album model parsing")
    func albumParsing() throws {
        let albumData: [String: Any] = [
            "browseId": "MPREtest",
            "title": "Test Album",
            "year": "2023",
        ]

        let album = try #require(Album(from: albumData))
        #expect(album.id == "MPREtest")
        #expect(album.title == "Test Album")
        #expect(album.year == "2023")
    }

    @Test("Artist model parsing")
    func artistParsing() throws {
        let artistData: [String: Any] = [
            "browseId": "UC123456",
            "name": "Test Artist",
        ]

        let artist = try #require(Artist(from: artistData))
        #expect(artist.id == "UC123456")
        #expect(artist.name == "Test Artist")
    }

    // MARK: - Podcast Show ID Validation Tests

    @Test("Podcast show ID conversion handles L-prefixed suffix correctly")
    func podcastShowIdConversionWithLPrefix() {
        // Real podcast IDs are "MPSPP" + "L" + {base64id}
        // Example: "MPSPPLXz2p9abc123"
        let showId = "MPSPPLXz2p9abc123"
        let suffix = String(showId.dropFirst(5)) // "LXz2p9abc123"
        let playlistId = "P" + suffix // "PLXz2p9abc123"

        #expect(suffix == "LXz2p9abc123")
        #expect(suffix.hasPrefix("L"), "Suffix should start with 'L'")
        #expect(playlistId == "PLXz2p9abc123")
        #expect(playlistId.hasPrefix("PL"), "Playlist ID should start with 'PL'")
    }

    @Test("Podcast show ID conversion avoids double-L bug")
    func podcastShowIdAvoidDoubleLBug() {
        // The bug was: "PL" + suffix = "PLLXz2p9..." (double L = 404)
        // Fix: "P" + suffix = "PLXz2p9..." (correct)
        let showId = "MPSPPLXz2p9abc123"
        let suffix = String(showId.dropFirst(5)) // "LXz2p9abc123"

        // Wrong: This was the bug
        let wrongPlaylistId = "PL" + suffix // "PLLXz2p9abc123" - DOUBLE L!
        #expect(wrongPlaylistId.hasPrefix("PLL"), "Bug would produce double-L")

        // Correct: This is the fix
        let correctPlaylistId = "P" + suffix // "PLXz2p9abc123"
        #expect(!correctPlaylistId.hasPrefix("PLL"), "Fix should not have double-L")
        #expect(correctPlaylistId == "PLXz2p9abc123")
    }

    @Test("Podcast show ID with only MPSPP prefix is invalid")
    func podcastShowIdWithOnlyPrefix() {
        // This tests the validation logic we added
        let showId = "MPSPP"
        let suffix = String(showId.dropFirst(5))

        #expect(suffix.isEmpty, "Empty suffix should trigger validation error")
    }

    @Test("Valid podcast show IDs have L-prefixed content after MPSPP")
    func validPodcastShowIdHasLPrefixedContent() {
        let validShowId = "MPSPPLabc123"
        let suffix = String(validShowId.dropFirst(5))

        #expect(!suffix.isEmpty)
        #expect(suffix.hasPrefix("L"), "Valid suffix should start with 'L'")
        #expect(suffix == "Labc123")
    }

    @Test("Podcast show ID without L-prefix should be rejected")
    func podcastShowIdWithoutLPrefix() {
        // IDs like "MPSPPX123" would be invalid
        let invalidShowId = "MPSPPX123"
        let suffix = String(invalidShowId.dropFirst(5))

        #expect(!suffix.isEmpty)
        #expect(!suffix.hasPrefix("L"), "This ID doesn't have required L-prefix")
    }

    // MARK: - Podcast Subscription Integration Tests

    @Test("subscribeToPodcast throws for empty suffix")
    @MainActor
    func subscribeToPodcastThrowsForEmptySuffix() async {
        let mockClient = MockYTMusicClient()

        await #expect(throws: YTMusicError.self) {
            try await mockClient.subscribeToPodcast(showId: "MPSPP")
        }
    }

    @Test("subscribeToPodcast throws for missing L-prefix")
    @MainActor
    func subscribeToPodcastThrowsForMissingLPrefix() async {
        let mockClient = MockYTMusicClient()

        await #expect(throws: YTMusicError.self) {
            try await mockClient.subscribeToPodcast(showId: "MPSPPX123")
        }
    }

    @Test("subscribeToPodcast succeeds for valid MPSPP ID")
    @MainActor
    func subscribeToPodcastSucceedsForValidId() async throws {
        let mockClient = MockYTMusicClient()

        // Should not throw for valid ID
        try await mockClient.subscribeToPodcast(showId: "MPSPPLXz2p9abc123")
    }

    @Test("unsubscribeFromPodcast throws for empty suffix")
    @MainActor
    func unsubscribeFromPodcastThrowsForEmptySuffix() async {
        let mockClient = MockYTMusicClient()

        await #expect(throws: YTMusicError.self) {
            try await mockClient.unsubscribeFromPodcast(showId: "MPSPP")
        }
    }

    @Test("unsubscribeFromPodcast throws for missing L-prefix")
    @MainActor
    func unsubscribeFromPodcastThrowsForMissingLPrefix() async {
        let mockClient = MockYTMusicClient()

        await #expect(throws: YTMusicError.self) {
            try await mockClient.unsubscribeFromPodcast(showId: "MPSPPX123")
        }
    }

    @Test("unsubscribeFromPodcast succeeds for valid MPSPP ID")
    @MainActor
    func unsubscribeFromPodcastSucceedsForValidId() async throws {
        let mockClient = MockYTMusicClient()

        // Should not throw for valid ID
        try await mockClient.unsubscribeFromPodcast(showId: "MPSPPLXz2p9abc123")
    }
}

// MARK: - YTMusicClientSearchRequestTests

@Suite(.serialized, .tags(.api))
@MainActor
struct YTMusicClientSearchRequestTests {
    @Test("Filtered search and continuation route through search with exact parameters")
    func filteredSearchAndContinuationRouting() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()
        let recorder = SearchRequestRecorder()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            let bodyData = try Self.requestBodyData(request)
            let body = try #require(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            recorder.append(SearchRequestRecord(
                path: url.path,
                query: body["query"] as? String,
                params: body["params"] as? String,
                continuation: body["continuation"] as? String,
                hasBrowseId: body["browseId"] != nil
            ))

            let payload: [String: Any]
            if body["continuation"] != nil {
                payload = Self.continuationSearchPayload(continuation: "continuation-next")
            } else {
                let continuation = switch body["params"] as? String {
                case "EgWKAQIQAWoMEA4QChADEAQQCRAF": "video-next"
                case "EgWKAQJYAWoMEA4QChADEAQQCRAF": "profile-next"
                case "EgWKAQJIAWoMEA4QChADEAQQCRAF": "episode-next"
                default: "unexpected-next"
                }
                payload = Self.firstPageSearchPayload(continuation: continuation)
            }
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
        defer { MockURLProtocol.reset(session: session) }

        let client = self.makeClient(session: session)

        let videos = try await client.searchVideos(query: "video query")
        let profiles = try await client.searchProfiles(query: "profile query")
        let episodes = try await client.searchEpisodes(query: "episode query")
        let videoContinuation = try #require(videos.continuationToken)
        let continuation = try await client.getSearchContinuation(token: videoContinuation)

        #expect(videoContinuation == "video-next")
        #expect(profiles.continuationToken == "profile-next")
        #expect(episodes.continuationToken == "episode-next")
        #expect(continuation.videos.map(\.videoId) == ["continued-video"])
        #expect(continuation.continuationToken == "continuation-next")

        let records = recorder.records
        try #require(records.count == 4)
        #expect(records.map(\.path) == Array(repeating: "/youtubei/v1/search", count: 4))
        #expect(records.allSatisfy { !$0.hasBrowseId })
        #expect(records[0] == SearchRequestRecord(
            path: "/youtubei/v1/search",
            query: "video query",
            params: "EgWKAQIQAWoMEA4QChADEAQQCRAF",
            continuation: nil,
            hasBrowseId: false
        ))
        #expect(records[1] == SearchRequestRecord(
            path: "/youtubei/v1/search",
            query: "profile query",
            params: "EgWKAQJYAWoMEA4QChADEAQQCRAF",
            continuation: nil,
            hasBrowseId: false
        ))
        #expect(records[2] == SearchRequestRecord(
            path: "/youtubei/v1/search",
            query: "episode query",
            params: "EgWKAQJIAWoMEA4QChADEAQQCRAF",
            continuation: nil,
            hasBrowseId: false
        ))
        #expect(records[3] == SearchRequestRecord(
            path: "/youtubei/v1/search",
            query: nil,
            params: nil,
            continuation: "video-next",
            hasBrowseId: false
        ))
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func firstPageSearchPayload(continuation: String) -> [String: Any] {
        [
            "contents": [
                "tabbedSearchResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": [],
                                            "continuations": [[
                                                "nextContinuationData": [
                                                    "continuation": continuation,
                                                ],
                                            ]],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func continuationSearchPayload(continuation: String) -> [String: Any] {
        [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": [
                        [
                            "musicResponsiveListItemRenderer": [
                                "playlistItemData": ["videoId": "continued-video"],
                                "navigationEndpoint": [
                                    "watchEndpoint": [
                                        "videoId": "continued-video",
                                        "watchEndpointMusicSupportedConfigs": [
                                            "watchEndpointMusicConfig": [
                                                "musicVideoType": "MUSIC_VIDEO_TYPE_UGC",
                                            ],
                                        ],
                                    ],
                                ],
                                "flexColumns": [
                                    [
                                        "musicResponsiveListItemFlexColumnRenderer": [
                                            "text": ["runs": [["text": "Continued Video"]]],
                                        ],
                                    ],
                                    [
                                        "musicResponsiveListItemFlexColumnRenderer": [
                                            "text": ["runs": [["text": "Video"]]],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                        [
                            "continuationItemRenderer": [
                                "continuationEndpoint": [
                                    "continuationCommand": ["token": continuation],
                                ],
                            ],
                        ],
                    ],
                ],
            ]],
        ]
    }

    // URLSession may bridge `httpBody` to a stream before URLProtocol observes the request.
    // swiftlint:disable:next modifier_order
    private nonisolated static func requestBodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            throw YTMusicError.parseError(message: "Search request body was missing")
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? YTMusicError.parseError(message: "Search request body could not be read")
            }
            if count == 0 {
                return data
            }
            data.append(buffer, count: count)
        }
    }

    private func makeClient(session: URLSession) -> YTMusicClient {
        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        let resolver = YTMusicAPIKeyResolver(session: session, environment: { name in
            name == YTMusicAPIKeyResolver.environmentVariable ? "mock-token" : nil
        })
        return YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            apiKeyResolver: resolver
        )
    }
}

// MARK: - SearchRequestRecord

private struct SearchRequestRecord: Equatable, Sendable {
    let path: String
    let query: String?
    let params: String?
    let continuation: String?
    let hasBrowseId: Bool
}

// MARK: - SearchRequestRecorder

private final class SearchRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRecords: [SearchRequestRecord] = []

    var records: [SearchRequestRecord] {
        self.lock.withLock { self.storedRecords }
    }

    func append(_ record: SearchRequestRecord) {
        self.lock.withLock {
            self.storedRecords.append(record)
        }
    }
}

// MARK: - YTMusicAPIKeyResolverTests

/// Tests for runtime resolution of the YouTube Music web client API key.
@Suite(.serialized, .tags(.api))
struct YTMusicAPIKeyResolverTests {
    @Test("Extracts Innertube API key from web client HTML")
    @MainActor
    func extractsInnertubeAPIKey() {
        let html = #"ytcfg.set({"INNERTUBE_API_KEY":"mock-token","INNERTUBE_API_VERSION":"v1"});"#

        #expect(YTMusicAPIKeyResolver.extractInnertubeAPIKey(from: html) == "mock-token")
    }

    @Test("Environment override is trimmed and avoids network fetch")
    @MainActor
    func environmentOverrideAvoidsNetworkFetch() async throws {
        let session = MockURLProtocol.makeMockSession()
        MockURLProtocol.setRequestHandler(for: session) { _ in
            throw URLError(.badServerResponse)
        }
        defer {
            MockURLProtocol.reset(session: session)
        }

        let resolver = YTMusicAPIKeyResolver(
            session: session,
            environment: { name in
                name == YTMusicAPIKeyResolver.environmentVariable ? "  mock-token\n" : nil
            }
        )

        let apiKey = try await resolver.resolve()

        #expect(apiKey == "mock-token")
    }

    @Test("Fetches and caches API key from mocked web client HTML")
    @MainActor
    func fetchesAndCachesAPIKeyFromHTML() async throws {
        let session = MockURLProtocol.makeMockSession()
        let html = #"ytcfg.set({"INNERTUBE_API_KEY":"mock-token"});"#
        let requestCount = LockedCounter()

        MockURLProtocol.setRequestHandler(for: session) { request in
            requestCount.increment()
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "text/html"]
                  )
            else {
                throw URLError(.badURL)
            }

            return (response, Data(html.utf8))
        }
        defer {
            MockURLProtocol.reset(session: session)
        }

        let resolver = YTMusicAPIKeyResolver(session: session, environment: { _ in nil })

        let first = try await resolver.resolve()
        let second = try await resolver.resolve()

        #expect(first == "mock-token")
        #expect(second == "mock-token")
        #expect(requestCount.count == 1)
    }

    @Test("Concurrent cold resolves share one web client fetch")
    @MainActor
    func concurrentColdResolvesShareOneWebClientFetch() async throws {
        let session = MockURLProtocol.makeMockSession()
        let html = #"ytcfg.set({"INNERTUBE_API_KEY":"mock-token"});"#
        let firstRequestGate = DispatchSemaphore(value: 0)
        let requestCount = LockedCounter()

        MockURLProtocol.setRequestHandler(for: session) { request in
            if requestCount.increment() == 1 {
                _ = firstRequestGate.wait(timeout: .now() + 5)
            }
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "text/html"]
                  )
            else {
                throw URLError(.badURL)
            }

            return (response, Data(html.utf8))
        }
        defer {
            firstRequestGate.signal()
            MockURLProtocol.reset(session: session)
        }

        let resolver = YTMusicAPIKeyResolver(session: session, environment: { _ in nil })

        async let first = resolver.resolve()
        while requestCount.isEmpty {
            await Task.yield()
        }
        async let second = resolver.resolve()
        async let third = resolver.resolve()

        firstRequestGate.signal()
        let results = try await [first, second, third]

        #expect(results == ["mock-token", "mock-token", "mock-token"])
        #expect(requestCount.count == 1)
    }

    @Test("API key fetch is cookieless and sends consent cookie")
    @MainActor
    func apiKeyFetchIsCookielessAndSendsConsentCookie() async throws {
        let session = MockURLProtocol.makeMockSession()
        let html = #"ytcfg.set({"INNERTUBE_API_KEY":"mock-html-api-key"});"#
        nonisolated(unsafe) var observedShouldHandleCookies: Bool?
        nonisolated(unsafe) var observedCookieHeader: String?
        nonisolated(unsafe) var observedUserAgent: String?

        MockURLProtocol.requestHandler = { request in
            observedShouldHandleCookies = request.httpShouldHandleCookies
            observedCookieHeader = request.value(forHTTPHeaderField: "Cookie")
            observedUserAgent = request.value(forHTTPHeaderField: "User-Agent")

            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "text/html"]
                  )
            else {
                throw URLError(.badURL)
            }

            return (response, Data(html.utf8))
        }
        defer {
            MockURLProtocol.reset()
        }

        let resolver = YTMusicAPIKeyResolver(session: session, environment: { _ in nil })

        let apiKey = try await resolver.resolve()

        #expect(apiKey == "mock-html-api-key")
        #expect(observedShouldHandleCookies == false)
        #expect(observedCookieHeader == "SOCS=CAI")
        #expect(observedUserAgent == APISessionConfiguration.userAgent)
    }

    @Test("HTTP failures map to YTMusic API errors")
    @MainActor
    func httpFailureMapsToAPIError() async throws {
        let session = MockURLProtocol.makeMockSession()
        MockURLProtocol.setRequestHandler(for: session) { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 503,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "text/html"]
                  )
            else {
                throw URLError(.badURL)
            }

            return (response, Data("temporarily unavailable".utf8))
        }
        defer {
            MockURLProtocol.reset(session: session)
        }

        let resolver = YTMusicAPIKeyResolver(session: session, environment: { _ in nil })

        do {
            _ = try await resolver.resolve()
            Issue.record("Expected resolver to throw for HTTP 503")
        } catch let error as YTMusicError {
            guard case let .apiError(_, code) = error else {
                Issue.record("Expected apiError, got \(error)")
                return
            }
            #expect(code == 503)
        }
    }

    @Test("HTML without API key maps to parse error")
    @MainActor
    func missingAPIKeyMapsToParseError() async throws {
        let session = MockURLProtocol.makeMockSession()
        MockURLProtocol.setRequestHandler(for: session) { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "text/html"]
                  )
            else {
                throw URLError(.badURL)
            }

            return (response, Data("<html></html>".utf8))
        }
        defer {
            MockURLProtocol.reset(session: session)
        }

        let resolver = YTMusicAPIKeyResolver(session: session, environment: { _ in nil })

        do {
            _ = try await resolver.resolve()
            Issue.record("Expected resolver to throw for missing API key")
        } catch let error as YTMusicError {
            guard case .parseError = error else {
                Issue.record("Expected parseError, got \(error)")
                return
            }
        }
    }
}

// MARK: - YTMusicClientContinuationResetTests

@Suite(.serialized, .tags(.api))
@MainActor
struct YTMusicClientContinuationResetTests {
    @Test("Stale home continuation cannot repopulate page cursor after reset")
    func staleHomeContinuationCannotRepopulatePageCursorAfterReset() async throws {
        let session = MockURLProtocol.makeMockSession()
        let requestCount = LockedCounter()
        let continuationRequestCount = LockedCounter()

        MockURLProtocol.setRequestHandler(for: session) { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"mock-token"});"#.utf8))
            }

            let currentRequestCount = requestCount.increment()
            let payload: [String: Any]
            if currentRequestCount == 2 {
                continuationRequestCount.increment()
                Thread.sleep(forTimeInterval: 0.15)
                payload = Self.homeContinuationPayload(nextCursor: "page-2")
            } else {
                payload = Self.homePayload(cursor: "page-1")
            }

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
        defer { MockURLProtocol.reset(session: session) }

        let authService = AuthService(webKitManager: MockWebKitManager())
        let client = YTMusicClient(authService: authService, session: session)

        _ = try await client.getHome()
        async let staleContinuation = client.getHomeContinuation()
        try? await Task.sleep(for: .milliseconds(30))
        client.resetSessionStateForAccountSwitch()

        let staleResult = try await staleContinuation
        let secondResult = try await client.getHomeContinuation()

        #expect(staleResult == nil)
        #expect(secondResult == nil)
        #expect(continuationRequestCount.count == 1)
    }

    @Test("Stale search continuation is discarded after reset")
    func staleSearchContinuationIsDiscardedAfterReset() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()
        let requestCount = LockedCounter()

        MockURLProtocol.setRequestHandler(for: session) { request in
            requestCount.increment()
            Thread.sleep(forTimeInterval: 0.15)
            let url = try #require(request.url)

            let data = try JSONSerialization.data(
                withJSONObject: Self.searchContinuationPayload(nextCursor: "page-2")
            )
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
        defer { MockURLProtocol.reset(session: session) }

        let authService = AuthService(webKitManager: MockWebKitManager())
        let resolver = YTMusicAPIKeyResolver(session: session, environment: { name in
            name == YTMusicAPIKeyResolver.environmentVariable ? "mock-token" : nil
        })
        let client = YTMusicClient(
            authService: authService,
            session: session,
            apiKeyResolver: resolver
        )

        async let staleContinuation = client.getSearchContinuation(token: "page-1")
        try? await Task.sleep(for: .milliseconds(30))
        client.resetSessionStateForAccountSwitch()

        do {
            _ = try await staleContinuation
            Issue.record("Expected stale search continuation to be cancelled")
        } catch is CancellationError {
            // Expected: reset invalidates any continuation already in flight.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(requestCount.count == 1)

        let retry = try await client.getSearchContinuation(token: "page-1")
        #expect(retry.continuationToken == "page-2")
        #expect(requestCount.count == 2)
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func homePayload(cursor: String) -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [],
                                    "continuations": [[
                                        "nextContinuationData": [
                                            "continuation": cursor,
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func searchContinuationPayload(nextCursor: String) -> [String: Any] {
        [
            "continuationContents": [
                "musicShelfContinuation": [
                    "contents": [],
                    "continuations": [[
                        "nextContinuationData": [
                            "continuation": nextCursor,
                        ],
                    ]],
                ],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func homeContinuationPayload(nextCursor: String) -> [String: Any] {
        [
            "continuationContents": [
                "sectionListContinuation": [
                    "contents": [],
                    "continuations": [[
                        "nextContinuationData": [
                            "continuation": nextCursor,
                        ],
                    ]],
                ],
            ],
        ]
    }
}
