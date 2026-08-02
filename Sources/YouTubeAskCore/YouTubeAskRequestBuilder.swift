import Foundation

package enum YouTubeAskRequestBuilder {
    package static func makePanelBootstrapBody(
        command: YouTubeAskOpaqueCommand
    ) -> Data {
        do {
            return try JSONEncoder().encode(
                PanelBootstrapBody(continuation: command.continuation)
            )
        } catch {
            preconditionFailure("Could not encode the fixed YouTube Ask bootstrap body")
        }
    }

    package static func makeDirectChipBody(
        command: YouTubeAskOpaqueCommand,
        clientMessageID: String
    ) throws -> Data {
        guard self.isValidClientMessageID(clientMessageID) else {
            throw YouTubeAskCoreError.invalidClientMessageID
        }

        let body = DirectChipBody(
            continuation: command.continuation,
            formData: FormData(
                inputComposerFormData: InputComposerFormData(
                    clientMessageId: clientMessageID
                )
            )
        )
        return try JSONEncoder().encode(body)
    }

    package static func makeFreeTextBody(
        command: YouTubeAskOpaqueCommand,
        clientMessageID: String,
        userInputText: String,
        playerOffsetMilliseconds: Int64
    ) throws -> Data {
        guard self.isValidClientMessageID(clientMessageID) else {
            throw YouTubeAskCoreError.invalidClientMessageID
        }
        let trimmedInput = userInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty,
              trimmedInput.count <= YouTubeAskLimits.maximumUserInputCharacters,
              trimmedInput.utf8.count <= YouTubeAskLimits.maximumUserInputBytes
        else {
            throw YouTubeAskCoreError.invalidUserInput
        }
        guard command.clickTrackingParams != nil else {
            throw YouTubeAskCoreError.missingFreeTextCommandContext
        }

        let body = FreeTextBody(
            continuation: command.continuation,
            formData: FreeTextFormData(
                inputComposerFormData: FreeTextInputComposerFormData(
                    clientMessageId: clientMessageID,
                    playerOffsetMs: String(max(0, playerOffsetMilliseconds)),
                    userInputText: trimmedInput
                )
            )
        )
        let data = try JSONEncoder().encode(body)
        try Self.validateRequestBodySize(data)
        return data
    }

    package static func makeFreeTextClickTrackingContext(
        command: YouTubeAskOpaqueCommand
    ) throws -> Data {
        guard let clickTrackingParams = command.clickTrackingParams else {
            throw YouTubeAskCoreError.missingFreeTextCommandContext
        }
        return try JSONEncoder().encode(ClickTrackingContext(
            clickTracking: ClickTracking(clickTrackingParams: clickTrackingParams)
        ))
    }

    package static func validateRequestBodySize(_ data: Data) throws {
        guard data.count <= YouTubeAskLimits.maximumRequestBodyBytes else {
            throw YouTubeAskCoreError.requestTooLarge
        }
    }

    private static func isValidClientMessageID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let prefix = Array("youchat-".utf8)
        guard bytes.count <= 64,
              bytes.count > prefix.count,
              bytes.starts(with: prefix)
        else {
            return false
        }
        return bytes.dropFirst(prefix.count).allSatisfy { byte in
            (0x30 ... 0x39).contains(byte)
        }
    }

    private struct PanelBootstrapBody: Encodable {
        let continuation: String
    }

    private struct DirectChipBody: Encodable {
        let continuation: String
        let formData: FormData
    }

    private struct FormData: Encodable {
        let inputComposerFormData: InputComposerFormData
    }

    private struct InputComposerFormData: Encodable {
        let clientMessageId: String
    }

    private struct FreeTextBody: Encodable {
        let continuation: String
        let formData: FreeTextFormData
    }

    private struct FreeTextFormData: Encodable {
        let inputComposerFormData: FreeTextInputComposerFormData
    }

    private struct FreeTextInputComposerFormData: Encodable {
        let clientMessageId: String
        let playerOffsetMs: String
        let userInputText: String
    }

    private struct ClickTrackingContext: Encodable {
        let clickTracking: ClickTracking
    }

    private struct ClickTracking: Encodable {
        let clickTrackingParams: String
    }
}
