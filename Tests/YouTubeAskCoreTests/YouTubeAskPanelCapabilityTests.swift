import Foundation
import Testing
@testable import YouTubeAskCore

@Suite("YouTube Ask materialized capabilities")
struct YouTubeAskPanelCapabilityTests {
    @Test("Extracts free text only from confirmed legacy panel items")
    func legacyPanelFreeTextCommand() throws {
        let envelope = try Self.envelope(
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
                              "clickTrackingParams": "fixture-panel-click",
                              "continuationCommand": {
                                "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                                "token": "fixture-panel-free-text"
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
            """#
        )

        let conversation = try YouTubeAskParser.parseConversation(from: envelope)

        #expect(conversation.freeTextCommand?.continuation == "fixture-panel-free-text")
        #expect(conversation.freeTextCommand?.clickTrackingParams == "fixture-panel-click")
    }

    @Test("Extracts free text from the confirmed singular list mutation")
    func mutationPanelFreeTextCommand() throws {
        let envelope = try Self.envelope(
            #"""
            {
              "onResponseReceivedCommand": {
                "listMutationCommand": {
                  "operations": {
                    "operations": [
                      {
                        "insertItemSectionContent": {
                          "contents": [
                            {
                              "youChatItemViewModel": {
                                "sendUserQueryCommand": {
                                  "innertubeCommand": {
                                    "clickTrackingParams": "fixture-mutation-click",
                                    "continuationCommand": {
                                      "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                                      "token": "fixture-mutation-free-text"
                                    }
                                  }
                                }
                              }
                            }
                          ],
                          "insertByPositionInSection": {
                            "position": "INSERTION_POSITION_LAST",
                            "sectionTargetId": "fixture-section"
                          }
                        }
                      }
                    ]
                  }
                }
              }
            }
            """#
        )

        let conversation = try YouTubeAskParser.parseConversation(from: envelope)

        #expect(conversation.freeTextCommand?.continuation == "fixture-mutation-free-text")
    }

    @Test("Rejects distinct materialized commands and ignores unconfirmed decoys")
    func ambiguityAndDecoyHandling() throws {
        let ambiguous = try Self.envelope(
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
                              "clickTrackingParams": "fixture-click-a",
                              "continuationCommand": {
                                "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                                "token": "fixture-command-a"
                              }
                            }
                          }
                        }
                      },
                      {
                        "youChatItemViewModel": {
                          "sendUserQueryCommand": {
                            "innertubeCommand": {
                              "clickTrackingParams": "fixture-click-b",
                              "continuationCommand": {
                                "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                                "token": "fixture-command-b"
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
            """#
        )
        expectYouTubeAskError(.ambiguousBootstrap) {
            _ = try YouTubeAskParser.parseConversation(from: ambiguous)
        }

        let decoy = try Self.envelope(
            #"""
            {
              "youChatItemViewModel": {
                "sendUserQueryCommand": {
                  "innertubeCommand": {
                    "clickTrackingParams": "fixture-decoy-click",
                    "continuationCommand": {
                      "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                      "token": "fixture-decoy-command"
                    }
                  }
                }
              }
            }
            """#
        )
        let conversation = try YouTubeAskParser.parseConversation(from: decoy)
        #expect(conversation.freeTextCommand == nil)
    }

    private static func envelope(_ json: String) throws -> YouTubeAskWireEnvelope {
        try YouTubeAskWireDecoder.decode(Data(json.utf8))
    }
}
