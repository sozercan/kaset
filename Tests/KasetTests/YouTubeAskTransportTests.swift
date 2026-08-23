import Foundation
import Testing
@testable import Kaset

// MARK: - YouTubeAskTransportTests

@Suite("YouTube Ask transport", .serialized, .tags(.api))
struct YouTubeAskTransportTests {
    private static let maximumResponseBytes = 32 * 1024 * 1024

    @Test("Same-origin redirects are followed")
    func sameOriginRedirectIsFollowed() async throws {
        let requestCount = LockedCounter()
        AskTransportURLProtocol.setHandler { protocolInstance in
            let request = protocolInstance.request
            switch requestCount.increment() {
            case 1:
                guard let redirectURL = URL(
                    string: "https://www.youtube.com/youtubei/v1/get_panel?redirected=true"
                ) else {
                    Issue.record("Synthetic redirect URL could not be created")
                    return
                }
                AskTransportURLProtocol.redirect(
                    protocolInstance,
                    to: URLRequest(url: redirectURL)
                )
            case 2:
                #expect(request.url?.host == "www.youtube.com")
                #expect(request.url?.query == "redirected=true")
                AskTransportURLProtocol.respond(
                    protocolInstance,
                    data: Data(#"{}"#.utf8)
                )
            default:
                Issue.record("Same-origin redirect performed too many requests")
                AskTransportURLProtocol.fail(protocolInstance, with: URLError(.badServerResponse))
            }
        }
        defer { AskTransportURLProtocol.reset() }

        let response = try await self.makeTransport().send(self.makeRequest())

        #expect(response.statusCode == 200)
        #expect(response.data == Data(#"{}"#.utf8))
        #expect(requestCount.count == 2)
    }

    @Test("Cross-origin redirects are rejected")
    func crossOriginRedirectIsRejected() async {
        let requestCount = LockedCounter()
        AskTransportURLProtocol.setHandler { protocolInstance in
            _ = requestCount.increment()
            let redirectURL = URL(string: "https://example.invalid/blocked")
            guard let redirectURL else {
                Issue.record("Synthetic redirect URL could not be created")
                return
            }
            AskTransportURLProtocol.redirect(
                protocolInstance,
                to: URLRequest(url: redirectURL)
            )
        }
        defer { AskTransportURLProtocol.reset() }

        await #expect(throws: YouTubeAskTransportError.invalidResponse) {
            _ = try await self.makeTransport().send(self.makeRequest())
        }
        #expect(requestCount.count == 1)
    }

    @Test("Declared response sizes above the limit are rejected")
    func declaredResponseOverflowIsRejected() async {
        AskTransportURLProtocol.setHandler { protocolInstance in
            AskTransportURLProtocol.respond(
                protocolInstance,
                data: Data(),
                headers: [
                    "Content-Length": String(Self.maximumResponseBytes + 1),
                    "Content-Type": "application/json",
                ]
            )
        }
        defer { AskTransportURLProtocol.reset() }

        await #expect(throws: YouTubeAskTransportError.responseTooLarge) {
            _ = try await self.makeTransport().send(self.makeRequest())
        }
    }

    @Test("Streamed response sizes above the limit are rejected")
    func streamedResponseOverflowIsRejected() async {
        let chunk = Data(repeating: 0x61, count: 4 * 1024 * 1024)
        AskTransportURLProtocol.setHandler { protocolInstance in
            AskTransportURLProtocol.respond(
                protocolInstance,
                chunks: Array(repeating: chunk, count: 9),
                headers: ["Content-Type": "application/json"]
            )
        }
        defer { AskTransportURLProtocol.reset() }

        await #expect(throws: YouTubeAskTransportError.responseTooLarge) {
            _ = try await self.makeTransport().send(self.makeRequest())
        }
    }

    @Test("Non-HTTP responses are rejected as malformed")
    func nonHTTPResponseIsRejected() async {
        AskTransportURLProtocol.setHandler { protocolInstance in
            guard let url = protocolInstance.request.url else {
                Issue.record("Synthetic request had no URL")
                return
            }
            AskTransportURLProtocol.respond(
                protocolInstance,
                response: URLResponse(
                    url: url,
                    mimeType: "application/json",
                    expectedContentLength: 2,
                    textEncodingName: nil
                ),
                chunks: [Data(#"{}"#.utf8)]
            )
        }
        defer { AskTransportURLProtocol.reset() }

        await #expect(throws: YouTubeAskTransportError.invalidResponse) {
            _ = try await self.makeTransport().send(self.makeRequest())
        }
    }

    @Test("Malformed transport responses map to the Ask presentation error")
    @MainActor
    func malformedTransportResponseMapsToClientError() async throws {
        let requestCount = LockedCounter()
        AskTransportURLProtocol.setHandler { protocolInstance in
            let request = protocolInstance.request
            switch requestCount.increment() {
            case 1:
                AskTransportURLProtocol.respond(
                    protocolInstance,
                    data: Self.panelOnlyNextData
                )
            case 2:
                guard let url = request.url else {
                    Issue.record("Synthetic panel request had no URL")
                    return
                }
                AskTransportURLProtocol.respond(
                    protocolInstance,
                    response: URLResponse(
                        url: url,
                        mimeType: "application/json",
                        expectedContentLength: 2,
                        textEncodingName: nil
                    ),
                    chunks: [Data(#"{}"#.utf8)]
                )
            default:
                Issue.record("Malformed transport response retried unexpectedly")
                AskTransportURLProtocol.fail(protocolInstance, with: URLError(.badServerResponse))
            }
        }
        defer { AskTransportURLProtocol.reset() }

        let client = try await self.makeAuthenticatedClient()
        let page = try await client.getWatchPage(videoId: "fixture-video")

        await #expect(throws: YouTubeAskClientError.invalidResponse) {
            _ = try await client.loadAskConversation(from: #require(page.askBootstrap))
        }
        #expect(requestCount.count == 2)
    }

    private func makeTransport() -> YouTubeAskTransport {
        YouTubeAskTransport(configuration: self.makeConfiguration())
    }

    private func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AskTransportURLProtocol.self]
        return configuration
    }

    private func makeRequest() -> URLRequest {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/get_panel") else {
            preconditionFailure("Synthetic Ask URL could not be created")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{}"#.utf8)
        return request
    }

    @MainActor
    private func makeAuthenticatedClient() async throws -> YouTubeClient {
        let webKitManager = WebKitManager.makeTestInstance()
        let authCookie = try #require(HTTPCookie(properties: [
            .name: "__Secure-3PAPISID",
            .value: "mock-token",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        await webKitManager.dataStore.httpCookieStore.setCookie(authCookie)
        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "mock-token")
        let client = YouTubeClient(
            authService: authService,
            webKitManager: webKitManager,
            session: URLSession(configuration: self.makeConfiguration()),
            askFeatureEnabled: true
        )
        client.askAccountBindingProvider = {
            YouTubeAskAccountBinding(scopeID: "fixture-primary-scope")
        }
        return client
    }

    private static let panelOnlyNextData = Data(
        #"""
        {
          "contents": {},
          "engagementPanels": [
            {
              "engagementPanelSectionListRenderer": {
                "panelIdentifier": "PAyouchat",
                "continuationEndpoint": {
                  "continuationCommand": {
                    "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                    "token": "fixture-panel-continuation"
                  }
                }
              }
            }
          ]
        }
        """#.utf8
    )
}

// MARK: - AskTransportURLProtocol

private final class AskTransportURLProtocol: URLProtocol {
    typealias Handler = (AskTransportURLProtocol) -> Void

    private static let lock = NSLock()
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var handler: Handler?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            Self.fail(self, with: URLError(.resourceUnavailable))
            return
        }
        handler(self)
    }

    override func stopLoading() {}

    static func setHandler(_ handler: @escaping Handler) {
        self.lock.withLock {
            self.handler = handler
        }
    }

    static func reset() {
        self.lock.withLock {
            self.handler = nil
        }
    }

    static func respond(
        _ protocolInstance: AskTransportURLProtocol,
        data: Data,
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) {
        self.respond(
            protocolInstance,
            chunks: [data],
            statusCode: statusCode,
            headers: headers
        )
    }

    static func respond(
        _ protocolInstance: AskTransportURLProtocol,
        chunks: [Data],
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) {
        guard let url = protocolInstance.request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: nil,
                  headerFields: headers
              )
        else {
            self.fail(protocolInstance, with: URLError(.badServerResponse))
            return
        }
        self.respond(protocolInstance, response: response, chunks: chunks)
    }

    static func respond(
        _ protocolInstance: AskTransportURLProtocol,
        response: URLResponse,
        chunks: [Data]
    ) {
        protocolInstance.client?.urlProtocol(
            protocolInstance,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        for chunk in chunks {
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: chunk)
        }
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }

    static func redirect(
        _ protocolInstance: AskTransportURLProtocol,
        to request: URLRequest
    ) {
        guard let originalURL = protocolInstance.request.url,
              let response = HTTPURLResponse(
                  url: originalURL,
                  statusCode: 302,
                  httpVersion: nil,
                  headerFields: ["Location": request.url?.absoluteString ?? ""]
              )
        else {
            self.fail(protocolInstance, with: URLError(.badServerResponse))
            return
        }
        protocolInstance.client?.urlProtocol(
            protocolInstance,
            wasRedirectedTo: request,
            redirectResponse: response
        )
    }

    static func fail(
        _ protocolInstance: AskTransportURLProtocol,
        with error: any Error
    ) {
        protocolInstance.client?.urlProtocol(protocolInstance, didFailWithError: error)
    }
}
