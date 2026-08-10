import Foundation

extension YouTubeAskClientTests {
    static let mutationConversationData = Data(
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
                            "chatResponseStyle": "CHAT_RESPONSE_STYLE_DEFAULT",
                            "text": {
                              "content": "A synthetic assistant response.",
                              "styleRuns": [
                                {
                                  "startIndex": 0,
                                  "length": 9,
                                  "weightLabel": "FONT_WEIGHT_MEDIUM"
                                }
                              ]
                            },
                            "transparentBackground": true
                          }
                        },
                        {
                          "youChatItemViewModel": {
                            "chipsData": {
                              "chipData": [
                                {
                                  "text": {"content": "Continue"},
                                  "continuation": "fixture-next-chip"
                                }
                              ]
                            }
                          }
                        }
                      ],
                      "insertByPositionInSection": {
                        "position": "INSERTION_POSITION_LAST",
                        "sectionTargetId": "fixture-response-section"
                      }
                    }
                  }
                ]
              }
            }
          },
          "frameworkUpdates": {
            "entityBatchUpdate": {"mutations": []}
          }
        }
        """#.utf8
    )
}
