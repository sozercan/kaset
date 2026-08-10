import Foundation
import Testing
@testable import YouTubeAskCore

@Suite("YouTubeAsk strict parser")
struct YouTubeAskParserTests {
    @Test("Parses only the eligible YouChat watch panel")
    func parsesEligibleBootstrap() throws {
        let envelope = try YouTubeAskTestFixture.envelope("YouTubeAskEligibleNext")
        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let bootstrap = try #require(parsedBootstrap)

        #expect(bootstrap.panelCommand?.continuation == "fixture-panel-continuation")
        #expect(bootstrap.suggestions.map(\.label) == [
            "Explain this video",
            "Résumer les points clés",
        ])
        #expect(bootstrap.suggestions.map(\.command.continuation) == [
            "fixture-chip-continuation-a",
            "fixture-chip-continuation-b",
        ])
        #expect(bootstrap.panelCommand?.continuation != "fixture-query-continuation")
        #expect(bootstrap.freeTextCommand?.continuation == "fixture-free-text-continuation")
        #expect(
            bootstrap.freeTextCommand?.clickTrackingParams
                == "fixture-free-text-click-tracking"
        )
    }

    @Test("Rejects unrelated AI panels and decoy YouChat-shaped content")
    func rejectsIneligibleBootstrap() throws {
        let bootstrap = try YouTubeAskParser.parseBootstrap(
            from: YouTubeAskTestFixture.envelope("YouTubeAskIneligibleNext")
        )
        #expect(bootstrap == nil)
    }

    @Test("Excludes sendUserQueryCommand continuations from bootstrap selection")
    func excludesSendUserQueryCommand() throws {
        let envelope = try Self.envelope([
            "engagementPanels": [[
                "panelIdentifier": "PAyouchat",
                "sendUserQueryCommand": [
                    "continuationCommand": [
                        "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                        "token": "fixture-query-only-continuation",
                    ],
                ],
                "youChatItemViewModel": [
                    "chipsData": [
                        "chipData": [[
                            "text": ["simpleText": "Safe suggestion"],
                            "continuation": "fixture-chip-only-continuation",
                        ]],
                    ],
                ],
            ]],
        ])

        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let bootstrap = try #require(parsedBootstrap)
        #expect(bootstrap.panelCommand == nil)
        #expect(bootstrap.suggestions.count == 1)
    }

    @Test("Fails closed on distinct bootstrap commands but permits repeated identical commands")
    func bootstrapAmbiguity() throws {
        let ambiguous = try Self.envelope(Self.bootstrapObject(tokens: [
            "fixture-panel-continuation-a",
            "fixture-panel-continuation-b",
        ]))
        expectYouTubeAskError(.ambiguousBootstrap) {
            _ = try YouTubeAskParser.parseBootstrap(from: ambiguous)
        }

        let repeated = try Self.envelope(Self.bootstrapObject(tokens: [
            "fixture-panel-continuation-a",
            "fixture-panel-continuation-a",
        ]))
        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: repeated)
        let bootstrap = try #require(parsedBootstrap)
        #expect(bootstrap.panelCommand?.continuation == "fixture-panel-continuation-a")
    }

    @Test("Keeps direct chips when panel bootstrap commands are ambiguous")
    func directChipsSurvivePanelCommandAmbiguity() throws {
        let envelope = try Self.envelope([
            "engagementPanels": [[
                "panelIdentifier": "PAyouchat",
                "commands": [
                    [
                        "continuationCommand": [
                            "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                            "token": "fixture-panel-continuation-a",
                        ],
                    ],
                    [
                        "continuationCommand": [
                            "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                            "token": "fixture-panel-continuation-b",
                        ],
                    ],
                ],
                "content": [
                    "youChatItemViewModel": [
                        "chipsData": [
                            "chipData": [[
                                "text": ["simpleText": "Direct suggestion"],
                                "continuation": "fixture-direct-continuation",
                            ]],
                        ],
                    ],
                ],
            ]],
        ])

        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let bootstrap = try #require(parsedBootstrap)
        #expect(bootstrap.panelCommand == nil)
        #expect(bootstrap.suggestions.map(\.label) == ["Direct suggestion"])
        #expect(bootstrap.suggestions.first?.command.continuation == "fixture-direct-continuation")
    }

    @Test("Extracts chips only from supported YouChat continuation-item containers")
    func strictChipPath() throws {
        let decoy = [
            "youChatItemViewModel": [
                "chipsData": [
                    "chipData": [[
                        "text": ["simpleText": "Decoy"],
                        "continuation": "fixture-decoy-continuation",
                        "onClick": ["sendUserQueryCommand": ["placeholder": true]],
                    ]],
                ],
            ],
        ]
        let accepted = [
            "youChatItemViewModel": [
                "chipsData": [
                    "chipData": [[
                        "text": ["simpleText": "Accepted"],
                        "continuation": "fixture-accepted-continuation",
                    ]],
                ],
            ],
        ]
        let envelope = try Self.envelope([
            "decoy": decoy,
            "items": [decoy],
            "onResponseReceivedCommands": [[
                "decoy": decoy,
                "appendContinuationItemsAction": [
                    "decoy": decoy,
                    "continuationItems": [
                        ["metadata": decoy],
                        accepted,
                    ],
                ],
            ]],
        ])

        let conversation = try YouTubeAskParser.parseConversation(from: envelope)
        #expect(conversation.suggestions.map(\.label) == ["Accepted"])
        #expect(conversation.suggestions.first?.command.continuation == "fixture-accepted-continuation")
    }

    @Test("Deduplicates exact chips while preserving first occurrence and order")
    func deduplicatesExactChips() throws {
        let conversation = try YouTubeAskParser.parseConversation(
            from: YouTubeAskTestFixture.envelope("YouTubeAskInitialPanel")
        )

        #expect(conversation.suggestions.map(\.label) == ["Ask a follow-up"])
        #expect(conversation.suggestions.map(\.command.continuation) == [
            "fixture-follow-up-continuation",
        ])
    }

    @Test("Rejects the same sanitized chip label with a different continuation")
    func rejectsAmbiguousChipLabel() {
        expectYouTubeAskError(.malformedChip) {
            _ = try YouTubeAskParser.parseConversation(
                from: YouTubeAskTestFixture.envelope("YouTubeAskConversation")
            )
        }
    }

    @Test("Accepts the observed local list-mutation callback without executing it")
    func acceptsObservedOnClickListMutation() throws {
        let envelope = try Self.envelope([
            "engagementPanels": [[
                "panelIdentifier": "PAyouchat",
                "content": [
                    "youChatItemViewModel": [
                        "chipsData": [
                            "chipData": [[
                                "text": ["simpleText": "Supported suggestion"],
                                "continuation": "fixture-supported-continuation",
                                "onClick": Self.localListMutationCallback(
                                    visibleText: "Supported suggestion"
                                ),
                            ]],
                        ],
                    ],
                ],
            ]],
        ])

        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let bootstrap = try #require(parsedBootstrap)
        #expect(bootstrap.suggestions.map(\.label) == ["Supported suggestion"])
        #expect(bootstrap.suggestions.first?.command.continuation == "fixture-supported-continuation")
    }

    @Test("Fails the entire chip set on malformed or decorated chips")
    func malformedChipsFailClosed() throws {
        let decorated = try Self.conversationEnvelope(chips: [[
            "text": ["simpleText": "Decorated"],
            "continuation": "fixture-decorated-continuation",
            "onClick": [
                "sendUserQueryCommand": ["placeholder": true],
            ],
        ]])
        expectYouTubeAskError(.unsupportedChipDecorator) {
            _ = try YouTubeAskParser.parseConversation(from: decorated)
        }

        let alternativeContinuation = try Self.conversationEnvelope(chips: [[
            "text": ["simpleText": "Alternative command"],
            "continuation": "fixture-root-continuation",
            "onClick": [
                "continuationCommand": [
                    "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                    "token": "fixture-alternative-continuation",
                ],
            ],
        ]])
        expectYouTubeAskError(.unsupportedChipDecorator) {
            _ = try YouTubeAskParser.parseConversation(from: alternativeContinuation)
        }

        let malformedOnClick = try Self.conversationEnvelope(chips: [[
            "text": ["simpleText": "Malformed callback"],
            "continuation": "fixture-malformed-callback-continuation",
            "onClick": "unsupported-callback",
        ]])
        expectYouTubeAskError(.unsupportedChipDecorator) {
            _ = try YouTubeAskParser.parseConversation(from: malformedOnClick)
        }

        let multipleCallbackCommands = try Self.conversationEnvelope(chips: [[
            "text": ["simpleText": "Multiple callbacks"],
            "continuation": "fixture-multiple-callback-continuation",
            "onClick": [
                "recordClickCommand": ["placeholder": true],
                "recordVisibilityCommand": ["placeholder": true],
            ],
        ]])
        expectYouTubeAskError(.unsupportedChipDecorator) {
            _ = try YouTubeAskParser.parseConversation(from: multipleCallbackCommands)
        }

        let unknownCommand = try Self.conversationEnvelope(chips: [[
            "text": ["simpleText": "Unknown callback"],
            "continuation": "fixture-unknown-callback-continuation",
            "onClick": [
                "loadContinuationCommand": [
                    "continuationToken": "fixture-hidden-continuation",
                ],
            ],
        ]])
        expectYouTubeAskError(.unsupportedChipDecorator) {
            _ = try YouTubeAskParser.parseConversation(from: unknownCommand)
        }

        let mismatchedVisibleText = try Self.conversationEnvelope(chips: [[
            "text": ["simpleText": "Visible suggestion"],
            "continuation": "fixture-mismatched-callback-continuation",
            "onClick": Self.localListMutationCallback(
                visibleText: "Different suggestion"
            ),
        ]])
        expectYouTubeAskError(.unsupportedChipDecorator) {
            _ = try YouTubeAskParser.parseConversation(from: mismatchedVisibleText)
        }

        let unsafeLoadingCallback = try Self.conversationEnvelope(chips: [[
            "text": ["simpleText": "Unsafe loading callback"],
            "continuation": "fixture-unsafe-loading-continuation",
            "onClick": Self.localListMutationCallback(
                visibleText: "Unsafe loading callback",
                loadingExtraFields: [
                    "sendUserQueryCommand": ["placeholder": true],
                ]
            ),
        ]])
        expectYouTubeAskError(.unsupportedChipDecorator) {
            _ = try YouTubeAskParser.parseConversation(from: unsafeLoadingCallback)
        }

        let missingContinuation = try Self.conversationEnvelope(chips: [[
            "text": ["simpleText": "Missing command"],
        ]])
        expectYouTubeAskError(.malformedChip) {
            _ = try YouTubeAskParser.parseConversation(from: missingContinuation)
        }

        let ambiguousText = try Self.conversationEnvelope(chips: [[
            "text": [
                "content": "First representation",
                "simpleText": "Second representation",
            ],
            "continuation": "fixture-ambiguous-text-continuation",
        ]])
        expectYouTubeAskError(.malformedChip) {
            _ = try YouTubeAskParser.parseConversation(from: ambiguousText)
        }
    }

    @Test("Preserves duplicate assistant messages")
    func preservesDuplicateAssistantMessages() throws {
        let duplicateMessage = [
            "youChatTextMessageViewModel": [
                "text": ["content": "First assistant message"],
            ],
        ]
        let conversation = try YouTubeAskParser.parseConversation(from: Self.conversationEnvelope(items: [
            duplicateMessage,
            duplicateMessage,
        ]))

        #expect(conversation.messages.map(\.text) == [
            "First assistant message",
            "First assistant message",
        ])
        #expect(conversation.suggestions.isEmpty)
    }

    @Test("Accepts messages only from confirmed YouChat response containers")
    func ignoresDecoyMessages() throws {
        let decoy = [
            "youChatTextMessageViewModel": [
                "text": ["content": "YouChat-shaped decoy"],
            ],
        ]
        let envelope = try Self.envelope([
            "youChatTextMessageViewModel": [
                "text": ["content": "Top-level decoy"],
            ],
            "items": [
                ["text": ["content": "Decoy text"]],
                ["genericMessageViewModel": ["text": ["content": "Generic decoy"]]],
                decoy,
            ],
            "onResponseReceivedCommands": [[
                "decoy": decoy,
                "appendContinuationItemsAction": [
                    "continuationItems": [
                        ["metadata": decoy],
                        ["youChatTextMessageViewModel": [
                            "text": ["content": "Confirmed message"],
                        ]],
                    ],
                ],
            ]],
        ])

        let conversation = try YouTubeAskParser.parseConversation(from: envelope)
        #expect(conversation.messages.map(\.text) == ["Confirmed message"])
    }

    @Test("Parses the confirmed list-mutation response container")
    func parsesConfirmedListMutationResponse() throws {
        let envelope = try Self.envelope([
            "onResponseReceivedCommand": [
                "listMutationCommand": [
                    "operations": [
                        "operations": [[
                            "insertItemSectionContent": [
                                "contents": [
                                    [
                                        "youChatItemViewModel": [
                                            "chatResponseStyle": "CHAT_RESPONSE_STYLE_DEFAULT",
                                            "text": [
                                                "content": "Synthetic summary response",
                                                "styleRuns": [[
                                                    "startIndex": 0,
                                                    "length": 9,
                                                    "weightLabel": "FONT_WEIGHT_MEDIUM",
                                                ]],
                                            ],
                                            "transparentBackground": true,
                                        ],
                                    ],
                                    [
                                        "youChatItemViewModel": [
                                            "chatResponseStyle": "CHAT_RESPONSE_STYLE_DEFAULT",
                                            "videoResultsData": ["placeholder": true],
                                            "transparentBackground": true,
                                        ],
                                    ],
                                    [
                                        "youChatItemViewModel": [
                                            "chipsData": [
                                                "chipData": [[
                                                    "text": ["content": "Continue"],
                                                    "continuation": "fixture-mutation-follow-up",
                                                    "onClick": Self.localListMutationCallback(
                                                        visibleText: "Continue"
                                                    ),
                                                ]],
                                            ],
                                        ],
                                    ],
                                ],
                                "insertByPositionInSection": [
                                    "position": "INSERTION_POSITION_LAST",
                                    "sectionTargetId": "fixture-response-section",
                                ],
                            ],
                        ]],
                    ],
                ],
            ],
            "frameworkUpdates": [
                "entityBatchUpdate": ["mutations": []],
            ],
        ])

        let conversation = try YouTubeAskParser.parseConversation(from: envelope)
        #expect(conversation.messages.map(\.text) == ["Synthetic summary response"])
        #expect(conversation.suggestions.map(\.label) == ["Continue"])
        #expect(conversation.suggestions.first?.command.continuation == "fixture-mutation-follow-up")
    }

    @Test("Rejects YouChat-shaped content in unsupported response containers")
    func rejectsUnsupportedResponseContainers() throws {
        let message = [
            "youChatTextMessageViewModel": [
                "text": ["content": "Unsupported message"],
            ],
        ]
        let suggestion = [
            "youChatItemViewModel": [
                "chipsData": [
                    "chipData": [[
                        "text": ["simpleText": "Unsupported suggestion"],
                        "continuation": "fixture-unsupported-continuation",
                    ]],
                ],
            ],
        ]
        let envelope = try Self.envelope([
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": [message, suggestion],
                ],
            ]],
            "onResponseReceivedCommands": [[
                "reloadContinuationItemsCommand": [
                    "continuationItems": [message, suggestion],
                ],
            ]],
        ])

        let conversation = try YouTubeAskParser.parseConversation(from: envelope)
        #expect(conversation.messages.isEmpty)
        #expect(conversation.suggestions.isEmpty)
    }

    @Test("Fails closed on malformed or ambiguous supported response containers")
    func malformedSupportedResponseContainersFailClosed() throws {
        let malformedCommands = try Self.envelope([
            "onResponseReceivedCommands": ["unexpected": true],
        ])
        expectYouTubeAskError(.malformedWireResponse) {
            _ = try YouTubeAskParser.parseConversation(from: malformedCommands)
        }

        let missingItems = try Self.envelope([
            "onResponseReceivedCommands": [[
                "appendContinuationItemsAction": ["unexpected": true],
            ]],
        ])
        expectYouTubeAskError(.malformedWireResponse) {
            _ = try YouTubeAskParser.parseConversation(from: missingItems)
        }

        let mixedContainers = try Self.envelope([
            "onResponseReceivedCommands": [],
            "onResponseReceivedCommand": [
                "listMutationCommand": [
                    "operations": ["operations": []],
                ],
            ],
        ])
        expectYouTubeAskError(.malformedWireResponse) {
            _ = try YouTubeAskParser.parseConversation(from: mixedContainers)
        }

        let malformedMutation = try Self.envelope([
            "onResponseReceivedCommand": [
                "listMutationCommand": ["operations": ["unexpected": true]],
            ],
        ])
        expectYouTubeAskError(.malformedWireResponse) {
            _ = try YouTubeAskParser.parseConversation(from: malformedMutation)
        }

        let missingMutationPlacement = try Self.envelope([
            "onResponseReceivedCommand": [
                "listMutationCommand": [
                    "operations": [
                        "operations": [[
                            "insertItemSectionContent": ["contents": []],
                        ]],
                    ],
                ],
            ],
        ])
        expectYouTubeAskError(.malformedWireResponse) {
            _ = try YouTubeAskParser.parseConversation(from: missingMutationPlacement)
        }

        let wrongMutationPosition = try Self.envelope([
            "onResponseReceivedCommand": [
                "listMutationCommand": [
                    "operations": [
                        "operations": [[
                            "insertItemSectionContent": [
                                "contents": [],
                                "insertByPositionInSection": [
                                    "position": "ITEM_SECTION_POSITION_START",
                                    "sectionTargetId": "fixture-response-section",
                                ],
                            ],
                        ]],
                    ],
                ],
            ],
        ])
        expectYouTubeAskError(.malformedWireResponse) {
            _ = try YouTubeAskParser.parseConversation(from: wrongMutationPosition)
        }

        let ambiguousItem = try Self.conversationEnvelope(items: [[
            "youChatTextMessageViewModel": [
                "text": ["content": "Ambiguous message"],
            ],
            "youChatItemViewModel": [
                "chipsData": [
                    "chipData": [[
                        "text": ["simpleText": "Ambiguous suggestion"],
                        "continuation": "fixture-ambiguous-container-continuation",
                    ]],
                ],
            ],
        ]])
        expectYouTubeAskError(.malformedWireResponse) {
            _ = try YouTubeAskParser.parseConversation(from: ambiguousItem)
        }
    }

    @Test("Sanitizes assistant text and preserves frame order")
    func sanitizesMessagesAcrossFrames() throws {
        let first = #"{"onResponseReceivedCommands":[{"appendContinuationItemsAction":{"continuationItems":[{"youChatTextMessageViewModel":{"text":{"content":"First https://placeholder.invalid/path"}}}]}}]}"#
        let second = #"{"onResponseReceivedCommands":[{"appendContinuationItemsAction":{"continuationItems":[{"youChatTextMessageViewModel":{"text":{"content":"Second"}}}]}}]}"#
        let envelope = try YouTubeAskWireDecoder.decode(Data("\(first)\n\(second)\n".utf8))

        let conversation = try YouTubeAskParser.parseConversation(from: envelope)
        #expect(conversation.messages.map(\.text) == [
            "First [link omitted]",
            "Second",
        ])
    }

    @Test("Rejects overlong chip labels and empty sanitized messages")
    func enforcesVisibleTextRules() throws {
        let oversizedLabel = String(repeating: "a", count: YouTubeAskLimits.maximumChipCharacters + 1)
        let oversized = try Self.conversationEnvelope(chips: [[
            "text": ["simpleText": oversizedLabel],
            "continuation": "fixture-overlong-label-continuation",
        ]])
        expectYouTubeAskError(.malformedChip) {
            _ = try YouTubeAskParser.parseConversation(from: oversized)
        }

        let emptyMessage = try Self.conversationEnvelope(items: [[
            "youChatTextMessageViewModel": [
                "text": ["content": "\u{0000}\u{0007}"],
            ],
        ]])
        expectYouTubeAskError(.malformedMessage) {
            _ = try YouTubeAskParser.parseConversation(from: emptyMessage)
        }
    }

    @Test("Bounds parser traversal even for manually constructed AST values")
    func boundsParserTraversal() {
        var value = YouTubeAskJSONValue.object([:])
        for _ in 0 ... YouTubeAskLimits.maximumTreeDepth {
            value = .array([value])
        }
        let envelope = YouTubeAskWireEnvelope(
            format: .jsonArray,
            hadXSSIPrefix: false,
            roots: [value]
        )

        expectYouTubeAskError(.structureLimitExceeded) {
            _ = try YouTubeAskParser.parseConversation(from: envelope)
        }
    }

    private static func localListMutationCallback(
        visibleText: String,
        loadingExtraFields: [String: Any] = [:]
    ) -> [String: Any] {
        var loadingView: [String: Any] = [
            "animation": Self.loadingAnimation(resource: "fixture-light-animation"),
            "darkThemeAnimation": Self.loadingAnimation(resource: "fixture-dark-animation"),
            "loadingAnimationA11yLabel": "Loading response",
            "targetId": "fixture-loading-target",
        ]
        loadingView.merge(loadingExtraFields) { _, newValue in newValue }

        return [
            "clickTrackingParams": "fixture-tracking-placeholder",
            "listMutationCommand": [
                "operations": [
                    "operations": [[
                        "insertItemSectionContent": [
                            "contents": [
                                [
                                    "chatUserTurnViewModel": [
                                        "backgroundStyle": "CHAT_USER_TURN_BACKGROUND_STYLE_DEFAULT",
                                        "text": visibleText,
                                    ],
                                ],
                                ["chatLoadingViewModel": loadingView],
                            ],
                            "insertByPositionInSection": [
                                "position": "ITEM_SECTION_POSITION_END",
                                "sectionTargetId": "fixture-section-target",
                            ],
                        ],
                    ]],
                    "scrollConfig": [
                        "scrollToItem": [
                            "item": [
                                "itemTargetId": "fixture-item-target",
                                "sectionTargetId": "fixture-section-target",
                            ],
                            "scrollPosition": "SCROLL_POSITION_BOTTOM",
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func loadingAnimation(resource: String) -> [String: Any] {
        [
            "lottieAnimationViewModel": [
                "loop": true,
                "trustedAnimationUrl": [
                    "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": resource,
                ],
            ],
        ]
    }

    private static func bootstrapObject(tokens: [String]) -> [String: Any] {
        [
            "engagementPanels": [[
                "panelIdentifier": "PAyouchat",
                "commands": tokens.map { token in
                    [
                        "continuationCommand": [
                            "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                            "token": token,
                        ],
                    ]
                },
            ]],
        ]
    }

    static func eligiblePanel(
        chips: [(label: String, continuation: String)],
        freeTextCommand: [String: Any]? = nil
    ) -> [String: Any] {
        var viewModel: [String: Any] = [
            "chipsData": [
                "chipData": chips.map { chip in
                    [
                        "text": ["simpleText": chip.label],
                        "continuation": chip.continuation,
                    ]
                },
            ],
        ]
        if let freeTextCommand {
            viewModel["sendUserQueryCommand"] = freeTextCommand
        }
        return [
            "panelIdentifier": "PAyouchat",
            "youChatItemViewModel": viewModel,
        ]
    }

    static func freeTextCommand(
        continuation: String,
        clickTrackingParams: String = "fixture-free-text-click"
    ) -> [String: Any] {
        [
            "innertubeCommand": [
                "clickTrackingParams": clickTrackingParams,
                "continuationCommand": [
                    "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                    "token": continuation,
                ],
            ],
        ]
    }

    private static func conversationEnvelope(
        chips: [[String: Any]]
    ) throws -> YouTubeAskWireEnvelope {
        try self.conversationEnvelope(items: [[
            "youChatItemViewModel": [
                "chipsData": [
                    "chipData": chips,
                ],
            ],
        ]])
    }

    private static func conversationEnvelope(
        items: [[String: Any]]
    ) throws -> YouTubeAskWireEnvelope {
        try self.envelope([
            "onResponseReceivedCommands": [[
                "appendContinuationItemsAction": [
                    "continuationItems": items,
                ],
            ]],
        ])
    }

    static func envelope(
        _ object: [String: Any]
    ) throws -> YouTubeAskWireEnvelope {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try YouTubeAskWireDecoder.decode(data)
    }
}
