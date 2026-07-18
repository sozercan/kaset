import Foundation
import Observation

// MARK: - CommandBarTimeoutRace

@available(macOS 26.0, *)
@MainActor
private final class CommandBarTimeoutRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        if let pendingResult {
            self.isResolved = true
            continuation.resume(with: pendingResult)
            self.pendingResult = nil
        } else {
            self.continuation = continuation
        }
    }

    func resolve(_ result: Result<Value, any Error>) {
        guard !self.isResolved else { return }
        guard let continuation else {
            self.pendingResult = result
            return
        }
        self.isResolved = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}

// MARK: - CommandBarViewModel

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
        let resolveCommand: @Sendable (_ query: String, _ instructions: String) async throws -> CommandBarParseResult
        let describeQueue:
            @Sendable (
                _ prompt: String,
                _ instructions: String,
                _ onPartial: @escaping @MainActor (QueueAnalysisSummary.PartiallyGenerated) -> Void
            ) async throws -> QueueAnalysisSummary
        let fittedQueueLineCount:
            @Sendable (
                _ lines: [String],
                _ totalTracks: Int,
                _ instructions: String,
                _ version: FoundationModelsPromptVersion
            ) async -> Int

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
                resolveCommand: { query, instructions in
                    try await FoundationModelsService.shared.resolveCommand(
                        query: query,
                        instructions: instructions
                    )
                },
                describeQueue: { prompt, instructions, onPartial in
                    try await FoundationModelsService.shared.analyzeQueue(
                        prompt: prompt,
                        instructions: instructions,
                        onPartial: onPartial
                    )
                },
                fittedQueueLineCount: { lines, totalTracks, instructions, version in
                    await FoundationModelsService.shared.fittedLineCount(
                        context: "queue description",
                        instructions: instructions,
                        lines: lines,
                        generationSchema: QueueAnalysisSummary.generationSchema
                    ) { candidateLines in
                        FoundationModelsPromptLibrary.queueDescriptionPrompt(
                            trackList: candidateLines.joined(separator: "\n"),
                            totalTracks: totalTracks,
                            shownTracks: candidateLines.count,
                            version: version
                        )
                    }
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
    @ObservationIgnored private var activeRequestID: UUID?
    @ObservationIgnored private let parser = CommandIntentParser()
    @ObservationIgnored private let executor: CommandExecutor
    @ObservationIgnored private let playerService: any PlayerServiceProtocol
    @ObservationIgnored private let searchRouter: SearchRouter
    @ObservationIgnored private let dismissAction: DismissAction
    @ObservationIgnored private let aiClient: AIClient
    @ObservationIgnored private let requestTimeout: Duration
    @ObservationIgnored private let queueDescriptionTimeout: Duration
    @ObservationIgnored private let autoDismissDelay: Duration

    private let logger = DiagnosticsLogger.ai
    private let aiPromptVersion: FoundationModelsPromptVersion

    private struct QueueSnapshot {
        let trackList: String
        let totalTracks: Int
        let shownTracks: Int
    }

    private var aiSystemInstructions: String {
        FoundationModelsPromptLibrary.commandBarInstructions(version: self.aiPromptVersion)
    }

    private var queueDescriptionInstructions: String {
        FoundationModelsPromptLibrary.queueDescriptionInstructions(version: self.aiPromptVersion)
    }

    init(
        client: any YTMusicClientProtocol,
        playerService: any PlayerServiceProtocol,
        searchRouter: @escaping SearchRouter,
        dismissAction: @escaping DismissAction,
        aiClient: AIClient = .live,
        requestTimeout: Duration = .seconds(12),
        queueDescriptionTimeout: Duration = .seconds(18),
        autoDismissDelay: Duration = .seconds(1),
        aiPromptVersion: FoundationModelsPromptVersion = .current
    ) {
        self.playerService = playerService
        self.executor = CommandExecutor(client: client, playerService: playerService)
        self.searchRouter = searchRouter
        self.dismissAction = dismissAction
        self.aiClient = aiClient
        self.requestTimeout = requestTimeout
        self.queueDescriptionTimeout = queueDescriptionTimeout
        self.autoDismissDelay = autoDismissDelay
        self.aiPromptVersion = aiPromptVersion
    }

    func handleAppear() {
        self.aiClient.refreshAvailability()
        self.aiClient.prewarm(self.aiSystemInstructions)
        self.aiClient.prewarm(self.queueDescriptionInstructions)
    }

    func submit() {
        let query = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard self.requestTask == nil else {
            self.logger.warning("Ignoring overlapping command bar request")
            return
        }

        let requestID = UUID()
        self.startRequest(id: requestID)
        let playbackReservation = self.playerService.reserveMusicPlaybackIntent()

        self.requestTask = Task { [weak self] in
            guard let self else { return }
            await self.process(
                query: query,
                playbackReservation: playbackReservation,
                requestID: requestID
            )
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
        guard let activeRequestID else { return }
        self.finishRequest(id: activeRequestID)
    }

    private func process(
        query: String,
        playbackReservation: MusicPlaybackReservation,
        requestID: UUID
    ) async {
        self.logger.info("Processing command: \(query)")
        self.logger.debug("Using Foundation Models command prompt version \(self.aiPromptVersion.logDescription)")

        defer {
            self.finishRequest(id: requestID)
        }

        if let localRequest = self.parser.deterministicRequest(for: query) {
            self.phase = .localCommand
            await self.applyOutcome(self.executor.execute(
                localRequest,
                reservation: playbackReservation
            ))
            return
        }

        if self.parser.isQueueInspectionQuery(query) {
            self.phase = .localCommand
            await self.describeQueue(requestID: requestID)
            return
        }

        self.aiClient.refreshAvailability()

        guard self.aiClient.isAvailable() else {
            await self.handleFallback(
                query: query,
                reason: .aiUnavailable,
                playbackReservation: playbackReservation
            )
            return
        }

        guard self.aiClient.supportsCurrentLocale() else {
            await self.handleFallback(
                query: query,
                reason: .unsupportedLocale,
                playbackReservation: playbackReservation
            )
            return
        }

        do {
            self.phase = .aiParsing
            let parsedCommand = try await self.resolveCommand(query: query)
            await self.executeParsedCommand(
                parsedCommand,
                originalQuery: query,
                playbackReservation: playbackReservation,
                requestID: requestID
            )
        } catch {
            let handledError = AIErrorHandler.handle(error)

            switch handledError {
            case .cancelled:
                self.logger.info("Command processing cancelled")
            case .timedOut:
                await self.handleFallback(query: query, reason: .timedOut, playbackReservation: playbackReservation)
            case .decodingFailure:
                await self.handleFallback(query: query, reason: .decodingFailure, playbackReservation: playbackReservation)
            case .sessionBusy:
                await self.handleFallback(query: query, reason: .sessionBusy, playbackReservation: playbackReservation)
            case .contextWindowExceeded:
                await self.handleFallback(query: query, reason: .contextWindowExceeded, playbackReservation: playbackReservation)
            case .modelNotReady:
                await self.handleFallback(query: query, reason: .modelNotReady, playbackReservation: playbackReservation)
            case .notAvailable:
                await self.handleFallback(query: query, reason: .aiUnavailable, playbackReservation: playbackReservation)
            case .contentBlocked, .unknown:
                if let message = AIErrorHandler.handleAndMessage(error, context: "command processing") {
                    self.errorMessage = message
                }
            }
        }
    }

    private func resolveCommand(query: String) async throws -> CommandBarParseResult {
        let resolveCommand = self.aiClient.resolveCommand
        let instructions = self.aiSystemInstructions
        return try await self.withHardTimeout(self.requestTimeout) {
            try await resolveCommand(query, instructions)
        }
    }

    private func executeParsedCommand(
        _ parsedCommand: CommandBarParseResult,
        originalQuery: String,
        playbackReservation: MusicPlaybackReservation,
        requestID: UUID
    ) async {
        if parsedCommand.isQueueInspection {
            await self.describeQueue(requestID: requestID)
            return
        }

        if let directRequest = parsedCommand.directRequest {
            self.phase = .executing
            await self.applyOutcome(self.executor.execute(
                directRequest,
                reservation: playbackReservation
            ))
            return
        }

        guard let intent = parsedCommand.musicIntent else {
            self.errorMessage = String(localized: "I couldn't understand that request")
            return
        }

        self.phase = .executing
        await self.applyOutcome(self.executor.execute(
            .musicIntent(intent, originalQuery: originalQuery),
            reservation: playbackReservation
        ))
    }

    private func describeQueue(requestID: UUID) async {
        guard !self.playerService.queue.isEmpty else {
            await self.applyOutcome(self.executor.describeQueueLocally())
            return
        }

        self.aiClient.refreshAvailability()

        guard self.aiClient.isAvailable() else {
            await self.applyLocalQueueDescription(reason: .aiUnavailable)
            return
        }

        guard self.aiClient.supportsCurrentLocale() else {
            await self.applyLocalQueueDescription(reason: .unsupportedLocale)
            return
        }

        do {
            self.phase = .aiParsing
            let summary = try await self.withHardTimeout(self.queueDescriptionTimeout) { [weak self] in
                guard let self, self.activeRequestID == requestID else {
                    throw CancellationError()
                }
                let queueSnapshot = await self.queueSnapshot(maxLimit: 20)
                guard self.activeRequestID == requestID else {
                    throw CancellationError()
                }
                return try await self.resolveQueueDescription(
                    queueSnapshot: queueSnapshot,
                    requestID: requestID
                )
            }
            self.phase = .executing
            await self.applyOutcome(.result(summary.displayText, shouldDismiss: false))
        } catch {
            let handledError = AIErrorHandler.handle(error)

            switch handledError {
            case .cancelled:
                self.logger.info("Queue description cancelled")
            case .timedOut:
                await self.applyLocalQueueDescription(reason: .timedOut)
            case .decodingFailure:
                await self.applyLocalQueueDescription(reason: .decodingFailure)
            case .sessionBusy:
                await self.applyLocalQueueDescription(reason: .sessionBusy)
            case .contextWindowExceeded:
                await self.applyLocalQueueDescription(reason: .contextWindowExceeded)
            case .modelNotReady:
                await self.applyLocalQueueDescription(reason: .modelNotReady)
            case .notAvailable:
                await self.applyLocalQueueDescription(reason: .aiUnavailable)
            case .contentBlocked, .unknown:
                await self.applyLocalQueueDescription(reason: .unknown)
            }
        }
    }

    private func resolveQueueDescription(
        queueSnapshot: QueueSnapshot,
        requestID: UUID
    ) async throws -> QueueAnalysisSummary {
        let describeQueue = self.aiClient.describeQueue
        let instructions = self.queueDescriptionInstructions
        let prompt = FoundationModelsPromptLibrary.queueDescriptionPrompt(
            trackList: queueSnapshot.trackList,
            totalTracks: queueSnapshot.totalTracks,
            shownTracks: queueSnapshot.shownTracks,
            version: self.aiPromptVersion
        )

        return try await describeQueue(prompt, instructions) { [weak self] partial in
            guard let self,
                  self.activeRequestID == requestID,
                  let displayText = partial.displayText
            else { return }
            self.resultMessage = displayText
        }
    }

    private func handleFallback(
        query: String,
        reason: FallbackReason,
        playbackReservation: MusicPlaybackReservation
    ) async {
        self.phase = .fallback
        self.lastFallbackReason = reason
        self.logger.info("Falling back from AI for command '\(query)' due to \(reason.rawValue)")
        await self.applyOutcome(self.executor.execute(
            self.parser.fallbackRequest(for: query),
            reservation: playbackReservation
        ))
    }

    private func applyLocalQueueDescription(reason: FallbackReason) async {
        self.phase = .fallback
        self.lastFallbackReason = reason
        self.logger.info("Falling back to local queue description due to \(reason.rawValue)")
        let outcome = self.executor.describeQueueLocally()

        guard let summary = outcome.resultMessage else {
            await self.applyOutcome(outcome)
            return
        }

        await self.applyOutcome(
            .result(
                "\(self.queueFallbackLead(for: reason)) \(summary)",
                shouldDismiss: false
            )
        )
    }

    private func queueSnapshot(maxLimit: Int) async -> QueueSnapshot {
        let candidateLines = FoundationModelsPromptLibrary.queueTrackLines(
            from: self.playerService.queue,
            currentIndex: self.playerService.activePlaybackQueueIndex ?? -1,
            isPlaying: self.playerService.isPlaying,
            limit: maxLimit
        )
        let fittedLineCount = await self.aiClient.fittedQueueLineCount(
            candidateLines,
            self.playerService.queue.count,
            self.queueDescriptionInstructions,
            self.aiPromptVersion
        )
        let finalLineCount = min(
            max(1, fittedLineCount),
            maxLimit,
            max(1, self.playerService.queue.count)
        )
        let lines = FoundationModelsPromptLibrary.queueTrackLines(
            from: self.playerService.queue,
            currentIndex: self.playerService.activePlaybackQueueIndex ?? -1,
            isPlaying: self.playerService.isPlaying,
            limit: finalLineCount
        )

        return QueueSnapshot(
            trackList: lines.joined(separator: "\n"),
            totalTracks: self.playerService.queue.count,
            shownTracks: lines.count
        )
    }

    private func queueFallbackLead(for reason: FallbackReason) -> String {
        switch reason {
        case .aiUnavailable, .unsupportedLocale, .modelNotReady:
            "Apple Intelligence wasn't available for a fuller queue analysis, so here's a quick summary:"
        case .timedOut, .sessionBusy:
            "Queue analysis took too long, so here's a quick summary:"
        case .decodingFailure, .contextWindowExceeded, .unknown:
            "I couldn't finish the queue analysis cleanly, so here's a quick summary:"
        }
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

    private func withHardTimeout<Value: Sendable>(
        _ timeout: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = CommandBarTimeoutRace<Value>()
        let operationTask = Task<Value, any Error> {
            try await operation()
        }
        let timeoutTask = Task<Value, any Error> {
            try await Task.sleep(for: timeout)
            throw AIError.timedOut
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                Task { @MainActor in
                    await race.resolve(operationTask.result)
                    timeoutTask.cancel()
                }
                Task { @MainActor in
                    await race.resolve(timeoutTask.result)
                    operationTask.cancel()
                }
            }
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            Task { @MainActor in
                race.resolve(.failure(CancellationError()))
            }
        }
    }

    private func startRequest(id: UUID) {
        self.activeRequestID = id
        self.isProcessing = true
        self.isInteractionDisabled = true
        self.errorMessage = nil
        self.resultMessage = nil
        self.lastFallbackReason = nil
        self.phase = .idle
    }

    private func finishRequest(id: UUID) {
        guard self.activeRequestID == id else { return }
        self.activeRequestID = nil
        self.requestTask = nil
        self.isProcessing = false
        self.isInteractionDisabled = false
        self.phase = .idle
    }
}
