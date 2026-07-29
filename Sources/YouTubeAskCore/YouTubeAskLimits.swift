import Foundation

package enum YouTubeAskLimits {
    package static let maximumResponseBytes = 32 * 1024 * 1024
    package static let maximumFrameBytes = 4 * 1024 * 1024
    package static let maximumFrames = 256
    package static let maximumChipCharacters = 200
    package static let maximumAnswerCharacters = 16000

    static let maximumTreeDepth = 80
    static let maximumTreeNodes = 100_000
    static let maximumChildrenPerContainer = 2048
    static let maximumCommandCharacters = 64 * 1024
}
