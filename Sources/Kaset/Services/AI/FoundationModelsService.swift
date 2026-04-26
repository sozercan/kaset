import Foundation
import FoundationModels
import Observation
import os

// MARK: - FoundationModelsPromptBudget

@available(macOS 26.0, *)
struct FoundationModelsPromptBudget: Equatable {
    let contextSize: Int
    let instructionsTokens: Int
    let promptTokens: Int
    let toolsTokens: Int
    let schemaTokens: Int

    var totalTokens: Int {
        self.instructionsTokens + self.promptTokens + self.toolsTokens + self.schemaTokens
    }

    var remainingTokens: Int {
        max(0, self.contextSize - self.totalTokens)
    }

    var utilizationPercent: Int {
        guard self.contextSize > 0 else { return 0 }
        return Int((Double(self.totalTokens) / Double(self.contextSize) * 100).rounded())
    }
}

// MARK: - FoundationModelsService

/// Service for managing Apple Foundation Models integration.
///
/// This service provides on-device AI capabilities for:
/// - Natural language music control (command parsing)
/// - Queue analysis and description
/// - Lyrics explanation and analysis
/// - Playlist refinement suggestions
///
/// ## Usage
///
/// ```swift
/// // Check availability first
/// guard FoundationModelsService.shared.isAvailable else { return }
///
/// // Create a session for command parsing
/// guard let session = FoundationModelsService.shared.createCommandSession(
///     tools: [searchTool, queueTool]
/// ) else { return }
///
/// // Use with guided generation
/// let response = try await session.respond(to: prompt, generating: CommandBarParseResult.self)
/// ```
///
/// ## Session Types
///
/// - **Command sessions**: Optimized for parsing user intents with lower temperature
/// - **Analysis sessions**: Optimized for creative content like lyrics explanation
/// - **Conversational sessions**: For multi-turn dialogue (future use)
///
/// ## Performance
///
/// Call `warmup()` at app launch to pre-initialize the model. This uses the official
/// `prewarm()` API to load model resources without sending dummy prompts.
@available(macOS 26.0, *)
@MainActor
@Observable
final class FoundationModelsService {
    // MARK: - Singleton

    /// Shared instance for app-wide access.
    static let shared = FoundationModelsService()

    // MARK: - Published State

    /// Current availability status of Foundation Models.
    private(set) var availability: SystemLanguageModel.Availability = .unavailable(.modelNotReady)

    /// Whether the service has completed warmup.
    private(set) var isWarmedUp: Bool = false

    /// User preference to disable AI features even when available.
    var isDisabledByUser: Bool = false {
        didSet {
            UserDefaults.standard.set(self.isDisabledByUser, forKey: Self.disabledKey)
            // Notify UI to update immediately
            NotificationCenter.default.post(name: .intelligenceAvailabilityChanged, object: nil)
        }
    }

    // MARK: - Computed Properties

    /// Whether AI features are currently available and enabled.
    var isAvailable: Bool {
        guard !self.isDisabledByUser else { return false }
        return self.availability == .available
    }

    // MARK: - Private Properties

    private let logger = DiagnosticsLogger.ai
    private static let disabledKey = "intelligence.disabled"

    // MARK: - Initialization

    private init() {
        self.isDisabledByUser = UserDefaults.standard.bool(forKey: Self.disabledKey)
    }

    // MARK: - Public Methods

    /// Warms up the Foundation Models session in the background.
    ///
    /// Call this from app launch to pre-initialize the model for faster first use.
    /// Uses the official `prewarm()` API to eagerly load model resources into memory
    /// without sending dummy prompts.
    ///
    /// - Note: This should be called when you're confident the user will engage
    ///   with AI features. For Kaset, we call this at launch since AI is a core feature.
    func warmup() async {
        self.logger.info("Starting Foundation Models warmup")

        // Check availability
        self.refreshAvailability()

        switch self.availability {
        case .available:
            self.logger.info("Foundation Models available")
            await self.prewarmSession()
        case let .unavailable(reason):
            self.logger.info("Foundation Models unavailable: \(String(describing: reason))")
        @unknown default:
            self.logger.warning("Unknown Foundation Models availability state")
        }

        self.isWarmedUp = true
    }

    // MARK: - Specialized Session Factories

    /// Creates a session optimized for command parsing with tools.
    ///
    /// Uses lower temperature for predictable, structured intent parsing.
    /// Best for: natural language music commands like "play jazz" or "skip this song".
    ///
    /// - Parameters:
    ///   - instructions: System instructions for the session.
    ///   - tools: Tools the model can use (e.g., MusicSearchTool, QueueTool).
    /// - Returns: A configured LanguageModelSession, or nil if unavailable.
    func createCommandSession(instructions: String, tools: [any Tool]) -> LanguageModelSession? {
        self.refreshAvailability()

        guard self.isAvailable else {
            self.logger.warning("Attempted to create command session but AI is not available")
            return nil
        }

        self.logger.debug("Creating command session with \(tools.count) tools")
        return LanguageModelSession(
            tools: tools,
            instructions: instructions
        )
    }

    /// Refreshes the cached availability state from the system.
    func refreshAvailability() {
        self.availability = SystemLanguageModel.default.availability
    }

    /// Returns whether the system model supports a given locale.
    func supportsLocale(_ locale: Locale = .current) -> Bool {
        SystemLanguageModel.default.supportsLocale(locale)
    }

    /// Pre-warms command-bar parsing with the most likely prompt prefix.
    func prewarmCommandBar(promptPrefix: String) {
        self.refreshAvailability()

        guard self.isAvailable else { return }
        guard self.supportsLocale(Locale.current) else { return }

        self.logger.debug("Pre-warming Foundation Models command bar prompt prefix")
        let session = LanguageModelSession()
        session.prewarm(promptPrefix: Prompt(promptPrefix))
    }

    /// Resolves a natural-language command into a `CommandBarParseResult` using a fresh tool-free session.
    func resolveCommand(query: String, instructions: String) async throws -> CommandBarParseResult {
        self.refreshAvailability()

        guard self.isAvailable else {
            throw AIError.notAvailable(reason: self.availabilityDescription)
        }

        guard self.supportsLocale(Locale.current) else {
            throw AIError.notAvailable(reason: "Current language or locale is not supported")
        }

        await self.logPromptBudget(
            context: "command parsing",
            instructions: instructions,
            prompt: query,
            generationSchema: CommandBarParseResult.generationSchema
        )

        guard let session = self.createCommandSession(instructions: instructions, tools: []) else {
            throw AIError.modelNotReady
        }

        let response = try await session.respond(to: query, generating: CommandBarParseResult.self)
        return response.content
    }

    /// Streams a structured description of the current queue using a fresh analysis session.
    func analyzeQueue(
        prompt: String,
        instructions: String,
        onPartial: @escaping @MainActor @Sendable (QueueAnalysisSummary.PartiallyGenerated) -> Void
    ) async throws -> QueueAnalysisSummary {
        self.refreshAvailability()

        guard self.isAvailable else {
            throw AIError.notAvailable(reason: self.availabilityDescription)
        }

        guard self.supportsLocale(Locale.current) else {
            throw AIError.notAvailable(reason: "Current language or locale is not supported")
        }

        await self.logPromptBudget(
            context: "queue description",
            instructions: instructions,
            prompt: prompt,
            generationSchema: QueueAnalysisSummary.generationSchema
        )

        guard let session = self.createAnalysisSession(instructions: instructions) else {
            throw AIError.modelNotReady
        }

        let stream = session.streamResponse(to: prompt, generating: QueueAnalysisSummary.self)
        var partial: QueueAnalysisSummary.PartiallyGenerated?

        for try await snapshot in stream {
            partial = snapshot.content
            await onPartial(snapshot.content)
        }

        guard let final = partial,
              let opening = final.opening,
              let vibe = final.vibe,
              let highlights = final.highlights,
              let summary = final.summary
        else {
            throw AIError.decodingFailure
        }

        return QueueAnalysisSummary(
            opening: opening,
            vibe: vibe,
            highlights: highlights,
            summary: summary
        )
    }

    /// Creates a session optimized for creative content analysis.
    ///
    /// Uses higher temperature for more insightful, varied responses.
    /// Best for: lyrics explanation, music recommendations, mood analysis.
    ///
    /// - Parameter instructions: System instructions for the session.
    /// - Returns: A configured LanguageModelSession, or nil if unavailable.
    func createAnalysisSession(instructions: String) -> LanguageModelSession? {
        guard self.isAvailable else {
            self.logger.warning("Attempted to create analysis session but AI is not available")
            return nil
        }

        self.logger.debug("Creating analysis session for creative content")
        return LanguageModelSession(
            instructions: instructions
        )
    }

    /// Creates a session for multi-turn conversational interactions.
    ///
    /// Uses balanced temperature for natural dialogue. The session maintains
    /// context across multiple calls, allowing refinement like:
    /// "Play jazz" → "Make it more upbeat" → "Add to queue instead"
    ///
    /// - Parameter instructions: System instructions for the session.
    /// - Returns: A configured LanguageModelSession, or nil if unavailable.
    func createConversationalSession(instructions: String) -> LanguageModelSession? {
        guard self.isAvailable else {
            self.logger.warning("Attempted to create conversational session but AI is not available")
            return nil
        }

        self.logger.debug("Creating conversational session")
        return LanguageModelSession(
            instructions: instructions
        )
    }

    /// Logs a prompt budget snapshot when the 26.4 token-counting APIs are available.
    func logPromptBudget(
        context: String,
        instructions: String,
        prompt: String,
        tools: [any Tool] = [],
        generationSchema: GenerationSchema? = nil
    ) async {
        #if compiler(>=6.3)
            guard let budget = await self.promptBudget(
                context: context,
                instructions: instructions,
                prompt: prompt,
                tools: tools,
                generationSchema: generationSchema
            ) else {
                return
            }

            self.logger.debug(
                """
                \(context, privacy: .public) prompt budget: \
                instructions=\(budget.instructionsTokens, privacy: .public), \
                prompt=\(budget.promptTokens, privacy: .public), \
                tools=\(budget.toolsTokens, privacy: .public), \
                schema=\(budget.schemaTokens, privacy: .public), \
                total=\(budget.totalTokens, privacy: .public)/\(budget.contextSize, privacy: .public) \
                (\(budget.utilizationPercent, privacy: .public)%)
                """
            )
        #else
            _ = context
            _ = instructions
            _ = prompt
            _ = tools
            _ = generationSchema
        #endif
    }

    /// Fits large free-form content to the available context window on 26.4+.
    ///
    /// This preserves behavior on 26.0-26.3 by returning the original content unchanged.
    static func bestFittingTruncatedContent(
        _ content: String,
        truncationMarker: String = "\n...[truncated for on-device analysis]...\n",
        fits: (String) async -> Bool
    ) async -> String? {
        guard !content.isEmpty else { return "" }

        var low = 0
        var high = content.count
        var bestFit: String?

        while low <= high {
            let midpoint = (low + high) / 2
            let candidateContent = FoundationModelsPromptLibrary.middleTruncate(
                content,
                targetLength: midpoint,
                marker: truncationMarker
            )

            if await fits(candidateContent) {
                bestFit = candidateContent
                low = midpoint + 1
            } else {
                high = midpoint - 1
            }
        }

        return bestFit
    }

    func fittedPromptContent(
        context: String,
        instructions: String,
        content: String,
        tools: [any Tool] = [],
        generationSchema: GenerationSchema? = nil,
        reserveTokens: Int = 1024,
        truncationMarker: String = "\n...[truncated for on-device analysis]...\n",
        promptBuilder: (String) -> String
    ) async -> String {
        #if compiler(>=6.3)
            guard #available(macOS 26.4, *), !content.isEmpty else { return content }

            let fullPrompt = promptBuilder(content)
            guard let fullBudget = await self.promptBudget(
                context: context,
                instructions: instructions,
                prompt: fullPrompt,
                tools: tools,
                generationSchema: generationSchema
            ) else {
                return content
            }

            let tokenLimit = max(0, fullBudget.contextSize - reserveTokens)
            guard fullBudget.totalTokens > tokenLimit else {
                await self.logPromptBudget(
                    context: context,
                    instructions: instructions,
                    prompt: fullPrompt,
                    tools: tools,
                    generationSchema: generationSchema
                )
                return content
            }

            let bestFit = await Self.bestFittingTruncatedContent(
                content,
                truncationMarker: truncationMarker
            ) { candidateContent in
                let candidatePrompt = promptBuilder(candidateContent)

                if let budget = await self.promptBudget(
                    context: context,
                    instructions: instructions,
                    prompt: candidatePrompt,
                    tools: tools,
                    generationSchema: generationSchema
                ), budget.totalTokens <= tokenLimit {
                    return true
                }
                return false
            }

            let fittedContent = bestFit ?? ""
            let fittedPrompt = promptBuilder(fittedContent)

            if bestFit == nil {
                self.logger.warning(
                    """
                    No \(context, privacy: .public) content fit the available \
                    Foundation Models budget; using empty-content fallback
                    """
                )
            } else {
                self.logger.info(
                    """
                    Trimmed \(context, privacy: .public) content from \
                    \(content.count, privacy: .public) to \(fittedContent.count, privacy: .public) characters
                    """
                )
            }
            await self.logPromptBudget(
                context: context,
                instructions: instructions,
                prompt: fittedPrompt,
                tools: tools,
                generationSchema: generationSchema
            )

            return fittedContent
        #else
            _ = context
            _ = instructions
            _ = tools
            _ = generationSchema
            _ = reserveTokens
            _ = truncationMarker
            _ = promptBuilder
            return content
        #endif
    }

    /// Fits a list of prompt lines to the available context window on 26.4+.
    ///
    /// This is useful for playlist review prompts where dropping whole lines is better than
    /// trimming arbitrary characters mid-track.
    static func bestFittingPrefixCount(
        maxCount: Int,
        fits: (Int) async -> Bool
    ) async -> Int {
        guard maxCount > 0 else { return 0 }

        var low = 0
        var high = maxCount
        var bestFit = 0

        while low <= high {
            let midpoint = (low + high) / 2

            if await fits(midpoint) {
                bestFit = midpoint
                low = midpoint + 1
            } else {
                high = midpoint - 1
            }
        }

        return bestFit
    }

    func fittedLineCount(
        context: String,
        instructions: String,
        lines: [String],
        tools: [any Tool] = [],
        generationSchema: GenerationSchema? = nil,
        reserveTokens: Int = 1024,
        promptBuilder: ([String]) -> String
    ) async -> Int {
        #if compiler(>=6.3)
            guard #available(macOS 26.4, *), !lines.isEmpty else { return lines.count }

            let fullPrompt = promptBuilder(lines)
            guard let fullBudget = await self.promptBudget(
                context: context,
                instructions: instructions,
                prompt: fullPrompt,
                tools: tools,
                generationSchema: generationSchema
            ) else {
                return lines.count
            }

            let tokenLimit = max(0, fullBudget.contextSize - reserveTokens)
            guard fullBudget.totalTokens > tokenLimit else {
                await self.logPromptBudget(
                    context: context,
                    instructions: instructions,
                    prompt: fullPrompt,
                    tools: tools,
                    generationSchema: generationSchema
                )
                return lines.count
            }

            let bestFit = await Self.bestFittingPrefixCount(maxCount: lines.count) { candidateCount in
                let candidateLines = Array(lines.prefix(candidateCount))
                let candidatePrompt = promptBuilder(candidateLines)

                guard let budget = await self.promptBudget(
                    context: context,
                    instructions: instructions,
                    prompt: candidatePrompt,
                    tools: tools,
                    generationSchema: generationSchema
                ) else {
                    return false
                }

                return budget.totalTokens <= tokenLimit
            }

            if bestFit == 0 {
                self.logger.warning(
                    """
                    No \(context, privacy: .public) lines fit the available \
                    Foundation Models budget; using zero-line fallback
                    """
                )
            } else {
                self.logger.info(
                    """
                    Trimmed \(context, privacy: .public) lines from \
                    \(lines.count, privacy: .public) to \(bestFit, privacy: .public)
                    """
                )
            }
            await self.logPromptBudget(
                context: context,
                instructions: instructions,
                prompt: promptBuilder(Array(lines.prefix(bestFit))),
                tools: tools,
                generationSchema: generationSchema
            )

            return bestFit
        #else
            _ = context
            _ = instructions
            _ = tools
            _ = generationSchema
            _ = reserveTokens
            _ = promptBuilder
            return lines.count
        #endif
    }

    // MARK: - Private Methods

    private func promptBudget(
        context: String,
        instructions: String,
        prompt: String,
        tools: [any Tool],
        generationSchema: GenerationSchema?
    ) async -> FoundationModelsPromptBudget? {
        #if compiler(>=6.3)
            guard #available(macOS 26.4, *) else { return nil }

            let model = SystemLanguageModel.default

            do {
                let instructionsTokens = try await model.tokenCount(for: Instructions(instructions))
                let promptTokens = try await model.tokenCount(for: prompt)
                let toolsTokens = if tools.isEmpty {
                    0
                } else {
                    try await model.tokenCount(for: tools)
                }
                let schemaTokens = if let generationSchema {
                    try await model.tokenCount(for: generationSchema)
                } else {
                    0
                }

                return FoundationModelsPromptBudget(
                    contextSize: model.contextSize,
                    instructionsTokens: instructionsTokens,
                    promptTokens: promptTokens,
                    toolsTokens: toolsTokens,
                    schemaTokens: schemaTokens
                )
            } catch {
                self.logger.warning(
                    "Unable to measure \(context, privacy: .public) prompt budget: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        #else
            _ = context
            _ = instructions
            _ = prompt
            _ = tools
            _ = generationSchema
            return nil
        #endif
    }

    /// Pre-warms the Foundation Models using the official prewarm API.
    ///
    /// This eagerly loads model resources into memory without sending prompts,
    /// which is more efficient than the previous approach of sending "Hello".
    private func prewarmSession() async {
        self.logger.debug("Pre-warming Foundation Models with official API")

        let session = LanguageModelSession()

        // Use the official prewarm API to load model resources
        session.prewarm()
        self.logger.debug("Foundation Models prewarm completed successfully")
    }

    private var availabilityDescription: String {
        switch self.availability {
        case .available:
            "Available"
        case let .unavailable(reason):
            String(describing: reason)
        @unknown default:
            "Unknown availability state"
        }
    }
}
