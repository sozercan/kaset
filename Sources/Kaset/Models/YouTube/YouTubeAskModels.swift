import Foundation
import YouTubeAskCore

// MARK: - YouTubeAskAccountBinding

/// Opaque, in-memory identity for the confirmed primary account that owns one
/// Ask conversation. The scope is never persisted, logged, or shown to users.
struct YouTubeAskAccountBinding: Equatable, Sendable {
    fileprivate let scopeID: String

    init(scopeID: String) {
        self.scopeID = scopeID
    }
}

// MARK: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable

extension YouTubeAskAccountBinding: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "<redacted YouTube Ask account binding>"
    }

    var debugDescription: String {
        self.description
    }

    var customMirror: Mirror {
        Mirror(reflecting: self.description)
    }
}

// MARK: - YouTubeAskSuggestion

struct YouTubeAskSuggestion: Identifiable, Sendable {
    // swiftlint:disable:next type_name
    struct ID: Hashable, Sendable {
        fileprivate let rawValue: UUID

        init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }

        var accessibilityIdentifierComponent: String {
            self.rawValue.uuidString
        }
    }

    let id: ID
    let text: String
}

// MARK: - YouTubeAskMessage

struct YouTubeAskMessage: Identifiable, Sendable {
    enum Role: Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

// MARK: - YouTubeAskBindingState

private struct YouTubeAskBindingState: Sendable {
    let videoID: String
    let authenticationGeneration: UInt64
    let accountBinding: YouTubeAskAccountBinding
    let clientGeneration: UInt64
    let conversationID: UUID
    let revision: UInt64

    func advanced() -> YouTubeAskBindingState {
        YouTubeAskBindingState(
            videoID: self.videoID,
            authenticationGeneration: self.authenticationGeneration,
            accountBinding: self.accountBinding,
            clientGeneration: self.clientGeneration,
            conversationID: self.conversationID,
            revision: self.revision &+ 1
        )
    }
}

// MARK: - YouTubeAskSuggestionState

private struct YouTubeAskSuggestionState: Sendable {
    let visible: YouTubeAskSuggestion
    let command: YouTubeAskOpaqueCommand
}

// MARK: - YouTubeAskBootstrap

struct YouTubeAskBootstrap: Sendable {
    let videoID: String
    let suggestions: [YouTubeAskSuggestion]

    private let panelCommand: YouTubeAskOpaqueCommand?
    private let suggestionStates: [YouTubeAskSuggestionState]
    private let binding: YouTubeAskBindingState

    var requiresPanelMaterialization: Bool {
        self.suggestions.isEmpty && self.panelCommand != nil
    }

    fileprivate init(
        videoID: String,
        parsed: YouTubeAskParsedBootstrap,
        authenticationGeneration: UInt64,
        accountBinding: YouTubeAskAccountBinding,
        clientGeneration: UInt64,
        conversationID: UUID = UUID()
    ) {
        let suggestionStates = parsed.suggestions.map { parsedSuggestion in
            YouTubeAskSuggestionState(
                visible: YouTubeAskSuggestion(text: parsedSuggestion.label),
                command: parsedSuggestion.command
            )
        }
        self.videoID = videoID
        self.suggestions = suggestionStates.map(\.visible)
        self.panelCommand = parsed.panelCommand
        self.suggestionStates = suggestionStates
        self.binding = YouTubeAskBindingState(
            videoID: videoID,
            authenticationGeneration: authenticationGeneration,
            accountBinding: accountBinding,
            clientGeneration: clientGeneration,
            conversationID: conversationID,
            revision: 0
        )
    }

    fileprivate func makeDirectConversation() -> YouTubeAskConversation {
        YouTubeAskConversation(
            messages: [],
            suggestionStates: self.suggestionStates,
            binding: self.binding
        )
    }

    var materializationCommand: YouTubeAskOpaqueCommand? {
        self.panelCommand
    }

    var conversationID: UUID {
        self.binding.conversationID
    }

    func isBound(
        toVideoID videoID: String,
        authenticationGeneration: UInt64,
        accountBinding: YouTubeAskAccountBinding,
        clientGeneration: UInt64
    ) -> Bool {
        self.binding.videoID == videoID
            && self.binding.authenticationGeneration == authenticationGeneration
            && self.binding.accountBinding == accountBinding
            && self.binding.clientGeneration == clientGeneration
            && self.binding.revision == 0
    }

    fileprivate var bindingState: YouTubeAskBindingState {
        self.binding
    }

    static func testing(suggestions: [String]) -> YouTubeAskBootstrap {
        YouTubeAskBootstrap(
            videoID: "fixture-video",
            suggestions: suggestions
        )
    }

    private init(videoID: String, suggestions: [String]) {
        self.videoID = videoID
        self.suggestions = suggestions.map { YouTubeAskSuggestion(text: $0) }
        self.panelCommand = nil
        self.suggestionStates = []
        self.binding = YouTubeAskBindingState(
            videoID: videoID,
            authenticationGeneration: 0,
            accountBinding: YouTubeAskAccountBinding(scopeID: "fixture-scope"),
            clientGeneration: 0,
            conversationID: UUID(),
            revision: 0
        )
    }
}

// MARK: - YouTubeAskConversation

struct YouTubeAskConversation: Sendable {
    let id: UUID
    let revision: UInt64
    let messages: [YouTubeAskMessage]
    let suggestions: [YouTubeAskSuggestion]

    private let suggestionStates: [YouTubeAskSuggestionState]
    private let binding: YouTubeAskBindingState?
    private let pendingSuggestionID: YouTubeAskSuggestion.ID?

    var hasStarted: Bool {
        self.messages.contains { $0.role == .user }
    }

    fileprivate init(
        messages: [YouTubeAskMessage],
        suggestionStates: [YouTubeAskSuggestionState],
        binding: YouTubeAskBindingState
    ) {
        self.id = binding.conversationID
        self.revision = binding.revision
        self.messages = messages
        self.suggestions = suggestionStates.map(\.visible)
        self.suggestionStates = suggestionStates
        self.binding = binding
        self.pendingSuggestionID = nil
    }

    fileprivate init(
        previousMessages: [YouTubeAskMessage],
        parsed: YouTubeAskParsedConversation,
        binding: YouTubeAskBindingState
    ) {
        let suggestionStates = parsed.suggestions.map { parsedSuggestion in
            YouTubeAskSuggestionState(
                visible: YouTubeAskSuggestion(text: parsedSuggestion.label),
                command: parsedSuggestion.command
            )
        }
        let assistantMessages = parsed.messages.map { parsedMessage in
            YouTubeAskMessage(role: .assistant, text: parsedMessage.text)
        }
        self.init(
            messages: previousMessages + assistantMessages,
            suggestionStates: suggestionStates,
            binding: binding
        )
    }

    func appendingUserTurn(for suggestionID: YouTubeAskSuggestion.ID) -> YouTubeAskConversation? {
        guard self.pendingSuggestionID == nil,
              let selected = self.suggestions.first(where: { $0.id == suggestionID })
        else {
            return nil
        }
        return YouTubeAskConversation(
            id: self.id,
            revision: self.revision,
            messages: self.messages + [YouTubeAskMessage(role: .user, text: selected.text)],
            suggestions: self.suggestions,
            suggestionStates: self.suggestionStates,
            binding: self.binding,
            pendingSuggestionID: suggestionID
        )
    }

    func command(for suggestionID: YouTubeAskSuggestion.ID) -> YouTubeAskOpaqueCommand? {
        guard self.pendingSuggestionID == suggestionID else { return nil }
        return self.suggestionStates.first(where: { $0.visible.id == suggestionID })?.command
    }

    fileprivate var bindingState: YouTubeAskBindingState? {
        self.binding
    }

    var boundVideoID: String? {
        self.binding?.videoID
    }

    func isBound(
        toVideoID videoID: String,
        authenticationGeneration: UInt64,
        accountBinding: YouTubeAskAccountBinding,
        clientGeneration: UInt64
    ) -> Bool {
        guard let binding = self.binding else { return false }
        return binding.videoID == videoID
            && binding.authenticationGeneration == authenticationGeneration
            && binding.accountBinding == accountBinding
            && binding.clientGeneration == clientGeneration
            && binding.conversationID == self.id
            && binding.revision == self.revision
    }

    func discardingOpaqueState() -> YouTubeAskConversation {
        YouTubeAskConversation(
            id: self.id,
            revision: self.revision,
            messages: self.messages,
            suggestions: [],
            suggestionStates: [],
            binding: nil,
            pendingSuggestionID: nil
        )
    }

    private init(
        id: UUID,
        revision: UInt64,
        messages: [YouTubeAskMessage],
        suggestions: [YouTubeAskSuggestion],
        suggestionStates: [YouTubeAskSuggestionState],
        binding: YouTubeAskBindingState?,
        pendingSuggestionID: YouTubeAskSuggestion.ID?
    ) {
        self.id = id
        self.revision = revision
        self.messages = messages
        self.suggestions = suggestions
        self.suggestionStates = suggestionStates
        self.binding = binding
        self.pendingSuggestionID = pendingSuggestionID
    }

    static func testing(
        messages: [YouTubeAskMessage] = [],
        suggestions: [String] = []
    ) -> YouTubeAskConversation {
        YouTubeAskConversation(
            id: UUID(),
            revision: messages.isEmpty ? 0 : 1,
            messages: messages,
            suggestions: suggestions.map { YouTubeAskSuggestion(text: $0) },
            suggestionStates: [],
            binding: nil,
            pendingSuggestionID: nil
        )
    }
}

// MARK: - YouTubeAskBootstrap + CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable

extension YouTubeAskBootstrap: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "<redacted YouTube Ask bootstrap>"
    }

    var debugDescription: String {
        self.description
    }

    var customMirror: Mirror {
        Mirror(reflecting: self.description)
    }
}

// MARK: - YouTubeAskConversation + CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable

extension YouTubeAskConversation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "<redacted YouTube Ask conversation>"
    }

    var debugDescription: String {
        self.description
    }

    var customMirror: Mirror {
        Mirror(reflecting: self.description)
    }
}

// MARK: - YouTubeAskSuggestion Convenience

private extension YouTubeAskSuggestion {
    init(text: String) {
        self.init(id: ID(), text: text)
    }
}

// MARK: - YouTubeAskClientError

enum YouTubeAskClientError: Error, Equatable, Sendable {
    case authenticationRequired
    case sessionChanged
    case rateLimited
    case responseTooLarge
    case invalidResponse
    case unavailable
}

// MARK: - YouTubeAskPresentationError

enum YouTubeAskPresentationError: Equatable, Sendable {
    case authentication
    case rateLimited
    case preparation
    case restartRequired
}

// MARK: - YouTubeAsk Production Support

extension YouTubeAskBootstrap {
    static func production(
        videoID: String,
        parsed: YouTubeAskParsedBootstrap,
        authenticationGeneration: UInt64,
        accountBinding: YouTubeAskAccountBinding,
        clientGeneration: UInt64
    ) -> YouTubeAskBootstrap {
        YouTubeAskBootstrap(
            videoID: videoID,
            parsed: parsed,
            authenticationGeneration: authenticationGeneration,
            accountBinding: accountBinding,
            clientGeneration: clientGeneration
        )
    }
}

extension YouTubeAskConversation {
    static func materialized(
        from bootstrap: YouTubeAskBootstrap,
        parsed: YouTubeAskParsedConversation
    ) -> YouTubeAskConversation {
        YouTubeAskConversation(
            previousMessages: [],
            parsed: parsed,
            binding: bootstrap.bindingState
        )
    }

    static func continued(
        from conversation: YouTubeAskConversation,
        parsed: YouTubeAskParsedConversation
    ) -> YouTubeAskConversation? {
        guard let binding = conversation.bindingState else { return nil }
        return YouTubeAskConversation(
            previousMessages: conversation.messages,
            parsed: parsed,
            binding: binding.advanced()
        )
    }

    static func direct(from bootstrap: YouTubeAskBootstrap) -> YouTubeAskConversation {
        bootstrap.makeDirectConversation()
    }
}
