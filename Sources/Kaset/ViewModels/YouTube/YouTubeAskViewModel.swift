import Foundation
import Observation
import YouTubeAskCore

/// Owns one watch-scoped Ask Gemini conversation and every task that can mutate it.
@MainActor
@Observable
final class YouTubeAskViewModel {
    enum Activity: Equatable {
        case idle
        case preparing
        case sending
    }

    enum AccessibilityAnnouncement: Equatable {
        case responseReady
        case newChatReady
    }

    let videoID: String
    let client: any YouTubeClientProtocol

    private(set) var isAvailable = false
    private(set) var isExpanded = false
    private(set) var activity: Activity = .idle
    private(set) var conversation: YouTubeAskConversation?
    private(set) var presentationError: YouTubeAskPresentationError?
    private(set) var requiresNewChat = false
    private(set) var accessibilityAnnouncement: AccessibilityAnnouncement?
    private(set) var accessibilityAnnouncementSequence = 0
    var inputText = ""

    private var bootstrap: YouTubeAskBootstrap?
    private var operationGeneration: UInt64 = 0
    @ObservationIgnored private var requestTask: Task<Void, Never>?

    init(videoID: String, client: any YouTubeClientProtocol) {
        self.videoID = videoID
        self.client = client
    }

    deinit {
        self.requestTask?.cancel()
    }

    var messages: [YouTubeAskMessage] {
        self.conversation?.messages ?? []
    }

    var suggestions: [YouTubeAskSuggestion] {
        self.conversation?.suggestions ?? []
    }

    var isBusy: Bool {
        self.activity != .idle
    }

    var hasStarted: Bool {
        self.conversation?.hasStarted == true
    }

    var canStartNewChat: Bool {
        self.isAvailable && (self.hasStarted || self.requiresNewChat)
    }

    var acceptsFreeTextInput: Bool {
        !self.isBusy
            && !self.requiresNewChat
            && self.conversation?.canSubmitFreeText == true
    }

    var canSubmitInput: Bool {
        let trimmedInput = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.acceptsFreeTextInput
            && !trimmedInput.isEmpty
            && trimmedInput.count <= YouTubeAskLimits.maximumUserInputCharacters
            && trimmedInput.utf8.count <= YouTubeAskLimits.maximumUserInputBytes
    }

    /// Replaces all prior state with a fresh watch-page bootstrap. The toolbar
    /// action remains hidden until eligibility is known, and presenting the panel
    /// materializes it lazily.
    func seed(_ bootstrap: YouTubeAskBootstrap?) {
        self.cancelCurrentOperation()
        self.bootstrap = bootstrap
        self.conversation = nil
        self.isAvailable = bootstrap != nil
        self.isExpanded = false
        self.activity = .idle
        self.presentationError = nil
        self.requiresNewChat = false
        self.accessibilityAnnouncement = nil
        self.inputText = ""
    }

    func toggleExpanded() {
        self.setExpanded(!self.isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        guard self.isAvailable else { return }
        self.isExpanded = expanded
        if expanded {
            self.prepareInitialConversationIfNeeded()
        }
    }

    func selectSuggestion(id suggestionID: YouTubeAskSuggestion.ID) {
        guard !self.isBusy,
              !self.requiresNewChat,
              let conversation = self.conversation,
              let pendingConversation = conversation.appendingUserTurn(for: suggestionID)
        else {
            return
        }

        self.presentationError = nil
        self.inputText = ""
        self.conversation = pendingConversation
        let generation = self.beginOperation(.sending)
        let client = self.client

        self.requestTask = Task { @MainActor [weak self, client, pendingConversation] in
            do {
                let nextConversation = try await client.continueAskConversation(
                    pendingConversation,
                    selecting: suggestionID
                )
                guard let self, self.operationGeneration == generation else { return }
                self.conversation = nextConversation
                self.requiresNewChat = false
                self.presentationError = nil
                self.inputText = ""
                self.finishOperation(generation: generation)
                self.publishAnnouncement(.responseReady)
            } catch is CancellationError {
                guard let self, self.operationGeneration == generation else { return }
                if Task.isCancelled {
                    self.finishOperation(generation: generation)
                    return
                }
                self.failSubmission(
                    pendingConversation: pendingConversation,
                    error: YouTubeAskClientError.sessionChanged,
                    generation: generation
                )
            } catch {
                guard let self, self.operationGeneration == generation else { return }
                self.failSubmission(
                    pendingConversation: pendingConversation,
                    error: error,
                    generation: generation
                )
            }
        }
    }

    func submitInput(playerOffsetMilliseconds: Int64) {
        guard !self.isBusy,
              !self.requiresNewChat,
              let conversation = self.conversation,
              let pendingConversation = conversation.appendingUserTurn(text: self.inputText),
              let submittedText = pendingConversation.messages.last?.text
        else {
            return
        }

        self.presentationError = nil
        self.inputText = ""
        self.conversation = pendingConversation
        let generation = self.beginOperation(.sending)
        let client = self.client

        self.requestTask = Task { @MainActor [weak self, client, pendingConversation] in
            do {
                let nextConversation = try await client.continueAskConversation(
                    pendingConversation,
                    submitting: submittedText,
                    playerOffsetMilliseconds: playerOffsetMilliseconds
                )
                guard let self, self.operationGeneration == generation else { return }
                self.conversation = nextConversation
                self.requiresNewChat = false
                self.presentationError = nil
                self.finishOperation(generation: generation)
                self.publishAnnouncement(.responseReady)
            } catch is CancellationError {
                guard let self, self.operationGeneration == generation else { return }
                if Task.isCancelled {
                    self.finishOperation(generation: generation)
                    return
                }
                self.failSubmission(
                    pendingConversation: pendingConversation,
                    error: YouTubeAskClientError.sessionChanged,
                    generation: generation
                )
            } catch {
                guard let self, self.operationGeneration == generation else { return }
                self.failSubmission(
                    pendingConversation: pendingConversation,
                    error: error,
                    generation: generation
                )
            }
        }
    }

    /// Prepares a fresh bootstrap and conversation transactionally. A usable
    /// current conversation stays visible unless the new one is fully ready.
    func startNewChat() {
        guard self.canStartNewChat, !self.isBusy else { return }

        self.presentationError = nil
        let generation = self.beginOperation(.preparing)
        let client = self.client
        let videoID = self.videoID

        self.requestTask = Task { @MainActor [weak self, client, videoID] in
            do {
                let page = try await client.getWatchPage(videoId: videoID)
                guard let bootstrap = page.askBootstrap else {
                    throw YouTubeAskClientError.unavailable
                }
                let newConversation = try await client.loadAskConversation(from: bootstrap)
                guard let self, self.operationGeneration == generation else { return }

                self.bootstrap = nil
                self.conversation = newConversation
                self.isAvailable = true
                self.requiresNewChat = false
                self.presentationError = nil
                self.inputText = ""
                self.finishOperation(generation: generation)
                self.publishAnnouncement(.newChatReady)
            } catch is CancellationError {
                guard let self, self.operationGeneration == generation else { return }
                if Task.isCancelled {
                    self.finishOperation(generation: generation)
                    return
                }
                self.failNewChat(
                    error: YouTubeAskClientError.sessionChanged,
                    generation: generation
                )
            } catch {
                guard let self, self.operationGeneration == generation else { return }
                self.failNewChat(error: error, generation: generation)
            }
        }
    }

    /// Cancels in-flight work and removes all visible and opaque conversation
    /// state. Called when the watch route or its account/auth scope goes away.
    func cancelAndDiscard() {
        self.cancelCurrentOperation()
        self.bootstrap = nil
        self.conversation = nil
        self.isAvailable = false
        self.isExpanded = false
        self.activity = .idle
        self.presentationError = nil
        self.requiresNewChat = false
        self.accessibilityAnnouncement = nil
        self.inputText = ""
    }

    private func prepareInitialConversationIfNeeded() {
        guard self.conversation == nil,
              !self.isBusy,
              let bootstrap = self.bootstrap
        else {
            return
        }

        self.presentationError = nil
        let generation = self.beginOperation(.preparing)
        let client = self.client

        self.requestTask = Task { @MainActor [weak self, client, bootstrap] in
            do {
                let conversation = try await client.loadAskConversation(from: bootstrap)
                guard let self, self.operationGeneration == generation else { return }
                self.bootstrap = nil
                self.conversation = conversation
                self.requiresNewChat = false
                self.presentationError = nil
                self.finishOperation(generation: generation)
            } catch is CancellationError {
                guard let self, self.operationGeneration == generation else { return }
                if Task.isCancelled {
                    self.finishOperation(generation: generation)
                    return
                }
                self.failInitialPreparation(
                    error: YouTubeAskClientError.sessionChanged,
                    generation: generation
                )
            } catch {
                guard let self, self.operationGeneration == generation else { return }
                self.failInitialPreparation(error: error, generation: generation)
            }
        }
    }

    private func failInitialPreparation(error: any Error, generation: UInt64) {
        self.bootstrap = nil
        self.conversation = nil
        self.requiresNewChat = true
        self.presentationError = Self.presentationError(for: error, duringPreparation: true)
        self.finishOperation(generation: generation)
    }

    private func failSubmission(
        pendingConversation: YouTubeAskConversation,
        error: any Error,
        generation: UInt64
    ) {
        self.bootstrap = nil
        self.conversation = pendingConversation.discardingOpaqueState()
        self.requiresNewChat = true
        self.presentationError = Self.presentationError(for: error, duringPreparation: false)
        self.finishOperation(generation: generation)
    }

    private func failNewChat(error: any Error, generation: UInt64) {
        if Self.invalidatesExistingSession(error) {
            self.bootstrap = nil
            self.conversation = self.conversation?.discardingOpaqueState()
            self.requiresNewChat = true
        }
        self.presentationError = Self.presentationError(for: error, duringPreparation: true)
        self.finishOperation(generation: generation)
    }

    private func beginOperation(_ activity: Activity) -> UInt64 {
        self.operationGeneration &+= 1
        self.activity = activity
        return self.operationGeneration
    }

    private func finishOperation(generation: UInt64) {
        guard self.operationGeneration == generation else { return }
        self.requestTask = nil
        self.activity = .idle
    }

    private func cancelCurrentOperation() {
        self.operationGeneration &+= 1
        self.requestTask?.cancel()
        self.requestTask = nil
    }

    private func publishAnnouncement(_ announcement: AccessibilityAnnouncement) {
        self.accessibilityAnnouncement = announcement
        self.accessibilityAnnouncementSequence &+= 1
    }

    private static func presentationError(
        for error: any Error,
        duringPreparation: Bool
    ) -> YouTubeAskPresentationError {
        if let askError = error as? YouTubeAskClientError {
            switch askError {
            case .authenticationRequired:
                return .authentication
            case .rateLimited:
                return .rateLimited
            case .sessionChanged:
                return duringPreparation ? .preparation : .restartRequired
            case .responseTooLarge, .invalidResponse, .unavailable:
                return duringPreparation ? .preparation : .restartRequired
            }
        }

        if let apiError = error as? YTMusicError {
            switch apiError {
            case .authExpired, .notAuthenticated:
                return .authentication
            default:
                return duringPreparation ? .preparation : .restartRequired
            }
        }

        return duringPreparation ? .preparation : .restartRequired
    }

    private static func invalidatesExistingSession(_ error: any Error) -> Bool {
        if let askError = error as? YouTubeAskClientError {
            switch askError {
            case .authenticationRequired, .sessionChanged:
                return true
            case .rateLimited, .responseTooLarge, .invalidResponse, .unavailable:
                return false
            }
        }

        if let apiError = error as? YTMusicError {
            switch apiError {
            case .authExpired, .notAuthenticated:
                return true
            default:
                return false
            }
        }

        return false
    }
}
