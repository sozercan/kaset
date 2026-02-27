import Foundation
import Testing
@testable import Kaset

// MARK: - AIErrorTests

/// Tests for AIError enum and its properties.
@Suite("AIError", .tags(.api))
struct AIErrorTests {
    // MARK: - Error Description Tests

    @Test("contextWindowExceeded has correct description")
    func contextWindowExceededDescription() {
        let error = AIError.contextWindowExceeded
        #expect(error.errorDescription?.contains("too complex") == true)
    }

    @Test("contentBlocked has correct description")
    func contentBlockedDescription() {
        let error = AIError.contentBlocked
        #expect(error.errorDescription?.contains("can't help") == true)
    }

    @Test("cancelled has correct description")
    func cancelledDescription() {
        let error = AIError.cancelled
        #expect(error.errorDescription?.contains("cancelled") == true)
    }

    @Test("notAvailable has correct description with reason")
    func notAvailableDescription() {
        let error = AIError.notAvailable(reason: "Device not supported")
        #expect(error.errorDescription?.contains("unavailable") == true)
        #expect(error.errorDescription?.contains("Device not supported") == true)
    }

    @Test("modelNotReady has correct description")
    func modelNotReadyDescription() {
        let error = AIError.modelNotReady
        #expect(error.errorDescription?.contains("loading") == true)
    }

    @Test("sessionBusy has correct description")
    func sessionBusyDescription() {
        let error = AIError.sessionBusy
        #expect(error.errorDescription?.contains("wait") == true)
    }

    @Test("unknown has correct description with underlying error")
    func unknownDescription() {
        let underlying = NSError(domain: "test", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Something failed",
        ])
        let error = AIError.unknown(underlying: underlying)
        #expect(error.errorDescription?.contains("Something failed") == true)
    }

    // MARK: - Recovery Suggestion Tests

    @Test("contextWindowExceeded has recovery suggestion")
    func contextWindowExceededRecovery() {
        let error = AIError.contextWindowExceeded
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("shorter") == true)
    }

    @Test("contentBlocked has recovery suggestion")
    func contentBlockedRecovery() {
        let error = AIError.contentBlocked
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("rephras") == true)
    }

    @Test("cancelled has no recovery suggestion")
    func cancelledNoRecovery() {
        let error = AIError.cancelled
        #expect(error.recoverySuggestion == nil)
    }

    @Test("notAvailable has recovery suggestion")
    func notAvailableRecovery() {
        let error = AIError.notAvailable(reason: "Not enabled")
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("System Settings") == true)
    }

    @Test("modelNotReady has recovery suggestion")
    func modelNotReadyRecovery() {
        let error = AIError.modelNotReady
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("downloading") == true)
    }

    @Test("sessionBusy has no recovery suggestion")
    func sessionBusyNoRecovery() {
        let error = AIError.sessionBusy
        #expect(error.recoverySuggestion == nil)
    }

    @Test("unknown has recovery suggestion")
    func unknownRecovery() {
        let error = AIError.unknown(underlying: NSError(domain: "test", code: 1))
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("restart") == true)
    }

    // MARK: - shouldDisplay Tests

    @Test("contextWindowExceeded should display")
    func contextWindowExceededShouldDisplay() {
        let error = AIError.contextWindowExceeded
        #expect(error.shouldDisplay == true)
    }

    @Test("contentBlocked should display")
    func contentBlockedShouldDisplay() {
        let error = AIError.contentBlocked
        #expect(error.shouldDisplay == true)
    }

    @Test("cancelled should NOT display")
    func cancelledShouldNotDisplay() {
        let error = AIError.cancelled
        #expect(error.shouldDisplay == false)
    }

    @Test("notAvailable should display")
    func notAvailableShouldDisplay() {
        let error = AIError.notAvailable(reason: "test")
        #expect(error.shouldDisplay == true)
    }

    @Test("modelNotReady should display")
    func modelNotReadyShouldDisplay() {
        let error = AIError.modelNotReady
        #expect(error.shouldDisplay == true)
    }

    @Test("sessionBusy should display")
    func sessionBusyShouldDisplay() {
        let error = AIError.sessionBusy
        #expect(error.shouldDisplay == true)
    }

    @Test("unknown should display")
    func unknownShouldDisplay() {
        let error = AIError.unknown(underlying: NSError(domain: "test", code: 1))
        #expect(error.shouldDisplay == true)
    }
}

// MARK: - AIErrorHandlerTests

/// Tests for AIErrorHandler utility methods.
@Suite("AIErrorHandler", .tags(.api))
struct AIErrorHandlerTests {
    // MARK: - handle() Tests

    @Test("Handle CancellationError returns cancelled")
    func handleCancellationError() {
        let error = CancellationError()
        let result = AIErrorHandler.handle(error)

        if case .cancelled = result {
            // Success
        } else {
            Issue.record("Expected .cancelled, got \(result)")
        }
    }

    @Test("Handle unknown error wraps it")
    func handleUnknownError() {
        let underlying = NSError(domain: "test", code: 123)
        let result = AIErrorHandler.handle(underlying)

        if case let .unknown(wrapped) = result {
            #expect((wrapped as NSError).code == 123)
        } else {
            Issue.record("Expected .unknown, got \(result)")
        }
    }

    // MARK: - userMessage() Tests

    @Test("userMessage includes description")
    func userMessageIncludesDescription() {
        let error = AIError.contextWindowExceeded
        let message = AIErrorHandler.userMessage(for: error)

        #expect(message.contains("too complex"))
    }

    @Test("userMessage includes recovery suggestion when available")
    func userMessageIncludesRecovery() {
        let error = AIError.contentBlocked
        let message = AIErrorHandler.userMessage(for: error)

        #expect(message.contains("rephras"))
    }

    @Test("userMessage works for cancelled (no recovery)")
    func userMessageForCancelled() {
        let error = AIError.cancelled
        let message = AIErrorHandler.userMessage(for: error)

        #expect(message.contains("cancelled"))
    }

    // MARK: - handleAndMessage() Tests

    @Test("handleAndMessage returns nil for cancelled")
    func handleAndMessageCancelledReturnsNil() {
        let error = CancellationError()
        let message = AIErrorHandler.handleAndMessage(error, context: "test")

        #expect(message == nil)
    }

    @Test("handleAndMessage returns message for displayable errors")
    func handleAndMessageReturnsMessage() {
        let error = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Test error",
        ])
        let message = AIErrorHandler.handleAndMessage(error, context: "test operation")

        #expect(message != nil)
        #expect(message?.contains("Test error") == true)
    }
}
