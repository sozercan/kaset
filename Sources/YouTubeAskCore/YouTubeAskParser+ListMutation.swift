import Foundation

extension YouTubeAskParser {
    /// Current `get_panel` responses insert assistant items and follow-up chips
    /// through one top-level list mutation. Only contents under the confirmed
    /// insertion path are eligible; sibling framework/entity updates remain
    /// ignored.
    static func parseConfirmedMutationCommand(
        _ value: YouTubeAskJSONValue,
        content: inout ConversationAccumulator
    ) throws {
        guard let command = value.objectValue else {
            throw YouTubeAskCoreError.malformedWireResponse
        }
        guard let listMutationValue = command["listMutationCommand"] else { return }
        guard let listMutation = listMutationValue.objectValue,
              let operationsContainer = listMutation["operations"]?.objectValue,
              let operations = operationsContainer["operations"]?.arrayValue
        else {
            throw YouTubeAskCoreError.malformedWireResponse
        }

        for operation in operations {
            guard let operationObject = operation.objectValue else {
                throw YouTubeAskCoreError.malformedWireResponse
            }
            guard let insertion = operationObject["insertItemSectionContent"] else {
                continue
            }
            try Self.parseConfirmedInsertItemSectionContent(
                insertion,
                content: &content
            )
        }
    }

    private static func parseConfirmedInsertItemSectionContent(
        _ value: YouTubeAskJSONValue,
        content: inout ConversationAccumulator
    ) throws {
        guard let insertion = value.objectValue,
              Set(insertion.keys) == ["contents", "insertByPositionInSection"],
              let contents = insertion["contents"]?.arrayValue,
              let placement = insertion["insertByPositionInSection"]?.objectValue,
              Set(placement.keys) == ["position", "sectionTargetId"],
              placement["position"]?.stringValue == "INSERTION_POSITION_LAST",
              hasNonemptyString(placement["sectionTargetId"])
        else {
            throw YouTubeAskCoreError.malformedWireResponse
        }

        for item in contents {
            try Self.parseConfirmedContinuationItem(
                item,
                content: &content
            )
        }
    }

    private static func hasNonemptyString(_ value: YouTubeAskJSONValue?) -> Bool {
        guard let string = value?.stringValue else { return false }
        return !string.isEmpty
    }
}
