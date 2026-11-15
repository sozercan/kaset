import Foundation
import Testing
@testable import Kaset

/// Reply params and mentions from the comments parser. The shapes follow a
/// captured replies page: top-level comments' reply dialogs have no editable
/// text, and replies' dialogs start with a linked mention of their author.
@Suite("YouTubeCommentsParser replies", .tags(.parser))
struct YouTubeCommentReplyParserTests {
    @Test("Reads reply params, and a reply's mention, from the toolbar surface")
    func readsReplyParamsAndMention() throws {
        func replyCommand(editableText: [String: Any]?) -> [String: Any] {
            var dialog: [String: Any] = [
                "placeholderText": ["runs": [["text": "Add a reply..."]]],
                "replyButton": [
                    "buttonRenderer": [
                        "serviceEndpoint": [
                            "createCommentReplyEndpoint": ["createReplyParams": "reply-params"],
                        ],
                    ],
                ],
            ]
            if let editableText {
                dialog["editableText"] = editableText
            }
            return [
                "innertubeCommand": [
                    "createCommentReplyDialogEndpoint": [
                        "dialog": ["commentReplyDialogRenderer": dialog],
                    ],
                ],
            ]
        }
        func mutations(surface: [String: Any]) -> [[String: Any]] {
            [
                [
                    "entityKey": "key-c1",
                    "payload": [
                        "commentEntityPayload": [
                            "properties": [
                                "commentId": "c1",
                                "content": ["content": "Text"],
                            ],
                            "author": ["displayName": "@author"],
                        ],
                    ],
                ],
                [
                    "entityKey": "key-s1",
                    "payload": ["engagementToolbarSurfaceEntityPayload": surface],
                ],
            ]
        }
        func page(surface: [String: Any]) -> YouTubeCommentsPage {
            YouTubeCommentsParser.parse([
                "frameworkUpdates": ["entityBatchUpdate": ["mutations": mutations(surface: surface)]],
                "onResponseReceivedEndpoints": [
                    [
                        "appendContinuationItemsAction": [
                            "continuationItems": [
                                [
                                    "commentViewModel": [
                                        "commentId": "c1",
                                        "commentKey": "key-c1",
                                        "toolbarSurfaceKey": "key-s1",
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ])
        }

        // A top-level comment's dialog has no editable text.
        let topLevel = try #require(page(surface: ["replyCommand": replyCommand(editableText: nil)]).comments.first)
        #expect(topLevel.replyParams == "reply-params")
        #expect(topLevel.replyMention == nil)

        // A reply's dialog starts with a linked mention of its author, padded
        // with spaces as YouTube sends it.
        let mention: [String: Any] = [
            "runs": [
                [
                    "navigationEndpoint": ["browseEndpoint": ["browseId": "UCauthor"]],
                    "text": " @author",
                ],
                ["text": " "],
            ],
        ]
        let reply = try #require(page(surface: ["replyCommand": replyCommand(editableText: mention)]).comments.first)
        #expect(reply.replyParams == "reply-params")
        #expect(reply.replyMention == "@author")

        // Replies turned off: no reply command at all.
        let closed = try #require(page(surface: [:]).comments.first)
        #expect(closed.replyParams == nil)
        #expect(closed.replyMention == nil)
    }
}
