import Foundation
import FoundationModels

@available(macOS 26.0, *)
enum AIError: LocalizedError {
    case contextWindowExceeded

    case decodingFailure

    case contentBlocked

    case cancelled

    case notAvailable(reason: String)

    case modelNotReady

    case sessionBusy

    case timedOut

    case unknown(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .contextWindowExceeded:
            "That request was too complex"
        case .decodingFailure:
            "I couldn't understand that request"
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
        case .timedOut:
            "That took too long"
        case let .unknown(error):
            "Something went wrong: \(error.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .contextWindowExceeded:
            "Try a shorter request or select fewer items."
        case .decodingFailure:
            "Try a simpler or more specific command."
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
        case .timedOut:
            "Try again or use a simpler command."
        case .unknown:
            "Try again or restart the app."
        }
    }

    var shouldDisplay: Bool {
        switch self {
        case .cancelled:
            false
        default:
            true
        }
    }
}

@available(macOS 26.0, *)
enum AIErrorHandler {
    private static let logger = DiagnosticsLogger.ai

    static func handle(_ error: Error) -> AIError {
        if let aiError = error as? AIError {
            return aiError
        }

        #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                if let languageModelError = error as? LanguageModelError {
                    return Self.handleLanguageModelError(languageModelError)
                }

                if let sessionError = error as? LanguageModelSession.Error {
                    return Self.handleSessionError(sessionError)
                }

                if error is GeneratedContent.ParsingError {
                    Self.logger.warning("Failed to parse generated content")
                    return .decodingFailure
                }

                if let systemModelError = error as? SystemLanguageModel.Error {
                    return Self.handleSystemModelError(systemModelError)
                }
            }
        #endif

        if let generationError = error as? LanguageModelSession.GenerationError {
            return Self.handleGenerationError(generationError)
        }

        if error is CancellationError {
            self.logger.info("AI generation was cancelled")
            return .cancelled
        }

        self.logger.error("Unknown AI error: \(error.localizedDescription)")
        return .unknown(underlying: error)
    }

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        private static func handleLanguageModelError(_ error: LanguageModelError) -> AIError {
            switch error {
            case .contextSizeExceeded:
                self.logger.warning("Context window exceeded")
                return .contextWindowExceeded

            case .rateLimited:
                self.logger.warning("Rate limited by model")
                return .sessionBusy

            case .guardrailViolation:
                self.logger.warning("Content blocked by guardrails")
                return .contentBlocked

            case .refusal:
                self.logger.warning("Model refused to respond")
                return .contentBlocked

            case .unsupportedLanguageOrLocale:
                self.logger.warning("Unsupported language or locale")
                return .notAvailable(reason: "Language not supported")

            case .timeout:
                self.logger.warning("Foundation Models request timed out")
                return .timedOut

            case .unsupportedCapability:
                self.logger.error("Foundation Models capability is unsupported")
                return .unknown(underlying: error)

            case .unsupportedTranscriptContent:
                self.logger.error("Foundation Models transcript content is unsupported")
                return .unknown(underlying: error)

            case .unsupportedGenerationGuide:
                self.logger.error("Foundation Models generation guide is unsupported")
                return .unknown(underlying: error)

            @unknown default:
                self.logger.error("Unknown language model error: \(error.localizedDescription)")
                return .unknown(underlying: error)
            }
        }

        @available(macOS 27.0, *)
        private static func handleSessionError(_ error: LanguageModelSession.Error) -> AIError {
            switch error {
            case .concurrentRequests:
                self.logger.warning("Concurrent request limit exceeded")
                return .sessionBusy

            case .transcriptMutationWhileResponding:
                self.logger.error("Session transcript mutated while responding")
                return .unknown(underlying: error)

            @unknown default:
                self.logger.error("Unknown session error: \(error.localizedDescription)")
                return .unknown(underlying: error)
            }
        }

        @available(macOS 27.0, *)
        private static func handleSystemModelError(_ error: SystemLanguageModel.Error) -> AIError {
            switch error {
            case .assetsUnavailable:
                self.logger.warning("Model assets unavailable")
                return .notAvailable(reason: "Model assets are not available")

            @unknown default:
                self.logger.error("Unknown system model error: \(error.localizedDescription)")
                return .unknown(underlying: error)
            }
        }
    #endif

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
            return .decodingFailure

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

    static func userMessage(for error: AIError) -> String {
        if let suggestion = error.recoverySuggestion {
            return "\(error.errorDescription ?? "Error"). \(suggestion)"
        }
        return error.errorDescription ?? "An error occurred"
    }

    static func handleAndMessage(_ error: Error, context: String) -> String? {
        let aiError = self.handle(error)

        self.logger.error("AI error in \(context): \(error.localizedDescription)")

        guard aiError.shouldDisplay else { return nil }

        return self.userMessage(for: aiError)
    }
}
