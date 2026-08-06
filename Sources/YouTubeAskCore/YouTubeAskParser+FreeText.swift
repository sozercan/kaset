import Foundation

extension YouTubeAskParser {
    static func collectFreeTextCommands(
        in value: YouTubeAskJSONValue,
        depth: Int,
        budget: inout TraversalBudget,
        commands: inout [YouTubeAskOpaqueCommand]
    ) throws {
        try budget.visit(value, depth: depth)
        switch value {
        case let .object(object):
            if let viewModel = object["youChatItemViewModel"]?.objectValue,
               let command = viewModel["sendUserQueryCommand"]
            {
                try commands.append(Self.parseFreeTextCommand(command))
            }
            if let inputViewModel = object["chatInputViewModel"]?.objectValue,
               let command = inputViewModel["sendUserQueryCommand"]
            {
                try commands.append(Self.parseFreeTextCommand(command))
            }
            for key in object.keys.sorted() {
                guard let nested = object[key] else { continue }
                try Self.collectFreeTextCommands(
                    in: nested,
                    depth: depth + 1,
                    budget: &budget,
                    commands: &commands
                )
            }
        case let .array(array):
            for nested in array {
                try Self.collectFreeTextCommands(
                    in: nested,
                    depth: depth + 1,
                    budget: &budget,
                    commands: &commands
                )
            }
        default:
            break
        }
    }

    static func parseFreeTextCommand(
        _ value: YouTubeAskJSONValue
    ) throws -> YouTubeAskOpaqueCommand {
        guard let command = value.objectValue,
              Set(command.keys) == ["innertubeCommand"],
              let innertubeCommand = command["innertubeCommand"]?.objectValue,
              Set(innertubeCommand.keys) == ["clickTrackingParams", "continuationCommand"],
              let clickTrackingParams = innertubeCommand["clickTrackingParams"]?.stringValue,
              !clickTrackingParams.isEmpty,
              clickTrackingParams.count <= YouTubeAskLimits.maximumCommandCharacters,
              let continuationCommand = innertubeCommand["continuationCommand"]?.objectValue,
              Set(continuationCommand.keys) == ["request", "token"],
              continuationCommand["request"]?.stringValue
              == "CONTINUATION_REQUEST_TYPE_GET_PANEL",
              let continuation = continuationCommand["token"]?.stringValue,
              !continuation.isEmpty,
              continuation.count <= YouTubeAskLimits.maximumCommandCharacters
        else {
            throw YouTubeAskCoreError.malformedChip
        }
        return YouTubeAskOpaqueCommand(
            continuation: continuation,
            clickTrackingParams: clickTrackingParams
        )
    }

    static func unambiguousFreeTextCommand(
        _ commands: [YouTubeAskOpaqueCommand]
    ) throws -> YouTubeAskOpaqueCommand? {
        guard let first = commands.first else { return nil }
        guard commands.dropFirst().allSatisfy({ command in
            Self.freeTextCommandsMatch(first, command)
        }) else {
            throw YouTubeAskCoreError.ambiguousBootstrap
        }
        return first
    }

    static func freeTextCommandsMatch(
        _ lhs: YouTubeAskOpaqueCommand?,
        _ rhs: YouTubeAskOpaqueCommand?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.continuation == rhs.continuation
                && lhs.clickTrackingParams == rhs.clickTrackingParams
        default:
            false
        }
    }
}
