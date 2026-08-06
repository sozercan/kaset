import Foundation
import Testing
@testable import YouTubeAskCore

@Suite("YouTube Ask watch footer command")
struct YouTubeAskWatchFooterCommandTests {
    @Test("Extracts the live footer chat-input command from an eligible watch panel")
    func watchPanelFooterChatInputCommand() throws {
        let envelope = try YouTubeAskWireDecoder.decode(Data(
            #"""
            {
              "engagementPanels": [
                {
                  "engagementPanelSectionListRenderer": {
                    "panelIdentifier": "PAyouchat",
                    "content": {
                      "youChatItemViewModel": {
                        "chipsData": {
                          "chipData": [
                            {
                              "text": {"simpleText": "Summarize the video"},
                              "continuation": "fixture-summary-chip"
                            },
                            {
                              "text": {"simpleText": "Recommend related content"},
                              "continuation": "fixture-related-chip"
                            }
                          ]
                        }
                      }
                    },
                    "footer": {
                      "chatInputViewModel": {
                        "sendUserQueryCommand": {
                          "innertubeCommand": {
                            "clickTrackingParams": "fixture-footer-click",
                            "continuationCommand": {
                              "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                              "token": "fixture-footer-free-text"
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
        ))

        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let bootstrap = try #require(parsedBootstrap)

        #expect(bootstrap.panelCommand == nil)
        #expect(bootstrap.suggestions.map(\.label) == [
            "Summarize the video",
            "Recommend related content",
        ])
        #expect(bootstrap.freeTextCommand?.continuation == "fixture-footer-free-text")
        #expect(bootstrap.freeTextCommand?.clickTrackingParams == "fixture-footer-click")
    }
}
