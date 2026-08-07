import Foundation
import Testing
@testable import Kaset

extension YouTubeAskClientTests {
    @Test("Direct preview chips materialize the missing free-text capability")
    @MainActor
    func directChipsMaterializeMissingFreeTextCapability() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.directChipsPanelNextData)
            case 2:
                #expect(request.url?.path == "/youtubei/v1/get_panel")
                let body = try Self.body(from: request)
                #expect(Set(body.keys) == ["context", "continuation"])
                #expect(body["continuation"] as? String == "fixture-panel-continuation")
                #expect(body["formData"] == nil)
                return Self.response(for: request, data: Self.initialPanelWithFreeTextData)
            default:
                Issue.record("Initial Ask panel materialization retried unexpectedly")
                return Self.response(for: request, data: Data(#"{}"#.utf8))
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let bootstrap = try #require(page.askBootstrap)
        #expect(bootstrap.suggestions.map(\.text) == ["Preview summary"])

        let conversation = try await client.loadAskConversation(from: bootstrap)

        #expect(requestCount.count == 2)
        #expect(conversation.canSubmitFreeText)
        #expect(conversation.messages.isEmpty)
        #expect(conversation.suggestions.map(\.text) == [
            "Summarize the video",
            "Recommend related content",
            "What is the main claim?",
        ])
    }

    @Test("Materialized free text preserves preview chips and welcome messages")
    @MainActor
    func materializedFreeTextPreservesPreviewContent() async throws {
        let requestCount = LockedCounter()
        let session = MockURLProtocol.makeMockSession { request in
            switch requestCount.increment() {
            case 1:
                return Self.response(for: request, data: Self.directChipsPanelNextData)
            case 2:
                return Self.response(for: request, data: Self.initialPanelFreeTextOnlyData)
            default:
                Issue.record("Initial Ask panel materialization retried unexpectedly")
                return Self.response(for: request, data: Data(#"{}"#.utf8))
            }
        }
        defer { MockURLProtocol.reset(session: session) }

        let (client, _) = try await Self.makeAuthenticatedClient(session: session)
        let page = try await client.getWatchPage(videoId: "fixture-video")
        let conversation = try await client.loadAskConversation(from: #require(page.askBootstrap))

        #expect(requestCount.count == 2)
        #expect(conversation.canSubmitFreeText)
        #expect(!conversation.hasStarted)
        #expect(conversation.messages.map(\.text) == ["Ask me anything about this video."])
        #expect(conversation.suggestions.map(\.text) == ["Preview summary"])
    }

    private static let directChipsPanelNextData = Data(
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
                },
                "content": {
                  "youChatItemViewModel": {
                    "chipsData": {
                      "chipData": [
                        {
                          "text": {"simpleText": "Preview summary"},
                          "continuation": "fixture-preview-chip"
                        }
                      ]
                    }
                  }
                }
              }
            }
          ]
        }
        """#.utf8
    )

    private static let initialPanelWithFreeTextData = Data(
        #"""
        {
          "onResponseReceivedCommands": [
            {
              "appendContinuationItemsAction": {
                "continuationItems": [
                  {
                    "youChatItemViewModel": {
                      "sendUserQueryCommand": {
                        "innertubeCommand": {
                          "clickTrackingParams": "fixture-panel-free-text-click",
                          "continuationCommand": {
                            "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                            "token": "fixture-panel-free-text-continuation"
                          }
                        }
                      },
                      "chipsData": {
                        "chipData": [
                          {
                            "text": {"simpleText": "Summarize the video"},
                            "continuation": "fixture-summary-chip"
                          },
                          {
                            "text": {"simpleText": "Recommend related content"},
                            "continuation": "fixture-related-chip"
                          },
                          {
                            "text": {"simpleText": "What is the main claim?"},
                            "continuation": "fixture-claim-chip"
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

    private static let initialPanelFreeTextOnlyData = Data(
        #"""
        {
          "onResponseReceivedCommands": [
            {
              "appendContinuationItemsAction": {
                "continuationItems": [
                  {
                    "youChatTextMessageViewModel": {
                      "text": {"content": "Ask me anything about this video."}
                    }
                  },
                  {
                    "youChatItemViewModel": {
                      "sendUserQueryCommand": {
                        "innertubeCommand": {
                          "clickTrackingParams": "fixture-panel-free-text-click",
                          "continuationCommand": {
                            "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                            "token": "fixture-panel-free-text-continuation"
                          }
                        }
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
