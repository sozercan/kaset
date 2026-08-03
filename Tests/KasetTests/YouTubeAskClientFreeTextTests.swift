import Foundation
import Testing
@testable import Kaset

extension YouTubeAskClientTests {
    @Test("Free text sends the browser-validated get_panel body and click context")
    @MainActor
    func freeTextRequestShape() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.eligibleNextData)
            case 2, 3:
                #expect(request.url?.path == "/youtubei/v1/get_panel")
                #expect(request.url?.query?.contains("key=") != true)
                let body = try Self.body(from: request)
                #expect(Set(body.keys) == ["context", "continuation", "formData"])
                #expect(body["continuation"] as? String == "fixture-free-text-continuation")

                let context = try #require(body["context"] as? [String: Any])
                let clickTracking = try #require(context["clickTracking"] as? [String: Any])
                #expect(Set(clickTracking.keys) == ["clickTrackingParams"])
                #expect(
                    clickTracking["clickTrackingParams"] as? String
                        == "fixture-free-text-click-tracking"
                )

                let formData = try #require(body["formData"] as? [String: Any])
                #expect(Set(formData.keys) == ["inputComposerFormData"])
                let composer = try #require(formData["inputComposerFormData"] as? [String: Any])
                #expect(Set(composer.keys) == ["clientMessageId", "playerOffsetMs", "userInputText"])
                let messageID = try #require(composer["clientMessageId"] as? String)
                if requestCount.count == 2 {
                    #expect(messageID == "youchat-1000")
                } else {
                    let sequence = Int(messageID.dropFirst("youchat-".count)) ?? 0
                    #expect(sequence > 1000)
                }
                let expectedOffset = requestCount.count == 2 ? "234000" : "235000"
                let expectedInput = requestCount.count == 2
                    ? "What is this video about?"
                    : "What should I know next?"
                #expect(composer["playerOffsetMs"] as? String == expectedOffset)
                #expect(composer["userInputText"] as? String == expectedInput)
                return Self.response(for: request, data: Self.mutationConversationData)
            default:
                Issue.record("Free-text Ask request retried unexpectedly")
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
        let conversation = try await client.loadAskConversation(
            from: #require(page.askBootstrap)
        )
        #expect(conversation.canSubmitFreeText)
        let pendingConversation = try #require(
            conversation.appendingUserTurn(text: "What is this video about?")
        )

        await #expect(throws: CancellationError.self) {
            _ = try await client.continueAskConversation(
                pendingConversation,
                submitting: "Answer a different question",
                playerOffsetMilliseconds: 234_000
            )
        }
        #expect(requestCount.count == 1)

        let continued = try await client.continueAskConversation(
            pendingConversation,
            submitting: "What is this video about?",
            playerOffsetMilliseconds: 234_000
        )

        await #expect(throws: CancellationError.self) {
            _ = try await client.continueAskConversation(
                pendingConversation,
                submitting: "What is this video about?",
                playerOffsetMilliseconds: 234_000
            )
        }
        #expect(requestCount.count == 2)
        #expect(continued.canSubmitFreeText)
        #expect(continued.messages.map(\.role).count == 2)

        let secondPending = try #require(
            continued.appendingUserTurn(text: "What should I know next?")
        )
        let secondContinued = try await client.continueAskConversation(
            secondPending,
            submitting: "What should I know next?",
            playerOffsetMilliseconds: 235_000
        )

        await #expect(throws: CancellationError.self) {
            _ = try await client.continueAskConversation(
                secondPending,
                submitting: "What should I know next?",
                playerOffsetMilliseconds: 235_000
            )
        }
        #expect(requestCount.count == 3)
        #expect(secondContinued.canSubmitFreeText)
        #expect(secondContinued.messages.map(\.role).count == 4)
    }
}
