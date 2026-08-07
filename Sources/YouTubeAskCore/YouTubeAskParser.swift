import Foundation

package enum YouTubeAskParser {
    /// Parses a watch `next` response. `nil` means the response did not expose a
    /// usable YouChat panel bootstrap or direct server-issued suggestions.
    package static func parseBootstrap(
        from envelope: YouTubeAskWireEnvelope
    ) throws -> YouTubeAskParsedBootstrap? {
        var panelBudget = TraversalBudget()
        var eligiblePanels: [YouTubeAskJSONValue] = []
        for root in envelope.roots {
            try Self.collectEligiblePanels(
                in: root,
                depth: 0,
                budget: &panelBudget,
                panels: &eligiblePanels
            )
        }
        guard !eligiblePanels.isEmpty else { return nil }

        var continuationCandidates: [String] = []
        var canonicalContent: (
            suggestions: [YouTubeAskParsedSuggestion],
            freeTextCommand: YouTubeAskOpaqueCommand?
        )?
        for panel in eligiblePanels {
            var commandBudget = TraversalBudget()
            try Self.collectBootstrapContinuations(
                in: panel,
                depth: 0,
                insideSendUserQueryCommand: false,
                budget: &commandBudget,
                continuations: &continuationCandidates
            )

            var panelContent = ConversationAccumulator()
            var contentBudget = TraversalBudget()
            try Self.collectBootstrapSuggestions(
                in: panel,
                depth: 0,
                budget: &contentBudget,
                content: &panelContent
            )
            var freeTextBudget = TraversalBudget()
            var freeTextCommands: [YouTubeAskOpaqueCommand] = []
            try Self.collectFreeTextCommands(
                in: panel,
                depth: 0,
                budget: &freeTextBudget,
                commands: &freeTextCommands
            )
            let panelFreeTextCommand = try Self.unambiguousFreeTextCommand(freeTextCommands)

            let panelSuggestions = try Self.deduplicatedSuggestions(panelContent.suggestions)
            guard !panelSuggestions.isEmpty || panelFreeTextCommand != nil else {
                continue
            }
            if let existingContent = canonicalContent {
                guard existingContent.suggestions.map(\.label) == panelSuggestions.map(\.label) else {
                    throw YouTubeAskCoreError.malformedChip
                }
                // Responsive surfaces can mirror the same visible panel with
                // different opaque commands. Keep one panel atomic: retain the
                // first complete panel, or replace an earlier chips-only mirror
                // with the first later mirror that also owns the composer.
                if existingContent.freeTextCommand == nil, panelFreeTextCommand != nil {
                    canonicalContent = (
                        suggestions: panelSuggestions,
                        freeTextCommand: panelFreeTextCommand
                    )
                }
            } else {
                canonicalContent = (
                    suggestions: panelSuggestions,
                    freeTextCommand: panelFreeTextCommand
                )
            }
        }
        let suggestions = canonicalContent?.suggestions ?? []
        let freeTextCommand = canonicalContent?.freeTextCommand

        let panelContinuation: String?
        do {
            panelContinuation = try Self.unambiguousContinuation(continuationCandidates)
        } catch YouTubeAskCoreError.ambiguousBootstrap
            where !suggestions.isEmpty || freeTextCommand != nil
        {
            // Direct chip continuations are independently validated capabilities.
            // Do not guess among unrelated panel-bootstrap commands when the
            // panel can already be presented without materialization.
            panelContinuation = nil
        }
        guard panelContinuation != nil
            || freeTextCommand != nil
            || !suggestions.isEmpty
        else {
            return nil
        }
        return YouTubeAskParsedBootstrap(
            panelCommand: panelContinuation.map(YouTubeAskOpaqueCommand.init),
            freeTextCommand: freeTextCommand,
            suggestions: suggestions
        )
    }

    /// Parses assistant messages and server-issued follow-up suggestions from a
    /// materialized panel or direct-chip response.
    package static func parseConversation(
        from envelope: YouTubeAskWireEnvelope
    ) throws -> YouTubeAskParsedConversation {
        var budget = TraversalBudget()
        for root in envelope.roots {
            try Self.validateStructure(
                in: root,
                depth: 0,
                budget: &budget
            )
        }

        var content = ConversationAccumulator()
        for root in envelope.roots {
            try Self.collectConfirmedConversationContent(
                from: root,
                content: &content
            )
        }
        content.suggestions = try Self.deduplicatedSuggestions(content.suggestions)
        let freeTextCommand = try Self.unambiguousFreeTextCommand(content.freeTextCommands)
        return YouTubeAskParsedConversation(
            messages: content.messages,
            suggestions: content.suggestions,
            freeTextCommand: freeTextCommand
        )
    }

    package struct ConversationAccumulator {
        var messages: [YouTubeAskParsedMessage] = []
        var suggestions: [YouTubeAskParsedSuggestion] = []
        var freeTextCommands: [YouTubeAskOpaqueCommand] = []
    }

    struct TraversalBudget {
        var visitedNodes = 0

        mutating func visit(_ value: YouTubeAskJSONValue, depth: Int) throws {
            let childCount = switch value {
            case let .object(object):
                object.count
            case let .array(array):
                array.count
            default:
                0
            }
            guard depth <= YouTubeAskLimits.maximumTreeDepth,
                  self.visitedNodes < YouTubeAskLimits.maximumTreeNodes,
                  childCount <= YouTubeAskLimits.maximumChildrenPerContainer
            else {
                throw YouTubeAskCoreError.structureLimitExceeded
            }
            self.visitedNodes += 1
        }
    }

    private static func collectEligiblePanels(
        in value: YouTubeAskJSONValue,
        depth: Int,
        budget: inout TraversalBudget,
        panels: inout [YouTubeAskJSONValue]
    ) throws {
        try budget.visit(value, depth: depth)
        switch value {
        case let .object(object):
            if Self.isEligiblePanelObject(object) {
                panels.append(value)
                return
            }
            for key in object.keys.sorted() {
                guard let nested = object[key] else { continue }
                if key == "PAyouchat" {
                    panels.append(nested)
                    continue
                }
                try Self.collectEligiblePanels(
                    in: nested,
                    depth: depth + 1,
                    budget: &budget,
                    panels: &panels
                )
            }
        case let .array(array):
            for nested in array {
                try Self.collectEligiblePanels(
                    in: nested,
                    depth: depth + 1,
                    budget: &budget,
                    panels: &panels
                )
            }
        default:
            break
        }
    }

    private static func isEligiblePanelObject(
        _ object: [String: YouTubeAskJSONValue]
    ) -> Bool {
        object.contains { key, value in
            Self.eligibleMarkerKeys.contains(key)
                && value.stringValue.map(Self.eligibleMarkerValues.contains) == true
        }
    }

    private static func collectBootstrapContinuations(
        in value: YouTubeAskJSONValue,
        depth: Int,
        insideSendUserQueryCommand: Bool,
        budget: inout TraversalBudget,
        continuations: inout [String]
    ) throws {
        try budget.visit(value, depth: depth)
        switch value {
        case let .object(object):
            if !insideSendUserQueryCommand,
               object["request"]?.stringValue == "CONTINUATION_REQUEST_TYPE_GET_PANEL",
               let token = object["token"]?.stringValue,
               !token.isEmpty,
               token.count <= YouTubeAskLimits.maximumCommandCharacters
            {
                continuations.append(token)
            }

            for key in object.keys.sorted() {
                guard let nested = object[key] else { continue }
                try Self.collectBootstrapContinuations(
                    in: nested,
                    depth: depth + 1,
                    insideSendUserQueryCommand: insideSendUserQueryCommand
                        || key == "sendUserQueryCommand",
                    budget: &budget,
                    continuations: &continuations
                )
            }
        case let .array(array):
            for nested in array {
                try Self.collectBootstrapContinuations(
                    in: nested,
                    depth: depth + 1,
                    insideSendUserQueryCommand: insideSendUserQueryCommand,
                    budget: &budget,
                    continuations: &continuations
                )
            }
        default:
            break
        }
    }

    private static func unambiguousContinuation(
        _ candidates: [String]
    ) throws -> String? {
        guard let first = candidates.first else { return nil }
        guard candidates.dropFirst().allSatisfy({ $0 == first }) else {
            throw YouTubeAskCoreError.ambiguousBootstrap
        }
        return first
    }

    private static func validateStructure(
        in value: YouTubeAskJSONValue,
        depth: Int,
        budget: inout TraversalBudget
    ) throws {
        try budget.visit(value, depth: depth)
        switch value {
        case let .object(object):
            for key in object.keys.sorted() {
                guard let nested = object[key] else { continue }
                try Self.validateStructure(
                    in: nested,
                    depth: depth + 1,
                    budget: &budget
                )
            }
        case let .array(array):
            for nested in array {
                try Self.validateStructure(
                    in: nested,
                    depth: depth + 1,
                    budget: &budget
                )
            }
        default:
            break
        }
    }

    private static func collectConfirmedConversationContent(
        from root: YouTubeAskJSONValue,
        content: inout ConversationAccumulator
    ) throws {
        switch root {
        case let .object(response):
            try Self.parseConfirmedConversationResponse(
                response,
                content: &content
            )
        case let .array(responses):
            for response in responses {
                guard let object = response.objectValue else { continue }
                try Self.parseConfirmedConversationResponse(
                    object,
                    content: &content
                )
            }
        default:
            break
        }
    }

    /// Accept only the response path observed for YouChat panel materialization:
    /// `onResponseReceivedCommands[].appendContinuationItemsAction.continuationItems[]`.
    private static func parseConfirmedConversationResponse(
        _ response: [String: YouTubeAskJSONValue],
        content: inout ConversationAccumulator
    ) throws {
        let legacyCommands = response["onResponseReceivedCommands"]
        let mutationCommand = response["onResponseReceivedCommand"]
        guard legacyCommands == nil || mutationCommand == nil else {
            throw YouTubeAskCoreError.malformedWireResponse
        }

        if let legacyCommands {
            try Self.parseConfirmedLegacyCommands(
                legacyCommands,
                content: &content
            )
        }
        if let mutationCommand {
            try Self.parseConfirmedMutationCommand(
                mutationCommand,
                content: &content
            )
        }
    }

    private static func parseConfirmedLegacyCommands(
        _ value: YouTubeAskJSONValue,
        content: inout ConversationAccumulator
    ) throws {
        guard let commands = value.arrayValue else {
            throw YouTubeAskCoreError.malformedWireResponse
        }

        for command in commands {
            guard let commandObject = command.objectValue else {
                throw YouTubeAskCoreError.malformedWireResponse
            }
            guard let appendAction = commandObject["appendContinuationItemsAction"] else {
                continue
            }
            try Self.parseConfirmedAppendAction(
                appendAction,
                content: &content
            )
        }
    }

    private static func parseConfirmedAppendAction(
        _ value: YouTubeAskJSONValue,
        content: inout ConversationAccumulator
    ) throws {
        guard let action = value.objectValue,
              let continuationItems = action["continuationItems"]?.arrayValue
        else {
            throw YouTubeAskCoreError.malformedWireResponse
        }

        for item in continuationItems {
            try Self.parseConfirmedContinuationItem(
                item,
                content: &content
            )
        }
    }

    package static func parseConfirmedContinuationItem(
        _ value: YouTubeAskJSONValue,
        content: inout ConversationAccumulator
    ) throws {
        guard let item = value.objectValue else { return }
        let recognizedKeys = [
            "youChatTextMessageViewModel",
            "youChatItemViewModel",
        ].filter { item[$0] != nil }
        guard recognizedKeys.count <= 1 else {
            throw YouTubeAskCoreError.malformedWireResponse
        }
        guard let key = recognizedKeys.first,
              let viewModel = item[key]
        else {
            return
        }

        switch key {
        case "youChatTextMessageViewModel":
            try content.messages.append(Self.parseMessageViewModel(viewModel))
        case "youChatItemViewModel":
            try Self.parseYouChatItemViewModel(
                viewModel,
                includeMessages: true,
                content: &content
            )
        default:
            break
        }
    }

    private static func collectBootstrapSuggestions(
        in value: YouTubeAskJSONValue,
        depth: Int,
        budget: inout TraversalBudget,
        content: inout ConversationAccumulator
    ) throws {
        try budget.visit(value, depth: depth)
        switch value {
        case let .object(object):
            for key in object.keys.sorted() {
                guard let nested = object[key] else { continue }
                if key == "youChatItemViewModel" {
                    try Self.parseYouChatItemViewModel(
                        nested,
                        includeMessages: false,
                        content: &content
                    )
                }

                try Self.collectBootstrapSuggestions(
                    in: nested,
                    depth: depth + 1,
                    budget: &budget,
                    content: &content
                )
            }
        case let .array(array):
            for nested in array {
                try Self.collectBootstrapSuggestions(
                    in: nested,
                    depth: depth + 1,
                    budget: &budget,
                    content: &content
                )
            }
        default:
            break
        }
    }

    private static func parseYouChatItemViewModel(
        _ value: YouTubeAskJSONValue,
        includeMessages: Bool,
        content: inout ConversationAccumulator
    ) throws {
        guard let viewModel = value.objectValue else { return }

        if let chipsData = viewModel["chipsData"] {
            try content.suggestions.append(contentsOf: Self.parseChipsData(chipsData))
        }
        if includeMessages, let command = viewModel["sendUserQueryCommand"] {
            try content.freeTextCommands.append(Self.parseFreeTextCommand(command))
        }
        if includeMessages,
           viewModel["chipsData"] == nil,
           viewModel["text"] != nil
        {
            try content.messages.append(Self.parseMessageViewModel(value))
        }
    }

    private static func parseChipsData(
        _ value: YouTubeAskJSONValue
    ) throws -> [YouTubeAskParsedSuggestion] {
        guard let chipsData = value.objectValue,
              let chipData = chipsData["chipData"]?.arrayValue
        else {
            throw YouTubeAskCoreError.malformedChip
        }
        return try chipData.map(Self.parseChip)
    }

    private static func parseChip(
        _ value: YouTubeAskJSONValue
    ) throws -> YouTubeAskParsedSuggestion {
        guard let chip = value.objectValue,
              let continuation = chip["continuation"]?.stringValue,
              !continuation.isEmpty,
              continuation.count <= YouTubeAskLimits.maximumCommandCharacters,
              let textValue = chip["text"]
        else {
            throw YouTubeAskCoreError.malformedChip
        }

        let visibleText = try Self.visibleText(
            from: textValue,
            malformedError: .malformedChip
        )
        if Self.containsUnsupportedChipDecorator(
            value,
            expectedVisibleText: visibleText
        ) {
            throw YouTubeAskCoreError.unsupportedChipDecorator
        }
        guard let label = YouTubeAskVisibleTextSanitizer.sanitizeChipLabel(visibleText) else {
            throw YouTubeAskCoreError.malformedChip
        }
        return YouTubeAskParsedSuggestion(
            label: label.text,
            command: YouTubeAskOpaqueCommand(continuation)
        )
    }

    private static func parseMessageViewModel(
        _ value: YouTubeAskJSONValue
    ) throws -> YouTubeAskParsedMessage {
        guard let viewModel = value.objectValue,
              let textValue = viewModel["text"]
        else {
            throw YouTubeAskCoreError.malformedMessage
        }
        let visibleText = try Self.visibleText(
            from: textValue,
            malformedError: .malformedMessage
        )
        guard let message = YouTubeAskVisibleTextSanitizer.sanitizeAnswer(visibleText) else {
            throw YouTubeAskCoreError.malformedMessage
        }
        return YouTubeAskParsedMessage(
            text: message.text,
            wasTruncated: message.wasTruncated
        )
    }

    private static func containsUnsupportedChipDecorator(
        _ value: YouTubeAskJSONValue,
        expectedVisibleText: String
    ) -> Bool {
        switch value {
        case let .object(object):
            for (key, nested) in object {
                let canonical = key.lowercased()
                if canonical == "onclick" {
                    guard Self.isSupportedOnClickDecorator(
                        nested,
                        expectedVisibleText: expectedVisibleText
                    ) else {
                        return true
                    }
                    continue
                }
                if canonical == "innertubecommand"
                    || canonical == "commandmetadata"
                    || canonical.hasSuffix("command")
                    || canonical.hasSuffix("endpoint")
                    || canonical.contains("decorator")
                {
                    return true
                }
                if Self.containsUnsupportedChipDecorator(
                    nested,
                    expectedVisibleText: expectedVisibleText
                ) {
                    return true
                }
            }
            return false
        case let .array(array):
            return array.contains { nested in
                Self.containsUnsupportedChipDecorator(
                    nested,
                    expectedVisibleText: expectedVisibleText
                )
            }
        default:
            return false
        }
    }

    /// Current YouChat chips may carry a local `listMutationCommand` that
    /// inserts the already-visible chip label as the pending user turn and
    /// scrolls the panel. Kaset performs those UI updates itself and never
    /// executes or preserves this callback. Accept only the exact observed
    /// schema and reject every other command or field.
    private static func isSupportedOnClickDecorator(
        _ value: YouTubeAskJSONValue,
        expectedVisibleText: String
    ) -> Bool {
        guard let onClick = value.objectValue,
              Set(onClick.keys) == ["clickTrackingParams", "listMutationCommand"],
              hasNonemptyString(onClick["clickTrackingParams"]),
              let listMutation = onClick["listMutationCommand"]?.objectValue,
              Set(listMutation.keys) == ["operations"],
              let mutationOperations = listMutation["operations"]?.objectValue,
              Set(mutationOperations.keys) == ["operations", "scrollConfig"],
              let operations = mutationOperations["operations"]?.arrayValue,
              operations.count == 1,
              isSupportedInsertOperation(
                  operations[0],
                  expectedVisibleText: expectedVisibleText
              ),
              isSupportedScrollConfig(mutationOperations["scrollConfig"])
        else {
            return false
        }
        return true
    }

    private static func isSupportedInsertOperation(
        _ value: YouTubeAskJSONValue,
        expectedVisibleText: String
    ) -> Bool {
        guard let operation = value.objectValue,
              Set(operation.keys) == ["insertItemSectionContent"],
              let insertion = operation["insertItemSectionContent"]?.objectValue,
              Set(insertion.keys) == ["contents", "insertByPositionInSection"],
              let contents = insertion["contents"]?.arrayValue,
              contents.count == 2,
              contents.count(where: { content in
                  content.objectValue.map { Set($0.keys) == ["chatUserTurnViewModel"] } ?? false
              }) == 1,
              contents.count(where: { content in
                  content.objectValue.map { Set($0.keys) == ["chatLoadingViewModel"] } ?? false
              }) == 1,
              contents.allSatisfy({ content in
                  Self.isSupportedUserTurnContent(
                      content,
                      expectedVisibleText: expectedVisibleText
                  ) || Self.isSupportedLoadingContent(content)
              }),
              let position = insertion["insertByPositionInSection"]?.objectValue,
              Set(position.keys) == ["position", "sectionTargetId"],
              hasNonemptyString(position["position"]),
              hasNonemptyString(position["sectionTargetId"])
        else {
            return false
        }
        return true
    }

    private static func isSupportedUserTurnContent(
        _ value: YouTubeAskJSONValue,
        expectedVisibleText: String
    ) -> Bool {
        guard let content = value.objectValue,
              Set(content.keys) == ["chatUserTurnViewModel"],
              let userTurn = content["chatUserTurnViewModel"]?.objectValue,
              Set(userTurn.keys) == ["backgroundStyle", "text"],
              hasNonemptyString(userTurn["backgroundStyle"]),
              userTurn["text"]?.stringValue == expectedVisibleText
        else {
            return false
        }
        return true
    }

    private static func isSupportedLoadingContent(
        _ value: YouTubeAskJSONValue
    ) -> Bool {
        guard let content = value.objectValue,
              Set(content.keys) == ["chatLoadingViewModel"],
              let loading = content["chatLoadingViewModel"]?.objectValue,
              Set(loading.keys) == [
                  "animation",
                  "darkThemeAnimation",
                  "loadingAnimationA11yLabel",
                  "targetId",
              ],
              hasNonemptyString(loading["loadingAnimationA11yLabel"]),
              hasNonemptyString(loading["targetId"]),
              isSupportedLoadingAnimation(loading["animation"]),
              isSupportedLoadingAnimation(loading["darkThemeAnimation"])
        else {
            return false
        }
        return true
    }

    private static func isSupportedLoadingAnimation(
        _ value: YouTubeAskJSONValue?
    ) -> Bool {
        guard let animation = value?.objectValue,
              Set(animation.keys) == ["lottieAnimationViewModel"],
              let lottie = animation["lottieAnimationViewModel"]?.objectValue,
              Set(lottie.keys) == ["loop", "trustedAnimationUrl"],
              isBooleanOrNumber(lottie["loop"]),
              let trustedURL = lottie["trustedAnimationUrl"]?.objectValue,
              Set(trustedURL.keys) == [
                  "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue",
              ],
              hasNonemptyString(
                  trustedURL["privateDoNotAccessOrElseTrustedResourceUrlWrappedValue"]
              )
        else {
            return false
        }
        return true
    }

    private static func isBooleanOrNumber(_ value: YouTubeAskJSONValue?) -> Bool {
        switch value {
        case .bool, .number:
            true
        default:
            false
        }
    }

    private static func isSupportedScrollConfig(
        _ value: YouTubeAskJSONValue?
    ) -> Bool {
        guard let scrollConfig = value?.objectValue,
              Set(scrollConfig.keys) == ["scrollToItem"],
              let scrollToItem = scrollConfig["scrollToItem"]?.objectValue,
              Set(scrollToItem.keys) == ["item", "scrollPosition"],
              hasNonemptyString(scrollToItem["scrollPosition"]),
              let item = scrollToItem["item"]?.objectValue,
              Set(item.keys) == ["itemTargetId", "sectionTargetId"],
              hasNonemptyString(item["itemTargetId"]),
              hasNonemptyString(item["sectionTargetId"])
        else {
            return false
        }
        return true
    }

    private static func hasNonemptyString(_ value: YouTubeAskJSONValue?) -> Bool {
        guard let string = value?.stringValue else { return false }
        return !string.isEmpty
    }
}
