import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.api))
struct GuestModeAPIClientTests {
    @Test("YouTube public requests omit auth headers when logged out")
    @MainActor
    func youTubePublicRequestsOmitAuthHeadersWhenLoggedOut() async throws {
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
}
