import Foundation
import Testing
@testable import YouTubeAskCore

extension YouTubeAskParserTests {
    @Test("Selects the first content-equivalent mirrored Ask panel")
    func selectsFirstMirroredBootstrapPanel() throws {
        let envelope = try Self.envelope([
            "engagementPanels": [
                Self.eligiblePanel(chips: [
                    ("Summarize the video", "fixture-summary-primary"),
                    ("Recommend related content", "fixture-related-primary"),
                ]),
                Self.eligiblePanel(chips: [
                    ("Summarize the video", "fixture-summary-mirror"),
                    ("Recommend related content", "fixture-related-mirror"),
                ]),
            ],
        ])

        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let bootstrap = try #require(parsedBootstrap)

        #expect(bootstrap.suggestions.map(\.label) == [
            "Summarize the video",
            "Recommend related content",
        ])
        #expect(bootstrap.suggestions.map(\.command.continuation) == [
            "fixture-summary-primary",
            "fixture-related-primary",
        ])
    }

    @Test("Rejects mirrored Ask panels with different visible choices")
    func rejectsInconsistentMirroredBootstrapPanel() throws {
        let envelope = try Self.envelope([
            "engagementPanels": [
                Self.eligiblePanel(chips: [
                    ("Summarize the video", "fixture-summary-primary"),
                ]),
                Self.eligiblePanel(chips: [
                    ("Recommend related content", "fixture-related-mirror"),
                ]),
            ],
        ])

        expectYouTubeAskError(.malformedChip) {
            _ = try YouTubeAskParser.parseBootstrap(from: envelope)
        }
    }

    @Test("Rejects a missing free-text command across content-equivalent panels")
    func rejectsMissingFreeTextCommandAcrossMirrors() throws {
        let envelope = try Self.envelope([
            "engagementPanels": [
                Self.eligiblePanel(
                    chips: [("Summarize the video", "fixture-summary-primary")],
                    freeTextCommand: Self.freeTextCommand(
                        continuation: "fixture-free-text-command"
                    )
                ),
                Self.eligiblePanel(chips: [
                    ("Summarize the video", "fixture-summary-mirror"),
                ]),
            ],
        ])

        expectYouTubeAskError(.ambiguousBootstrap) {
            _ = try YouTubeAskParser.parseBootstrap(from: envelope)
        }
    }

    @Test("Rejects distinct free-text commands across content-equivalent panels")
    func rejectsDistinctFreeTextCommandsAcrossMirrors() throws {
        let envelope = try Self.envelope([
            "engagementPanels": [
                Self.eligiblePanel(
                    chips: [("Summarize the video", "fixture-summary-primary")],
                    freeTextCommand: Self.freeTextCommand(
                        continuation: "fixture-free-text-primary"
                    )
                ),
                Self.eligiblePanel(
                    chips: [("Summarize the video", "fixture-summary-mirror")],
                    freeTextCommand: Self.freeTextCommand(
                        continuation: "fixture-free-text-mirror"
                    )
                ),
            ],
        ])

        expectYouTubeAskError(.ambiguousBootstrap) {
            _ = try YouTubeAskParser.parseBootstrap(from: envelope)
        }
    }

    @Test("Free-text capability survives ambiguous mirrored panel continuations")
    func freeTextSurvivesAmbiguousPanelContinuations() throws {
        let freeTextCommand = Self.freeTextCommand(
            continuation: "fixture-free-text-command"
        )
        let envelope = try Self.envelope([
            "engagementPanels": [
                [
                    "panelIdentifier": "PAyouchat",
                    "continuationEndpoint": [
                        "continuationCommand": [
                            "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                            "token": "fixture-panel-a",
                        ],
                    ],
                    "content": [
                        "youChatItemViewModel": [
                            "sendUserQueryCommand": freeTextCommand,
                        ],
                    ],
                ],
                [
                    "panelIdentifier": "PAyouchat",
                    "continuationEndpoint": [
                        "continuationCommand": [
                            "request": "CONTINUATION_REQUEST_TYPE_GET_PANEL",
                            "token": "fixture-panel-b",
                        ],
                    ],
                    "content": [
                        "youChatItemViewModel": [
                            "sendUserQueryCommand": freeTextCommand,
                        ],
                    ],
                ],
            ],
        ])

        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let bootstrap = try #require(parsedBootstrap)
        #expect(bootstrap.panelCommand == nil)
        #expect(bootstrap.freeTextCommand != nil)
        #expect(bootstrap.suggestions.isEmpty)
    }
}
