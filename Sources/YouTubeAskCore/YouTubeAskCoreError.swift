import Foundation

package enum YouTubeAskCoreError: Error, Equatable, Sendable {
    case decoderAlreadyFinished
    case responseTooLarge
    case emptyResponse
    case frameTooLarge
    case tooManyFrames
    case malformedWireResponse
    case duplicateJSONKey
    case unsupportedJSONRoot
    case structureLimitExceeded
    case ambiguousBootstrap
    case malformedChip
    case unsupportedChipDecorator
    case malformedMessage
    case invalidClientMessageID
    case invalidUserInput
    case requestTooLarge
    case missingFreeTextCommandContext
}
