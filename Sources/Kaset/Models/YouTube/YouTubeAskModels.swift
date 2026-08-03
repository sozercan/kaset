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
    let wasTruncated: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        wasTruncated: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.wasTruncated = wasTruncated
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
    private let freeTextCommand: YouTubeAskOpaqueCommand?
    private let suggestionStates: [YouTubeAskSuggestionState]
    private let binding: YouTubeAskBindingState

    var requiresPanelMaterialization: Bool {
        self.panelCommand != nil
            && (self.suggestions.isEmpty || self.freeTextCommand == nil)
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
        self.freeTextCommand = parsed.freeTextCommand
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
            freeTextCommand: self.freeTextCommand,
            binding: self.binding
        )
    }

    var materializationCommand: YouTubeAskOpaqueCommand? {
        self.panelCommand
    }

    fileprivate var freeTextSubmissionCommand: YouTubeAskOpaqueCommand? {
        self.freeTextCommand
    }

    fileprivate var initialSuggestionStates: [YouTubeAskSuggestionState] {
        self.suggestionStates
    }

    var hasFreeTextCommand: Bool {
        self.freeTextCommand != nil
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

    static func testing(
        suggestions: [String],
        allowsFreeText: Bool = false
    ) -> YouTubeAskBootstrap {
        YouTubeAskBootstrap(
            videoID: "fixture-video",
            suggestions: suggestions,
            allowsFreeText: allowsFreeText
        )
    }

    private init(videoID: String, suggestions: [String], allowsFreeText: Bool) {
        let suggestionStates = suggestions.enumerated().map { index, text in
            YouTubeAskSuggestionState(
                visible: YouTubeAskSuggestion(text: text),
                command: YouTubeAskOpaqueCommand("fixture-suggestion-\(index)")
            )
        }
        self.videoID = videoID
        self.suggestions = suggestionStates.map(\.visible)
        self.panelCommand = nil
        self.freeTextCommand = allowsFreeText
            ? YouTubeAskOpaqueCommand(
                continuation: "fixture-free-text-continuation",
                clickTrackingParams: "fixture-click-tracking"
            )
            : nil
        self.suggestionStates = suggestionStates
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
    private let freeTextCommand: YouTubeAskOpaqueCommand?
    private let binding: YouTubeAskBindingState?
    private let pendingSuggestionID: YouTubeAskSuggestion.ID?
    private let pendingFreeTextInput: String?

    var hasStarted: Bool {
        self.messages.contains { $0.role == .user }
    }

    var canSubmitFreeText: Bool {
        self.binding != nil
            && self.freeTextCommand != nil
            && self.pendingSuggestionID == nil
            && self.pendingFreeTextInput == nil
    }

    fileprivate init(
        messages: [YouTubeAskMessage],
        suggestionStates: [YouTubeAskSuggestionState],
        freeTextCommand: YouTubeAskOpaqueCommand?,
        binding: YouTubeAskBindingState
    ) {
        self.id = binding.conversationID
        self.revision = binding.revision
        self.messages = messages
        self.suggestions = suggestionStates.map(\.visible)
        self.suggestionStates = suggestionStates
        self.freeTextCommand = freeTextCommand
        self.binding = binding
        self.pendingSuggestionID = nil
        self.pendingFreeTextInput = nil
    }

    fileprivate init(
        previousMessages: [YouTubeAskMessage],
        parsed: YouTubeAskParsedConversation,
        binding: YouTubeAskBindingState,
        freeTextCommand: YouTubeAskOpaqueCommand? = nil
    ) {
        let suggestionStates = parsed.suggestions.map { parsedSuggestion in
            YouTubeAskSuggestionState(
                visible: YouTubeAskSuggestion(text: parsedSuggestion.label),
                command: parsedSuggestion.command
            )
        }
        let assistantMessages = parsed.messages.map { parsedMessage in
            YouTubeAskMessage(
                role: .assistant,
                text: parsedMessage.text,
                wasTruncated: parsedMessage.wasTruncated
            )
        }
        self.init(
            messages: previousMessages + assistantMessages,
            suggestionStates: suggestionStates,
            freeTextCommand: freeTextCommand,
            binding: binding
        )
    }

    func appendingUserTurn(for suggestionID: YouTubeAskSuggestion.ID) -> YouTubeAskConversation? {
        guard self.pendingSuggestionID == nil,
              self.pendingFreeTextInput == nil,
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
            freeTextCommand: self.freeTextCommand,
            binding: self.binding,
            pendingSuggestionID: suggestionID,
            pendingFreeTextInput: nil
        )
    }

    func appendingUserTurn(text: String) -> YouTubeAskConversation? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.canSubmitFreeText,
              !trimmedText.isEmpty,
              trimmedText.count <= YouTubeAskLimits.maximumUserInputCharacters,
              trimmedText.utf8.count <= YouTubeAskLimits.maximumUserInputBytes
        else {
            return nil
        }
        return YouTubeAskConversation(
            id: self.id,
            revision: self.revision,
            messages: self.messages + [YouTubeAskMessage(role: .user, text: trimmedText)],
            suggestions: self.suggestions,
            suggestionStates: self.suggestionStates,
            freeTextCommand: self.freeTextCommand,
            binding: self.binding,
            pendingSuggestionID: nil,
            pendingFreeTextInput: trimmedText
        )
    }

    func pendingFreeTextSubmission(
        matching userInputText: String
    ) -> (command: YouTubeAskOpaqueCommand, userInputText: String)? {
        let trimmedInput = userInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pendingFreeTextInput = self.pendingFreeTextInput,
              pendingFreeTextInput == trimmedInput,
              let lastMessage = self.messages.last,
              case .user = lastMessage.role,
              lastMessage.text == pendingFreeTextInput,
              let command = self.freeTextCommand
        else {
            return nil
        }
        return (command: command, userInputText: pendingFreeTextInput)
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
            freeTextCommand: nil,
            binding: nil,
            pendingSuggestionID: nil,
            pendingFreeTextInput: nil
        )
    }

    private init(
        id: UUID,
        revision: UInt64,
        messages: [YouTubeAskMessage],
        suggestions: [YouTubeAskSuggestion],
        suggestionStates: [YouTubeAskSuggestionState],
        freeTextCommand: YouTubeAskOpaqueCommand?,
        binding: YouTubeAskBindingState?,
        pendingSuggestionID: YouTubeAskSuggestion.ID?,
        pendingFreeTextInput: String?
    ) {
        self.id = id
        self.revision = revision
        self.messages = messages
        self.suggestions = suggestions
        self.suggestionStates = suggestionStates
        self.freeTextCommand = freeTextCommand
        self.binding = binding
        self.pendingSuggestionID = pendingSuggestionID
        self.pendingFreeTextInput = pendingFreeTextInput
    }

    static func testing(
        messages: [YouTubeAskMessage] = [],
        suggestions: [String] = [],
        allowsFreeText: Bool = false
    ) -> YouTubeAskConversation {
        let id = UUID()
        let revision: UInt64 = messages.isEmpty ? 0 : 1
        let binding = allowsFreeText
            ? YouTubeAskBindingState(
                videoID: "fixture-video",
                authenticationGeneration: 0,
                accountBinding: YouTubeAskAccountBinding(scopeID: "fixture-scope"),
                clientGeneration: 0,
                conversationID: id,
                revision: revision
            )
            : nil
        return YouTubeAskConversation(
            id: id,
            revision: revision,
            messages: messages,
            suggestions: suggestions.map { YouTubeAskSuggestion(text: $0) },
            suggestionStates: [],
            freeTextCommand: allowsFreeText
                ? YouTubeAskOpaqueCommand(
                    continuation: "fixture-free-text-continuation",
                    clickTrackingParams: "fixture-click-tracking"
                )
                : nil,
            binding: binding,
            pendingSuggestionID: nil,
            pendingFreeTextInput: nil
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
    ) -> YouTubeAskConversation? {
        let bootstrapCommand = bootstrap.freeTextSubmissionCommand
        let materializedCommand = parsed.freeTextCommand
        if let bootstrapCommand, let materializedCommand,
           bootstrapCommand != materializedCommand
        {
            return nil
        }
        let resolvedCommand = materializedCommand ?? bootstrapCommand

        if parsed.suggestions.isEmpty {
            let assistantMessages = parsed.messages.map { parsedMessage in
                YouTubeAskMessage(
                    role: .assistant,
                    text: parsedMessage.text,
                    wasTruncated: parsedMessage.wasTruncated
                )
            }
            return YouTubeAskConversation(
                messages: assistantMessages,
                suggestionStates: bootstrap.initialSuggestionStates,
                freeTextCommand: resolvedCommand,
                binding: bootstrap.bindingState
            )
        }
        return YouTubeAskConversation(
            previousMessages: [],
            parsed: parsed,
            binding: bootstrap.bindingState,
            freeTextCommand: resolvedCommand
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
            binding: binding.advanced(),
            freeTextCommand: parsed.freeTextCommand ?? conversation.freeTextCommand
        )
    }

    static func direct(from bootstrap: YouTubeAskBootstrap) -> YouTubeAskConversation {
        bootstrap.makeDirectConversation()
    }
}
