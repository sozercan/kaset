import Foundation
import Testing
@testable import Kaset

// MARK: - YouTubeAskClientTests

@Suite("YouTube Ask client", .serialized, .tags(.api))
struct YouTubeAskClientTests {
    @Test("Watch page reuses one next request and exposes strict direct chips")
    @MainActor
    func watchPageReusesNextRequest() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            #expect(requestCount.increment() == 1)
            #expect(request.url?.path == "/youtubei/v1/next")
            #expect(request.url?.query?.contains("key=") != true)
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            #expect(authorization?.hasPrefix("SAPISIDHASH ") == true)
            #expect(authorization?.contains("SAPISID1PHASH") != true)
            #expect(authorization?.contains("SAPISID3PHASH") != true)
            let body = try Self.body(from: request)
            #expect(body["videoId"] as? String == "fixture-video")
            let context = try #require(body["context"] as? [String: Any])
            let client = try #require(context["client"] as? [String: Any])
            #expect(client["clientVersion"] as? String == "2.20260611.01.00")
            #expect(client["visitorData"] == nil)

            return Self.response(for: request, data: Self.eligibleNextData)
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")

        #expect(requestCount.count == 1)
        let bootstrap = try #require(page.askBootstrap)
        #expect(bootstrap.suggestions.map(\.text) == [
            "Explain the main idea",
            "Résumer les points clés",
        ])

        let conversation = try await client.loadAskConversation(from: bootstrap)
        #expect(requestCount.count == 1)
        #expect(conversation.messages.isEmpty)
        #expect(conversation.suggestions.map(\.text) == bootstrap.suggestions.map(\.text))
    }

    @Test("Production Ask domain state has redacted descriptions and reflection")
    @MainActor
    func productionAskDomainStateIsRedacted() async throws {
        let session = MockURLProtocol.makeMockSession { request in
            Self.response(for: request, data: Self.eligibleNextData)
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let bootstrap = try #require(page.askBootstrap)
        let conversation = try await client.loadAskConversation(from: bootstrap)
        let accountBinding = YouTubeAskAccountBinding(scopeID: "fixture-primary-scope")
        let requestSnapshot = try await client.makeAskRequestSnapshot(videoID: "fixture-video")
        let httpResponse = YouTubeAskHTTPResponse(data: Data(#"{}"#.utf8), statusCode: 200)

        #expect(String(describing: bootstrap) == "<redacted YouTube Ask bootstrap>")
        #expect(String(reflecting: bootstrap) == "<redacted YouTube Ask bootstrap>")
        #expect(String(describing: conversation) == "<redacted YouTube Ask conversation>")
        #expect(String(reflecting: conversation) == "<redacted YouTube Ask conversation>")
        #expect(String(describing: accountBinding) == "<redacted YouTube Ask account binding>")
        #expect(String(reflecting: accountBinding) == "<redacted YouTube Ask account binding>")
        #expect(String(describing: requestSnapshot) == "<redacted YouTube Ask request snapshot>")
        #expect(String(reflecting: requestSnapshot) == "<redacted YouTube Ask request snapshot>")
        #expect(String(describing: httpResponse) == "<redacted YouTube Ask HTTP response>")
        #expect(String(reflecting: httpResponse) == "<redacted YouTube Ask HTTP response>")
    }

    @Test("Panel materialization posts only continuation plus request context")
    @MainActor
    func materializationRequestShape() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.panelOnlyNextData)
            case 2:
                #expect(request.url?.path == "/youtubei/v1/get_panel")
                #expect(request.url?.query?.contains("key=") != true)
                #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
                let body = try Self.body(from: request)
                #expect(Set(body.keys) == ["context", "continuation"])
                #expect(body["continuation"] as? String == "fixture-panel-continuation")
                #expect(body["formData"] == nil)
                return Self.response(for: request, data: Self.initialPanelData)
            default:
                Issue.record("Ask panel materialization retried unexpectedly")
                return Self.response(for: request, data: Data(#"{}"#.utf8))
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let conversation = try await client.loadAskConversation(
            from: #require(page.askBootstrap)
        )

        #expect(requestCount.count == 2)
        #expect(conversation.suggestions.map(\.text) == ["Ask a follow-up"])
    }

    @Test("Direct chips send exact fields and monotonic message IDs")
    @MainActor
    func directChipRequestShapeAndMessageIDs() async throws {
        let requestCount = LockedCounter()
        let messageIDs = LockedValues<String>()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.eligibleNextData)
            case 2, 3:
                let body = try Self.body(from: request)
                #expect(Set(body.keys) == ["context", "continuation", "formData"])
                #expect(body["userInputText"] == nil)
                #expect(body["clickTrackingParams"] == nil)
                #expect(body["conversationId"] == nil)
                let formData = try #require(body["formData"] as? [String: Any])
                let composer = try #require(formData["inputComposerFormData"] as? [String: Any])
                try messageIDs.append(#require(composer["clientMessageId"] as? String))
                return Self.response(for: request, data: Self.mutationConversationData)
            default:
                Issue.record("Direct chip request retried unexpectedly")
                return Self.response(for: request, data: Data(#"{}"#.utf8))
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let generator = YouTubeAskMessageIDGenerator(nowMilliseconds: { 1000 })
        let (client, _) = try await Self.makeAuthenticatedClient(
            session: session,
            messageIDGenerator: generator
        )
        let page = try await client.getWatchPage(videoId: "fixture-video")
        var conversation = try await client.loadAskConversation(
            from: #require(page.askBootstrap)
        )

        let firstID = try #require(conversation.suggestions.first?.id)
        let consumedConversation = try #require(conversation.appendingUserTurn(for: firstID))
        conversation = try await client.continueAskConversation(
            consumedConversation,
            selecting: firstID
        )
        await #expect(throws: CancellationError.self) {
            _ = try await client.continueAskConversation(
                consumedConversation,
                selecting: firstID
            )
        }

        let secondID = try #require(conversation.suggestions.first?.id)
        conversation = try #require(conversation.appendingUserTurn(for: secondID))
        _ = try await client.continueAskConversation(
            conversation,
            selecting: secondID
        )

        #expect(messageIDs.values == ["youchat-1000", "youchat-1001"])
        #expect(requestCount.count == 3)
    }

    @Test("One chip prevents sibling reuse from the same revision")
    @MainActor
    func oneChipPreventsSiblingReuse() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.eligibleNextData)
            case 2:
                return Self.response(for: request, data: Self.conversationData)
            default:
                Issue.record("A sibling chip reused an already-consumed revision")
                return Self.response(for: request, data: Self.conversationData)
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let conversation = try await client.loadAskConversation(
            from: #require(page.askBootstrap)
        )
        let firstID = try #require(conversation.suggestions.first?.id)
        let secondID = try #require(conversation.suggestions.dropFirst().first?.id)
        let firstTurn = try #require(conversation.appendingUserTurn(for: firstID))
        let secondTurn = try #require(conversation.appendingUserTurn(for: secondID))

        _ = try await client.continueAskConversation(firstTurn, selecting: firstID)
        await #expect(throws: CancellationError.self) {
            _ = try await client.continueAskConversation(secondTurn, selecting: secondID)
        }
        #expect(requestCount.count == 2)
    }

    @Test("The visible user turn must match the submitted suggestion command")
    @MainActor
    func visibleTurnMustMatchSubmittedSuggestion() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.eligibleNextData)
            case 2:
                return Self.response(for: request, data: Self.conversationData)
            default:
                Issue.record("A mismatched suggestion triggered an unexpected request")
                return Self.response(for: request, data: Self.conversationData)
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let conversation = try await client.loadAskConversation(
            from: #require(page.askBootstrap)
        )
        let firstID = try #require(conversation.suggestions.first?.id)
        let secondID = try #require(conversation.suggestions.dropFirst().first?.id)
        let firstTurn = try #require(conversation.appendingUserTurn(for: firstID))

        await #expect(throws: CancellationError.self) {
            _ = try await client.continueAskConversation(firstTurn, selecting: secondID)
        }
        #expect(requestCount.count == 1)

        _ = try await client.continueAskConversation(firstTurn, selecting: firstID)
        #expect(requestCount.count == 2)
    }

    @Test("Concurrent sibling chips cannot fork one revision")
    @MainActor
    func concurrentSiblingChipsCannotForkRevision() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.eligibleNextData)
            case 2, 3:
                return Self.response(for: request, data: Self.conversationData)
            default:
                Issue.record("Ask request retried unexpectedly")
                return Self.response(for: request, data: Self.conversationData)
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let conversation = try await client.loadAskConversation(
            from: #require(page.askBootstrap)
        )
        let firstID = try #require(conversation.suggestions.first?.id)
        let secondID = try #require(conversation.suggestions.dropFirst().first?.id)
        let firstTurn = try #require(conversation.appendingUserTurn(for: firstID))
        let secondTurn = try #require(conversation.appendingUserTurn(for: secondID))

        let firstRequest = Task {
            do {
                _ = try await client.continueAskConversation(firstTurn, selecting: firstID)
                return true
            } catch is CancellationError {
                return false
            } catch {
                Issue.record("Unexpected first-chip failure: \(error)")
                return false
            }
        }
        let secondRequest = Task {
            do {
                _ = try await client.continueAskConversation(secondTurn, selecting: secondID)
                return true
            } catch is CancellationError {
                return false
            } catch {
                Issue.record("Unexpected second-chip failure: \(error)")
                return false
            }
        }

        let outcomes = await [firstRequest.value, secondRequest.value]
        #expect(outcomes.filter(\.self).count == 1)
        #expect(requestCount.count == 2)
    }

    @Test("Watch bootstrap is canceled when account scope changes during parsing")
    @MainActor
    func watchBootstrapRevalidatesAccountAfterParsing() async throws {
        let session = MockURLProtocol.makeMockSession { request in
            Self.response(for: request, data: Self.eligibleNextData)
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let bindingChecks = LockedCounter()
        client.askAccountBindingProvider = {
            let scopeID = bindingChecks.increment() <= 2
                ? "fixture-primary-scope"
                : "fixture-replacement-scope"
            return YouTubeAskAccountBinding(scopeID: scopeID)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await client.getWatchPage(videoId: "fixture-video")
        }
        #expect(bindingChecks.count == 3)
    }

    @Test("Conversation response is canceled when authentication changes during parsing")
    @MainActor
    func conversationRevalidatesAuthenticationAfterParsing() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.eligibleNextData)
            case 2:
                return Self.response(for: request, data: Self.conversationData)
            default:
                Issue.record("Ask request retried unexpectedly")
                return Self.response(for: request, data: Self.conversationData)
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, authService) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let conversation = try await client.loadAskConversation(
            from: #require(page.askBootstrap)
        )
        let selectedID = try #require(conversation.suggestions.first?.id)
        let selectedTurn = try #require(conversation.appendingUserTurn(for: selectedID))

        let bindingChecks = LockedCounter()
        client.askAccountBindingProvider = {
            if bindingChecks.increment() == 4 {
                authService.sessionExpired()
            }
            return YouTubeAskAccountBinding(scopeID: "fixture-primary-scope")
        }

        await #expect(throws: CancellationError.self) {
            _ = try await client.continueAskConversation(selectedTurn, selecting: selectedID)
        }
        #expect(bindingChecks.count == 4)
        #expect(requestCount.count == 2)
    }

    @Test("Panel rate limits are mapped without retry")
    @MainActor
    func rateLimitDoesNotRetry() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.panelOnlyNextData)
            case 2:
                return Self.response(for: request, data: Data(#"{}"#.utf8), statusCode: 429)
            default:
                Issue.record("Rate-limited Ask request retried unexpectedly")
                return Self.response(for: request, data: Data(#"{}"#.utf8), statusCode: 429)
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")

        await #expect(throws: YouTubeAskClientError.rateLimited) {
            _ = try await client.loadAskConversation(
                from: #require(page.askBootstrap)
            )
        }
        #expect(requestCount.count == 2)
    }

    @Test("Panel authentication failures throw shared auth expiry and invalidate the matching session", arguments: [401, 403])
    @MainActor
    func authenticationFailureMapping(statusCode: Int) async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.panelOnlyNextData)
            case 2:
                return Self.response(for: request, data: Data(#"{}"#.utf8), statusCode: statusCode)
            default:
                Issue.record("Authentication failure retried unexpectedly")
                return Self.response(for: request, data: Data(#"{}"#.utf8), statusCode: statusCode)
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, authService) = try await Self.makeAuthenticatedClient(session: session)
        let identityGeneration = authService.accountIdentityGeneration
        let page = try await client.getWatchPage(videoId: "fixture-video")

        do {
            _ = try await client.loadAskConversation(from: #require(page.askBootstrap))
            Issue.record("Expected YTMusicError.authExpired")
        } catch YTMusicError.authExpired {
            // Expected shared authentication-expiry contract.
        } catch {
            Issue.record("Expected YTMusicError.authExpired, got \(type(of: error))")
        }

        #expect(requestCount.count == 2)
        #expect(!authService.hasPersonalAccount)
        #expect(authService.accountIdentityGeneration == identityGeneration &+ 1)
    }

    @Test("Malformed successful panel responses fail without retry")
    @MainActor
    func malformedPanelResponseMapping() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.panelOnlyNextData)
            case 2:
                return Self.response(for: request, data: Data(#"{}"#.utf8))
            default:
                Issue.record("Malformed panel response retried unexpectedly")
                return Self.response(for: request, data: Data(#"{}"#.utf8))
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")

        await #expect(throws: YouTubeAskClientError.invalidResponse) {
            _ = try await client.loadAskConversation(from: #require(page.askBootstrap))
        }
        #expect(requestCount.count == 2)
    }

    @Test("Panel network failures map to unavailable without retry")
    @MainActor
    func panelNetworkFailureMapping() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.panelOnlyNextData)
            case 2:
                throw URLError(.timedOut)
            default:
                Issue.record("Panel network failure retried unexpectedly")
                throw URLError(.timedOut)
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")

        await #expect(throws: YouTubeAskClientError.unavailable) {
            _ = try await client.loadAskConversation(from: #require(page.askBootstrap))
        }
        #expect(requestCount.count == 2)
    }

    @Test("Signed-out and reset sessions reject old Ask state before sending")
    @MainActor
    func staleSessionStateIsRejectedBeforeSending() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            #expect(requestCount.increment() == 1)
            return Self.response(for: request, data: Self.eligibleNextData)
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, authService) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let bootstrap = try #require(page.askBootstrap)
        let conversation = try await client.loadAskConversation(from: bootstrap)
        let suggestionID = try #require(conversation.suggestions.first?.id)
        let pendingConversation = try #require(conversation.appendingUserTurn(for: suggestionID))

        client.resetSessionStateForAccountSwitch()

        await #expect(throws: CancellationError.self) {
            _ = try await client.loadAskConversation(from: bootstrap)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await client.continueAskConversation(
                pendingConversation,
                selecting: suggestionID
            )
        }
        #expect(requestCount.count == 1)

        authService.sessionExpired()
        await #expect(throws: YouTubeAskClientError.authenticationRequired) {
            _ = try await client.loadAskConversation(from: bootstrap)
        }
        #expect(requestCount.count == 1)
    }

    @Test("Client default remains disabled without explicit opt-in")
    @MainActor
    func clientDefaultRemainsDisabled() async throws {
        let session = MockURLProtocol.makeMockSession { request in
            Self.response(for: request, data: Self.eligibleNextData)
        }
        defer { MockURLProtocol.reset(session: session) }

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
            session: session
        )
        client.askAccountBindingProvider = {
            YouTubeAskAccountBinding(scopeID: "fixture-primary-scope")
        }

        let page = try await client.getWatchPage(videoId: "fixture-video")
        #expect(page.askBootstrap == nil)
    }

    @Test("Production app explicitly enables Ask Gemini")
    func productionAppExplicitlyEnablesAsk() throws {
        let sourcePath = #filePath.replacingOccurrences(
            of: "Tests/KasetTests/YouTubeAskClientTests.swift",
            with: "Sources/Kaset/KasetApp.swift"
        )
        let source = try String(contentsOfFile: sourcePath, encoding: .utf8)

        #expect(source.contains("askFeatureEnabled: true"))
    }

    @Test("Unresolved and unsupported account states omit Ask")
    @MainActor
    func unresolvedAccountOmitsAsk() async throws {
        let session = MockURLProtocol.makeMockSession { request in
            Self.response(for: request, data: Self.eligibleNextData)
        }
        defer { MockURLProtocol.reset(session: session) }

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
            session: session,
            askFeatureEnabled: true
        )

        let page = try await client.getWatchPage(videoId: "fixture-video")
        #expect(page.askBootstrap == nil)
    }

    @MainActor
    static func makeAuthenticatedClient(
        session: URLSession,
        messageIDGenerator: YouTubeAskMessageIDGenerator? = nil
    ) async throws -> (YouTubeClient, AuthService) {
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
            session: session,
            askMessageIDGenerator: messageIDGenerator,
            askFeatureEnabled: true
        )
        client.askAccountBindingProvider = {
            YouTubeAskAccountBinding(scopeID: "fixture-primary-scope")
        }
        return (client, authService)
    }

    static func body(from request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let httpBody = request.httpBody {
            data = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { break }
                if count == 0 {
                    break
                }
                result.append(buffer, count: count)
            }
            data = result
        } else {
            throw YouTubeAskClientError.invalidResponse
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func response(
        for request: URLRequest,
        data: Data,
        statusCode: Int = 200
    ) -> (HTTPURLResponse, Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            preconditionFailure("Synthetic HTTP response could not be created")
        }
        return (response, data)
    }

    static let eligibleNextData = Data(
        #"""
        {
          "contents": {},
          "engagementPanels": [
            {
              "engagementPanelSectionListRenderer": {
                "panelIdentifier": "PAyouchat",
                "content": {
                  "youChatItemViewModel": {
                    "chipsData": {
                      "chipData": [
                        {
                          "text": {"simpleText": "Explain the main idea"},
                          "continuation": "fixture-chip-a"
                        },
                        {
                          "text": {"simpleText": "Résumer les points clés"},
                          "continuation": "fixture-chip-b"
                        }
                      ]
                    },
                    "sendUserQueryCommand": {
                      "innertubeCommand": {
                        "clickTrackingParams": "fixture-free-text-click-tracking",
                        "continuationCommand": {
                          "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                          "token": "fixture-free-text-continuation"
                        }
                      }
                    }
                  }
                }
              }
            }
          ]
        }
        """#.utf8
    )

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

    private static let initialPanelData = Data(
        #"""
        {
          "onResponseReceivedCommands": [
            {
              "appendContinuationItemsAction": {
                "continuationItems": [
                  {
                    "youChatItemViewModel": {
                      "chipsData": {
                        "chipData": [
                          {
                            "text": {"simpleText": "Ask a follow-up"},
                            "continuation": "fixture-follow-up"
                          }
                        ]
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
        """#.utf8
    )

    private static let conversationData = Data(
        #"""
        {
          "onResponseReceivedCommands": [
            {
              "appendContinuationItemsAction": {
                "continuationItems": [
                  {
                    "youChatTextMessageViewModel": {
                      "text": {"content": "A synthetic assistant response."}
                    }
                  },
                  {
                    "youChatItemViewModel": {
                      "chipsData": {
                        "chipData": [
                          {
                            "text": {"simpleText": "Continue"},
                            "continuation": "fixture-next-chip"
                          }
                        ]
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
        """#.utf8
    )
}

// MARK: - LockedValues

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        self.lock.withLock {
            self.storage.append(value)
        }
    }

    var values: [Value] {
        self.lock.withLock { self.storage }
    }
}
