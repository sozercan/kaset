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
}
