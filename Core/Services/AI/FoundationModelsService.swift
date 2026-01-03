import Foundation
import FoundationModels
import Observation
import os

// MARK: - FoundationModelsService

/// Service for managing Apple Foundation Models integration.
///
/// This service provides on-device AI capabilities for:
/// - Natural language music control (command parsing)
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
/// let response = try await session.respond(to: prompt, generating: MusicIntent.self)
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
        self.availability = SystemLanguageModel.default.availability

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

    /// Clears any cached session state.
    /// This can help if the model gets into a bad state.
    func clearContext() {
        self.logger.info("Clearing Foundation Models context")
        // Sessions are created fresh each time, so this is mainly for future use
        // if we decide to keep a persistent session
    }

    // MARK: - Private Methods

    /// Pre-warms the Foundation Models using the official prewarm API.
    ///
    /// This eagerly loads model resources into memory without sending prompts,
    /// which is more efficient than the previous approach of sending "Hello".
    private func prewarmSession() async {
        self.logger.debug("Pre-warming Foundation Models with official API")

        let session = LanguageModelSession()

        do {
            // Use the official prewarm API instead of sending a dummy prompt
            try await session.prewarm()
            self.logger.debug("Foundation Models prewarm completed successfully")
        } catch {
            self.logger.error("Failed to prewarm session: \(error.localizedDescription)")
        }
    }
}
