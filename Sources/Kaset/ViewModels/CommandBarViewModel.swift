import Foundation
import Observation

@available(macOS 26.0, *)
@MainActor
@Observable
final class CommandBarViewModel {
    enum Phase: String, Equatable {
        case idle
        case localCommand
        case aiParsing
        case executing
        case fallback
    }

    enum FallbackReason: String, Equatable {
        case aiUnavailable
        case unsupportedLocale
        case timedOut
        case decodingFailure
        case sessionBusy
        case contextWindowExceeded
        case modelNotReady
        case unknown
    }

    struct AIClient {
        let refreshAvailability: @Sendable @MainActor () -> Void
        let isAvailable: @Sendable @MainActor () -> Bool
        let supportsCurrentLocale: @Sendable @MainActor () -> Bool
        let prewarm: @Sendable @MainActor (_ promptPrefix: String) -> Void
        let resolveIntent: @Sendable (_ query: String, _ instructions: String) async throws -> MusicIntent

        static var live: Self {
            Self(
                refreshAvailability: {
                    FoundationModelsService.shared.refreshAvailability()
                },
                isAvailable: {
                    FoundationModelsService.shared.isAvailable
                },
                supportsCurrentLocale: {
                    FoundationModelsService.shared.supportsLocale(Locale.current)
                },
                prewarm: { promptPrefix in
                    FoundationModelsService.shared.prewarmCommandBar(promptPrefix: promptPrefix)
                },
                resolveIntent: { query, instructions in
                    try await FoundationModelsService.shared.resolveCommandIntent(
                        query: query,
                        instructions: instructions
                    )
                }
            )
        }
    }

    typealias SearchRouter = @MainActor (_ query: String) async -> Void
    typealias DismissAction = @MainActor () -> Void

    var inputText = ""
    private(set) var isProcessing = false
    private(set) var isInteractionDisabled = false
    private(set) var errorMessage: String?
    private(set) var resultMessage: String?
    private(set) var phase: Phase = .idle
    private(set) var lastFallbackReason: FallbackReason?

    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private let parser = CommandIntentParser()
    @ObservationIgnored private let executor: CommandExecutor
    @ObservationIgnored private let searchRouter: SearchRouter
    @ObservationIgnored private let dismissAction: DismissAction
    @ObservationIgnored private let aiClient: AIClient
    @ObservationIgnored private let requestTimeout: Duration
    @ObservationIgnored private let autoDismissDelay: Duration

    private let logger = DiagnosticsLogger.ai
    private let aiPromptVersion: FoundationModelsPromptVersion

    private var aiSystemInstructions: String {
        FoundationModelsPromptLibrary.commandBarInstructions(version: self.aiPromptVersion)
    }

    init(
        client: any YTMusicClientProtocol,
        playerService: any PlayerServiceProtocol,
        searchRouter: @escaping SearchRouter,
        dismissAction: @escaping DismissAction,
        aiClient: AIClient = .live,
        requestTimeout: Duration = .seconds(12),
        autoDismissDelay: Duration = .seconds(1),
        aiPromptVersion: FoundationModelsPromptVersion = .current
    ) {
        self.executor = CommandExecutor(client: client, playerService: playerService)
        self.searchRouter = searchRouter
        self.dismissAction = dismissAction
        self.aiClient = aiClient
        self.requestTimeout = requestTimeout
        self.autoDismissDelay = autoDismissDelay
        self.aiPromptVersion = aiPromptVersion
    }

    func handleAppear() {
        self.aiClient.refreshAvailability()
        self.aiClient.prewarm(self.aiSystemInstructions)
    }

    func submit() {
        let query = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard self.requestTask == nil else {
            self.logger.warning("Ignoring overlapping command bar request")
            return
        }

        self.startRequest()

        self.requestTask = Task { [weak self] in
            guard let self else { return }
            await self.process(query: query)
        }
    }

    func executeSuggestion(_ command: String) {
        guard self.requestTask == nil else { return }
        self.inputText = command
        self.submit()
    }

    func dismiss() {
        self.cancelActiveRequest()
        self.dismissAction()
    }

    func cancelActiveRequest() {
        self.requestTask?.cancel()
        self.finishRequest()
    }

    private func process(query: String) async {
        self.logger.info("Processing command: \(query)")
        self.logger.debug("Using Foundation Models command prompt version \(self.aiPromptVersion.logDescription)")

        defer {
            self.finishRequest()
        }

        if let localRequest = self.parser.deterministicRequest(for: query) {
            self.phase = .localCommand
            await self.applyOutcome(self.executor.execute(localRequest))
            return
        }

        self.aiClient.refreshAvailability()

        guard self.aiClient.isAvailable() else {
            await self.handleFallback(query: query, reason: .aiUnavailable)
            return
        }

        guard self.aiClient.supportsCurrentLocale() else {
            await self.handleFallback(query: query, reason: .unsupportedLocale)
            return
        }

        do {
            self.phase = .aiParsing
            let intent = try await self.resolveIntent(query: query)
            self.phase = .executing
            await self.applyOutcome(self.executor.execute(.musicIntent(intent)))
        } catch {
            let handledError = AIErrorHandler.handle(error)

            switch handledError {
            case .cancelled:
                self.logger.info("Command processing cancelled")
            case .timedOut:
                await self.handleFallback(query: query, reason: .timedOut)
            case .decodingFailure:
                await self.handleFallback(query: query, reason: .decodingFailure)
            case .sessionBusy:
                await self.handleFallback(query: query, reason: .sessionBusy)
            case .contextWindowExceeded:
                await self.handleFallback(query: query, reason: .contextWindowExceeded)
            case .modelNotReady:
                await self.handleFallback(query: query, reason: .modelNotReady)
            case .notAvailable:
                await self.handleFallback(query: query, reason: .aiUnavailable)
            case .contentBlocked, .unknown:
                if let message = AIErrorHandler.handleAndMessage(error, context: "command processing") {
                    self.errorMessage = message
                }
            }
        }
    }

    private func resolveIntent(query: String) async throws -> MusicIntent {
        let resolveIntent = self.aiClient.resolveIntent
        let instructions = self.aiSystemInstructions
        let requestTimeout = self.requestTimeout

        return try await withThrowingTaskGroup(of: MusicIntent.self) { group in
            group.addTask {
                try await resolveIntent(query, instructions)
            }
            group.addTask {
                try await Task.sleep(for: requestTimeout)
                throw AIError.timedOut
            }

            let intent = try await group.next()!
            group.cancelAll()
            return intent
        }
    }

    private func handleFallback(query: String, reason: FallbackReason) async {
        self.phase = .fallback
        self.lastFallbackReason = reason
        self.logger.info("Falling back from AI for command '\(query)' due to \(reason.rawValue)")
        await self.applyOutcome(self.executor.execute(self.parser.fallbackRequest(for: query)))
    }

    private func applyOutcome(_ outcome: CommandExecutor.Outcome) async {
        self.isProcessing = false

        if let errorMessage = outcome.errorMessage {
            self.errorMessage = errorMessage
            return
        }

        if let searchQuery = outcome.searchQueryToOpen {
            await self.searchRouter(searchQuery)
            return
        }

        if let resultMessage = outcome.resultMessage {
            self.resultMessage = resultMessage
        }

        guard outcome.shouldDismiss else { return }

        try? await Task.sleep(for: self.autoDismissDelay)
        guard !Task.isCancelled else { return }
        self.dismissAction()
    }

    private func startRequest() {
        self.isProcessing = true
        self.isInteractionDisabled = true
        self.errorMessage = nil
        self.resultMessage = nil
        self.lastFallbackReason = nil
        self.phase = .idle
    }

    private func finishRequest() {
        self.requestTask = nil
        self.isProcessing = false
        self.isInteractionDisabled = false
        self.phase = .idle
    }
}
