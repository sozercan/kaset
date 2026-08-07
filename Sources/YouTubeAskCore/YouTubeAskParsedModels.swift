import Foundation

// MARK: - YouTubeAskParsedSuggestion

package struct YouTubeAskParsedSuggestion: Sendable {
    package let label: String
    package let command: YouTubeAskOpaqueCommand
}

// MARK: - YouTubeAskParsedBootstrap

package struct YouTubeAskParsedBootstrap: Sendable {
    package let panelCommand: YouTubeAskOpaqueCommand?
    package let freeTextCommand: YouTubeAskOpaqueCommand?
    package let suggestions: [YouTubeAskParsedSuggestion]
}

// MARK: - YouTubeAskParsedMessage

package struct YouTubeAskParsedMessage: Sendable {
    package let text: String
    package let wasTruncated: Bool
}

// MARK: - YouTubeAskParsedConversation

package struct YouTubeAskParsedConversation: Sendable {
    package let messages: [YouTubeAskParsedMessage]
    package let suggestions: [YouTubeAskParsedSuggestion]
    package let freeTextCommand: YouTubeAskOpaqueCommand?
}
