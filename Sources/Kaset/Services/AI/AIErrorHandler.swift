import Foundation
import FoundationModels

// MARK: - AIError

/// User-friendly errors for AI operations.
///
/// These errors provide actionable messages that can be displayed directly to users,
/// along with suggestions for recovery.
@available(macOS 26.0, *)
enum AIError: LocalizedError {
    /// The request was too complex or exceeded token limits.
    case contextWindowExceeded

    /// Content was blocked by safety guardrails.
    case contentBlocked

    /// The generation was cancelled by the user or system.
    case cancelled

    /// Apple Intelligence is not available on this device.
    case notAvailable(reason: String)

    /// The model is still loading or initializing.
    case modelNotReady

    /// Session is already processing another request.
    case sessionBusy

    /// An unknown error occurred.
    case unknown(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .contextWindowExceeded:
            "That request was too complex"
        case .contentBlocked:
            "I can't help with that request"
        case .cancelled:
            "Request was cancelled"
        case let .notAvailable(reason):
            "Apple Intelligence unavailable: \(reason)"
        case .modelNotReady:
            "AI is still loading, please try again"
        case .sessionBusy:
            "Please wait for the current request to finish"
        case let .unknown(error):
            "Something went wrong: \(error.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .contextWindowExceeded:
            "Try a shorter request or select fewer items."
        case .contentBlocked:
            "Try rephrasing your request."
        case .cancelled:
            nil
        case .notAvailable:
            "Check that Apple Intelligence is enabled in System Settings."
        case .modelNotReady:
            "The model is downloading. Try again in a moment."
        case .sessionBusy:
            nil
        case .unknown:
            "Try again or restart the app."
        }
    }

    /// Whether this error should be shown to the user.
    var shouldDisplay: Bool {
        switch self {
        case .cancelled:
            false
        default:
            true
        }
    }
}

// MARK: - AIErrorHandler

/// Handles Foundation Models errors and converts them to user-friendly messages.
///
/// ## Usage
///
/// ```swift
/// do {
///     let response = try await session.respond(to: prompt, generating: MusicIntent.self)
/// } catch {
///     let aiError = AIErrorHandler.handle(error)
///     if aiError.shouldDisplay {
///         self.errorMessage = aiError.localizedDescription
///     }
/// }
/// ```
@available(macOS 26.0, *)
enum AIErrorHandler {
    private static let logger = DiagnosticsLogger.ai

    /// Converts a caught error to a user-friendly AIError.
    ///
    /// - Parameter error: The error caught from a Foundation Models operation.
    /// - Returns: An AIError with user-friendly messaging.
    static func handle(_ error: Error) -> AIError {
        // Handle specific LanguageModelSession errors
        if let generationError = error as? LanguageModelSession.GenerationError {
            return self.handleGenerationError(generationError)
        }

        // Handle cancellation
        if error is CancellationError {
            self.logger.info("AI generation was cancelled")
            return .cancelled
        }

        // Unknown error
        self.logger.error("Unknown AI error: \(error.localizedDescription)")
        return .unknown(underlying: error)
    }

    /// Handles specific GenerationError cases.
    private static func handleGenerationError(_ error: LanguageModelSession.GenerationError) -> AIError {
        switch error {
        case .exceededContextWindowSize:
            self.logger.warning("Context window exceeded")
            return .contextWindowExceeded

        case .guardrailViolation:
            self.logger.warning("Content blocked by guardrails")
            return .contentBlocked

        case .assetsUnavailable:
            self.logger.warning("Model assets unavailable")
            return .notAvailable(reason: "Model assets are not available")

        case .unsupportedGuide:
            self.logger.warning("Unsupported generation guide")
            return .unknown(underlying: error)

        case .unsupportedLanguageOrLocale:
            self.logger.warning("Unsupported language or locale")
            return .notAvailable(reason: "Language not supported")

        case .decodingFailure:
            self.logger.warning("Failed to decode model response")
            return .unknown(underlying: error)

        case .rateLimited:
            self.logger.warning("Rate limited by model")
            return .sessionBusy

        case .concurrentRequests:
            self.logger.warning("Concurrent request limit exceeded")
            return .sessionBusy

        case .refusal:
            self.logger.warning("Model refused to respond")
            return .contentBlocked

        @unknown default:
            self.logger.error("Unknown generation error: \(error.localizedDescription)")
            return .unknown(underlying: error)
        }
    }

    /// Returns a user-friendly error message for display.
    ///
    /// Combines the error description with recovery suggestion when available.
    ///
    /// - Parameter error: The AIError to format.
    /// - Returns: A formatted string suitable for UI display.
    static func userMessage(for error: AIError) -> String {
        if let suggestion = error.recoverySuggestion {
            return "\(error.errorDescription ?? "Error"). \(suggestion)"
        }
        return error.errorDescription ?? "An error occurred"
    }

    /// Logs an error with appropriate severity and returns a display message.
    ///
    /// - Parameters:
    ///   - error: The error to handle.
    ///   - context: Additional context about where the error occurred.
    /// - Returns: A user-friendly message, or nil if the error shouldn't be displayed.
    static func handleAndMessage(_ error: Error, context: String) -> String? {
        let aiError = self.handle(error)

        self.logger.error("AI error in \(context): \(error.localizedDescription)")

        guard aiError.shouldDisplay else { return nil }

        return self.userMessage(for: aiError)
    }
}
