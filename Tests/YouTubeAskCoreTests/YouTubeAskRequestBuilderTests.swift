import Foundation
import Testing
@testable import YouTubeAskCore

@Suite("YouTubeAsk direct-chip request builder")
struct YouTubeAskRequestBuilderTests {
    @Test("Builds the exact panel-bootstrap body")
    func exactPanelBootstrapBody() throws {
        let envelope = try YouTubeAskTestFixture.envelope("YouTubeAskEligibleNext")
        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let bootstrap = try #require(parsedBootstrap)
        let command = try #require(bootstrap.panelCommand)

        let data = YouTubeAskRequestBuilder.makePanelBootstrapBody(command: command)
        let body = try YouTubeAskTestFixture.object(from: data)

        #expect(Set(body.keys) == ["continuation"])
        #expect(body["continuation"] as? String == "fixture-panel-continuation")
    }

    @Test("Builds the exact direct-chip body without forbidden fields")
    func exactDirectChipBody() throws {
        let envelope = try YouTubeAskTestFixture.envelope("YouTubeAskEligibleNext")
        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let bootstrap = try #require(parsedBootstrap)
        let suggestion = try #require(bootstrap.suggestions.first)

        let data = try YouTubeAskRequestBuilder.makeDirectChipBody(
            command: suggestion.command,
            clientMessageID: "youchat-1000"
        )
        let body = try YouTubeAskTestFixture.object(from: data)

        #expect(Set(body.keys) == ["continuation", "formData"])
        #expect(body["continuation"] as? String == "fixture-chip-continuation-a")
        let formData = try #require(body["formData"] as? [String: Any])
        #expect(Set(formData.keys) == ["inputComposerFormData"])
        let composer = try #require(formData["inputComposerFormData"] as? [String: Any])
        #expect(Set(composer.keys) == ["clientMessageId"])
        #expect(composer["clientMessageId"] as? String == "youchat-1000")

        let keys = Self.allKeys(in: body)
        for forbidden in [
            "chipId",
            "clickTrackingParams",
            "conversationId",
            "pendingSuggestedQueryIdentifier",
            "previousClientMessageId",
            "trackingParams",
            "userInputText",
        ] {
            #expect(!keys.contains(forbidden))
        }
        let bodyText = try #require(String(data: data, encoding: .utf8))
        #expect(!bodyText.contains(suggestion.label))
    }

    @Test("Builds the validated one-shot free-text body and click-tracking context")
    func exactFreeTextBody() throws {
        let envelope = try YouTubeAskTestFixture.envelope("YouTubeAskEligibleNext")
        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let command = try #require(parsedBootstrap?.freeTextCommand)

        let data = try YouTubeAskRequestBuilder.makeFreeTextBody(
            command: command,
            clientMessageID: "youchat-1000",
            userInputText: " What is this video about? ",
            playerOffsetMilliseconds: 234_000
        )
        let body = try YouTubeAskTestFixture.object(from: data)

        #expect(Set(body.keys) == ["continuation", "formData"])
        #expect(body["continuation"] as? String == "fixture-free-text-continuation")
        let formData = try #require(body["formData"] as? [String: Any])
        #expect(Set(formData.keys) == ["inputComposerFormData"])
        let composer = try #require(formData["inputComposerFormData"] as? [String: Any])
        #expect(Set(composer.keys) == ["clientMessageId", "playerOffsetMs", "userInputText"])
        #expect(composer["clientMessageId"] as? String == "youchat-1000")
        #expect(composer["playerOffsetMs"] as? String == "234000")
        #expect(composer["userInputText"] as? String == "What is this video about?")

        let contextData = try YouTubeAskRequestBuilder.makeFreeTextClickTrackingContext(
            command: command
        )
        let context = try YouTubeAskTestFixture.object(from: contextData)
        #expect(Set(context.keys) == ["clickTracking"])
        let clickTracking = try #require(context["clickTracking"] as? [String: Any])
        #expect(Set(clickTracking.keys) == ["clickTrackingParams"])
        #expect(clickTracking["clickTrackingParams"] as? String == "fixture-free-text-click-tracking")
    }

    @Test("Rejects empty and oversized free-text input")
    func freeTextValidation() throws {
        let envelope = try YouTubeAskTestFixture.envelope("YouTubeAskEligibleNext")
        let parsedBootstrap = try YouTubeAskParser.parseBootstrap(from: envelope)
        let command = try #require(parsedBootstrap?.freeTextCommand)
        let oversizedUTF8 = "a" + String(
            repeating: "\u{0301}",
            count: YouTubeAskLimits.maximumUserInputBytes
        )
        #expect(oversizedUTF8.count <= YouTubeAskLimits.maximumUserInputCharacters)
        #expect(oversizedUTF8.utf8.count > YouTubeAskLimits.maximumUserInputBytes)

        for invalid in [
            "",
            "   ",
            String(repeating: "a", count: YouTubeAskLimits.maximumUserInputCharacters + 1),
            oversizedUTF8,
        ] {
            expectYouTubeAskError(.invalidUserInput) {
                _ = try YouTubeAskRequestBuilder.makeFreeTextBody(
                    command: command,
                    clientMessageID: "youchat-1000",
                    userInputText: invalid,
                    playerOffsetMilliseconds: 0
                )
            }
        }
    }

    @Test("Enforces the final request-body byte limit")
    func finalRequestBodyLimit() throws {
        try YouTubeAskRequestBuilder.validateRequestBodySize(
            Data(count: YouTubeAskLimits.maximumRequestBodyBytes)
        )
        expectYouTubeAskError(.requestTooLarge) {
            try YouTubeAskRequestBuilder.validateRequestBodySize(
                Data(count: YouTubeAskLimits.maximumRequestBodyBytes + 1)
            )
        }
    }

    @Test("Rejects malformed client message IDs")
    func clientMessageIDValidation() throws {
        let conversation = try YouTubeAskParser.parseConversation(
            from: YouTubeAskTestFixture.envelope("YouTubeAskInitialPanel")
        )
        let command = try #require(conversation.suggestions.first?.command)

        for invalid in [
            "",
            "fixture-message",
            "youchat-",
            "youchat-not-numeric",
            "youchat-１２３",
            "youchat-١٢٣",
            "youchat-" + String(repeating: "1", count: 57),
        ] {
            expectYouTubeAskError(.invalidClientMessageID) {
                _ = try YouTubeAskRequestBuilder.makeDirectChipBody(
                    command: command,
                    clientMessageID: invalid
                )
            }
        }
    }

    @Test("Opaque commands have redacted descriptions and reflection")
    func opaqueCommandRedaction() throws {
        let conversation = try YouTubeAskParser.parseConversation(
            from: YouTubeAskTestFixture.envelope("YouTubeAskInitialPanel")
        )
        let command = try #require(conversation.suggestions.first?.command)

        #expect(String(describing: command) == "<redacted YouTube Ask command>")
        #expect(String(reflecting: command) == "<redacted YouTube Ask command>")
        #expect(!String(describing: command.customMirror.subjectType).contains("fixture"))
    }

    private static func allKeys(in value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { result, element in
                result.formUnion(Self.allKeys(in: element.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: []) { result, element in
                result.formUnion(Self.allKeys(in: element))
            }
        }
        return []
    }
}
