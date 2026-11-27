import Foundation

package struct YouTubeAskParsedSuggestion: Sendable {
    package let label: String
    package let command: YouTubeAskOpaqueCommand
}

package struct YouTubeAskParsedBootstrap: Sendable {
    package let panelCommand: YouTubeAskOpaqueCommand?
    package let freeTextCommand: YouTubeAskOpaqueCommand?
    package let suggestions: [YouTubeAskParsedSuggestion]
}

package struct YouTubeAskParsedMessage: Sendable {
    package let text: String
    package let wasTruncated: Bool
}

package struct YouTubeAskParsedConversation: Sendable {
    package let messages: [YouTubeAskParsedMessage]
    package let suggestions: [YouTubeAskParsedSuggestion]
    package let freeTextCommand: YouTubeAskOpaqueCommand?
}
