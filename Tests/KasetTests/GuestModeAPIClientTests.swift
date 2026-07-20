import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.api))
struct GuestModeAPIClientTests {
    @Test("YouTube public requests omit auth headers when logged out")
    @MainActor
    func youTubePublicRequestsOmitAuthHeadersWhenLoggedOut() async throws {
        APICache.shared.invalidateAll()
        let webKitManager = MockWebKitManager()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()

        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var apiRequestCount = 0
        MockURLProtocol.setRequestHandler(for: session) { request in
            apiRequestCount += 1
            #expect(request.url?.host == "www.youtube.com")
            let authHeader = ["Author", "ization"].joined()
            let cookieHeader = ["Coo", "kie"].joined()
            #expect(request.value(forHTTPHeaderField: authHeader) == nil)
            #expect(request.value(forHTTPHeaderField: cookieHeader) == nil)
            #expect(request.httpShouldHandleCookies == false)

            let data = try JSONSerialization.data(withJSONObject: [:])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = YouTubeClient(authService: authService, session: session)
        let response = try await client.search(query: "swift", filter: .all)

        #expect(response.videos.isEmpty)
        #expect(apiRequestCount == 1)
    }

    @Test("YouTube private requests fail before network when logged out")
    @MainActor
    func youTubePrivateRequestsFailBeforeNetworkWhenLoggedOut() async throws {
        let webKitManager = MockWebKitManager()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()

        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.setRequestHandler(for: session) { request in
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{}"#.utf8))
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = YouTubeClient(authService: authService, session: session)

        await #expect(throws: YTMusicError.self) {
            _ = try await client.getUserPlaylists()
        }
        #expect(requestCount == 0)
    }

    @Test("YouTube Music public requests omit auth headers when logged out")
    @MainActor
    func youTubeMusicPublicRequestsOmitAuthHeadersWhenLoggedOut() async throws {
        APICache.shared.invalidateAll()
        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()

        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var apiRequestCount = 0
        MockURLProtocol.setRequestHandler(for: session) { request in
            apiRequestCount += 1
            #expect(request.url?.host == "music.youtube.com")
            let authHeader = ["Author", "ization"].joined()
            let cookieHeader = ["Coo", "kie"].joined()
            #expect(request.value(forHTTPHeaderField: authHeader) == nil)
            #expect(request.value(forHTTPHeaderField: cookieHeader) == nil)
            #expect(request.httpShouldHandleCookies == false)

            let data = try JSONSerialization.data(withJSONObject: [:])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let resolver = YTMusicAPIKeyResolver(session: session, environment: { name in
            name == YTMusicAPIKeyResolver.environmentVariable ? "mock-token" : nil
        })
        let client = YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            apiKeyResolver:
            resolver
        )
        let response = try await client.search(query: "swift")

        #expect(response.songs.isEmpty)
        #expect(apiRequestCount == 1)
    }

    @Test("YouTube Music private requests fail before network when logged out")
    @MainActor
    func youTubeMusicPrivateRequestsFailBeforeNetworkWhenLoggedOut() async throws {
        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()

        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.setRequestHandler(for: session) { request in
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{}"#.utf8))
        }
        defer { MockURLProtocol.reset(session: session) }

        let resolver = YTMusicAPIKeyResolver(session: session, environment: { name in
            name == YTMusicAPIKeyResolver.environmentVariable ? "mock-token" : nil
        })
        let client = YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            apiKeyResolver:
            resolver
        )

        await #expect(throws: YTMusicError.self) {
            try await client.rateSong(videoId: "video", rating: .like)
        }
        #expect(requestCount == 0)
    }

    @Test("YouTube public requests omit auth headers in logged-in guest mode")
    @MainActor
    func youTubePublicRequestsOmitAuthHeadersInLoggedInGuestMode() async throws {
        APICache.shared.invalidateAll()
        let webKitManager = MockWebKitManager()
        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "test-sapisid")
        authService.enterGuestMode()

        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var apiRequestCount = 0
        MockURLProtocol.setRequestHandler(for: session) { request in
            apiRequestCount += 1
            #expect(request.url?.host == "www.youtube.com")
            let authHeader = ["Author", "ization"].joined()
            let cookieHeader = ["Coo", "kie"].joined()
            #expect(request.value(forHTTPHeaderField: authHeader) == nil)
            #expect(request.value(forHTTPHeaderField: cookieHeader) == nil)
            #expect(request.httpShouldHandleCookies == false)

            let data = try JSONSerialization.data(withJSONObject: [:])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = YouTubeClient(authService: authService, session: session)
        let response = try await client.search(query: "swift", filter: .all)

        #expect(response.videos.isEmpty)
        #expect(apiRequestCount == 1)
    }

    @Test("YouTube private requests fail before network in logged-in guest mode")
    @MainActor
    func youTubePrivateRequestsFailBeforeNetworkInLoggedInGuestMode() async throws {
        let webKitManager = MockWebKitManager()
        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "test-sapisid")
        authService.enterGuestMode()

        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.setRequestHandler(for: session) { request in
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{}"#.utf8))
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = YouTubeClient(authService: authService, session: session)

        await #expect(throws: YTMusicError.self) {
            _ = try await client.getUserPlaylists()
        }
        #expect(requestCount == 0)
    }

    @Test("YouTube Music filtered search and continuation remain public in logged-in guest mode")
    @MainActor
    func youTubeMusicFilteredSearchRemainsPublicInLoggedInGuestMode() async throws {
        APICache.shared.invalidateAll()
        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "test-sapisid")
        authService.enterGuestMode()

        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var apiRequestCount = 0
        MockURLProtocol.setRequestHandler(for: session) { request in
            apiRequestCount += 1
            #expect(request.url?.host == "music.youtube.com")
            #expect(request.url?.path == "/youtubei/v1/search")
            let authHeader = ["Author", "ization"].joined()
            let cookieHeader = ["Coo", "kie"].joined()
            #expect(request.value(forHTTPHeaderField: authHeader) == nil)
            #expect(request.value(forHTTPHeaderField: cookieHeader) == nil)
            #expect(request.httpShouldHandleCookies == false)

            let data = try JSONSerialization.data(withJSONObject: [:])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let resolver = YTMusicAPIKeyResolver(session: session, environment: { name in
            name == YTMusicAPIKeyResolver.environmentVariable ? "mock-token" : nil
        })
        let client = YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            apiKeyResolver: resolver
        )

        _ = try await client.searchVideos(query: "swift videos")
        _ = try await client.searchProfiles(query: "swift profiles")
        _ = try await client.searchEpisodes(query: "swift episodes")
        _ = try await client.getSearchContinuation(token: "guest-mode-search-continuation")

        #expect(apiRequestCount == 4)
    }

    @Test("YouTube Music public requests omit auth headers in logged-in guest mode")
    @MainActor
    func youTubeMusicPublicRequestsOmitAuthHeadersInLoggedInGuestMode() async throws {
        APICache.shared.invalidateAll()
        let webKitManager = WebKitManager.makeTestInstance()
        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "test-sapisid")
        authService.enterGuestMode()

        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var apiRequestCount = 0
        MockURLProtocol.setRequestHandler(for: session) { request in
            apiRequestCount += 1
            #expect(request.url?.host == "music.youtube.com")
            let authHeader = ["Author", "ization"].joined()
            let cookieHeader = ["Coo", "kie"].joined()
            #expect(request.value(forHTTPHeaderField: authHeader) == nil)
            #expect(request.value(forHTTPHeaderField: cookieHeader) == nil)
            #expect(request.httpShouldHandleCookies == false)

            let data = try JSONSerialization.data(withJSONObject: [:])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let resolver = YTMusicAPIKeyResolver(session: session, environment: { name in
            name == YTMusicAPIKeyResolver.environmentVariable ? "mock-token" : nil
        })
        let client = YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session,
            apiKeyResolver:
            resolver
        )
        let response = try await client.search(query: "swift")

        #expect(response.songs.isEmpty)
        #expect(apiRequestCount == 1)
    }
}
