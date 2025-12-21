import Foundation
import FoundationModels
import Observation
import os

/// Service for managing Apple Foundation Models integration.
/// Provides on-device AI capabilities for natural language music control,
/// playlist refinement, and lyrics explanation.
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
    /// Call this from app launch to pre-initialize the model for faster first use.
    func warmup() async {
        self.logger.info("Starting Foundation Models warmup")

        // Check availability
        self.availability = SystemLanguageModel.default.availability

        switch self.availability {
        case .available:
            self.logger.info("Foundation Models available")
            await self.preloadSession()
        case .unavailable:
            self.logger.info("Foundation Models unavailable")
        @unknown default:
            self.logger.warning("Unknown Foundation Models availability state")
        }

        self.isWarmedUp = true
    }

    /// Creates a new language model session for a given task.
    /// - Parameter instructions: System instructions for the session.
    /// - Returns: A configured LanguageModelSession, or nil if unavailable.
    func createSession(instructions: String) -> LanguageModelSession? {
        guard self.isAvailable else {
            self.logger.warning("Attempted to create session but AI is not available")
            return nil
        }

        return LanguageModelSession(
            instructions: instructions
        )
    }

    /// Creates a session with tool access for grounded responses.
    /// - Parameters:
    ///   - instructions: System instructions for the session.
    ///   - tools: Tools the model can use during generation.
    /// - Returns: A configured LanguageModelSession with tools, or nil if unavailable.
    func createSession(instructions: String, tools: [any Tool]) -> LanguageModelSession? {
        guard self.isAvailable else {
            self.logger.warning("Attempted to create session with tools but AI is not available")
            return nil
        }

        return LanguageModelSession(
            tools: tools,
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

    /// Pre-loads a session to warm up the model.
    private func preloadSession() async {
        self.logger.debug("Pre-loading Foundation Models session")

        let session = LanguageModelSession()

        do {
            // Simple prompt to warm up the model
            _ = try await session.respond(to: "Hello")
            self.logger.debug("Foundation Models session pre-loaded successfully")
        } catch {
            self.logger.error("Failed to pre-load session: \(error.localizedDescription)")
        }
    }
}
