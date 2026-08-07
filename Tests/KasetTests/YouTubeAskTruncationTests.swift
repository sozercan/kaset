import Foundation
import Testing
@testable import Kaset

@Suite("YouTube Ask truncation", .serialized)
struct YouTubeAskTruncationTests {
    @Test("Materialized messages preserve parser truncation state")
    @MainActor
    func materializedMessagesPreserveTruncation() async throws {
        let requestCount = LockedCounter()
        let responseData = try Self.conversationData(answerCharacterCount: 16001)
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return YouTubeAskClientTests.response(for: request, data: Self.panelOnlyNextData)
            case 2:
                return YouTubeAskClientTests.response(for: request, data: responseData)
            default:
                Issue.record("Truncated materialization retried unexpectedly")
                return YouTubeAskClientTests.response(for: request, data: Data(#"{}"#.utf8))
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await YouTubeAskClientTests.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let conversation = try await client.loadAskConversation(from: #require(page.askBootstrap))

        #expect(requestCount.count == 2)
        #expect(conversation.messages.count == 1)
        let message = try #require(conversation.messages.first)
        #expect(message.text.count == 16000)
        #expect(message.wasTruncated)
    }

    @Test("Continued messages preserve parser truncation state")
    @MainActor
    func continuedMessagesPreserveTruncation() async throws {
        let requestCount = LockedCounter()
        let responseData = try Self.conversationData(answerCharacterCount: 16001)
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return YouTubeAskClientTests.response(for: request, data: YouTubeAskClientTests.eligibleNextData)
            case 2:
                return YouTubeAskClientTests.response(for: request, data: responseData)
            default:
                Issue.record("Truncated continuation retried unexpectedly")
                return YouTubeAskClientTests.response(for: request, data: Data(#"{}"#.utf8))
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await YouTubeAskClientTests.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let bootstrap = try #require(page.askBootstrap)
        let conversation = try await client.loadAskConversation(from: bootstrap)
        let suggestionID = try #require(conversation.suggestions.first?.id)
        let pending = try #require(conversation.appendingUserTurn(for: suggestionID))
        let continued = try await client.continueAskConversation(pending, selecting: suggestionID)

        #expect(requestCount.count == 2)
        #expect(continued.messages.count == 2)
        let message = try #require(continued.messages.last)
        #expect(message.role == .assistant)
        #expect(message.text.count == 16000)
        #expect(message.wasTruncated)
    }

    @Test("Truncation marker is visible in accessibility text")
    func truncationMarkerIsVisibleInAccessibilityText() {
        #expect(YouTubeAskMarkdown.plainText(from: "**Bounded answer**") == "Bounded answer")
        #expect(YouTubeAskMarkdown.plainText(
            from: "**Bounded answer**",
            wasTruncated: true
        ) == "Bounded answer…")
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

    private static func conversationData(answerCharacterCount: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "onResponseReceivedCommands": [
                [
                    "appendContinuationItemsAction": [
                        "continuationItems": [
                            [
                                "youChatTextMessageViewModel": [
                                    "text": [
                                        "content": String(repeating: "A", count: answerCharacterCount),
                                    ],
                                ],
                            ],
                            [
                                "youChatItemViewModel": [
                                    "sendUserQueryCommand": [
                                        "innertubeCommand": [
                                            "clickTrackingParams": "fixture-free-text-click-tracking",
                                            "continuationCommand": [
                                                "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                                                "token": "fixture-free-text-continuation",
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
    }
}
