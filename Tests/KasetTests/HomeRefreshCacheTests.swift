import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.api))
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

    nonisolated static func musicHomePayload(title: String) -> [String: Any] {
        [
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
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    nonisolated static func youtubeHomePayload(title: String) -> [String: Any] {
        [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "richGridRenderer": [
                                    "contents": [[
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
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }
}
