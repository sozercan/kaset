import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.api))
struct AIErrorTests {
    @Test("contextWindowExceeded has correct description")
    func contextWindowExceededDescription() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.contextWindowExceeded
        #expect(error.errorDescription?.contains("too complex") == true)
    }

    @Test("contentBlocked has correct description")
    func contentBlockedDescription() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.contentBlocked
        #expect(error.errorDescription?.contains("can't help") == true)
    }

    @Test("cancelled has correct description")
    func cancelledDescription() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.cancelled
        #expect(error.errorDescription?.contains("cancelled") == true)
    }

    @Test("notAvailable has correct description with reason")
    func notAvailableDescription() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.notAvailable(reason: "Device not supported")
        #expect(error.errorDescription?.contains("unavailable") == true)
        #expect(error.errorDescription?.contains("Device not supported") == true)
    }

    @Test("modelNotReady has correct description")
    func modelNotReadyDescription() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.modelNotReady
        #expect(error.errorDescription?.contains("loading") == true)
    }

    @Test("sessionBusy has correct description")
    func sessionBusyDescription() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.sessionBusy
        #expect(error.errorDescription?.contains("wait") == true)
    }

    @Test("unknown has correct description with underlying error")
    func unknownDescription() {
        guard #available(macOS 26.0, *) else { return }
        let underlying = NSError(domain: "test", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Something failed",
        ])
        let error = AIError.unknown(underlying: underlying)
        #expect(error.errorDescription?.contains("Something failed") == true)
    }

    @Test("contextWindowExceeded has recovery suggestion")
    func contextWindowExceededRecovery() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.contextWindowExceeded
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("shorter") == true)
    }

    @Test("contentBlocked has recovery suggestion")
    func contentBlockedRecovery() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.contentBlocked
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("rephras") == true)
    }

    @Test("cancelled has no recovery suggestion")
    func cancelledNoRecovery() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.cancelled
        #expect(error.recoverySuggestion == nil)
    }

    @Test("notAvailable has recovery suggestion")
    func notAvailableRecovery() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.notAvailable(reason: "Not enabled")
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("System Settings") == true)
    }

    @Test("modelNotReady has recovery suggestion")
    func modelNotReadyRecovery() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.modelNotReady
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("downloading") == true)
    }

    @Test("sessionBusy has no recovery suggestion")
    func sessionBusyNoRecovery() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.sessionBusy
        #expect(error.recoverySuggestion == nil)
    }

    @Test("unknown has recovery suggestion")
    func unknownRecovery() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.unknown(underlying: NSError(domain: "test", code: 1))
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("restart") == true)
    }

    @Test("contextWindowExceeded should display")
    func contextWindowExceededShouldDisplay() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.contextWindowExceeded
        #expect(error.shouldDisplay == true)
    }

    @Test("contentBlocked should display")
    func contentBlockedShouldDisplay() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.contentBlocked
        #expect(error.shouldDisplay == true)
    }

    @Test("cancelled should NOT display")
    func cancelledShouldNotDisplay() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.cancelled
        #expect(error.shouldDisplay == false)
    }

    @Test("notAvailable should display")
    func notAvailableShouldDisplay() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.notAvailable(reason: "test")
        #expect(error.shouldDisplay == true)
    }

    @Test("modelNotReady should display")
    func modelNotReadyShouldDisplay() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.modelNotReady
        #expect(error.shouldDisplay == true)
    }

    @Test("sessionBusy should display")
    func sessionBusyShouldDisplay() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.sessionBusy
        #expect(error.shouldDisplay == true)
    }

    @Test("unknown should display")
    func unknownShouldDisplay() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.unknown(underlying: NSError(domain: "test", code: 1))
        #expect(error.shouldDisplay == true)
    }
}

@Suite(.tags(.api))
struct AIErrorHandlerTests {
    @Test("Handle CancellationError returns cancelled")
    func handleCancellationError() {
        guard #available(macOS 26.0, *) else { return }
        let error = CancellationError()
        let result = AIErrorHandler.handle(error)

        if case .cancelled = result {
        } else {
            Issue.record("Expected .cancelled, got \(result)")
        }
    }

    @Test("Handle unknown error wraps it")
    func handleUnknownError() {
        guard #available(macOS 26.0, *) else { return }
        let underlying = NSError(domain: "test", code: 123)
        let result = AIErrorHandler.handle(underlying)

        if case let .unknown(wrapped) = result {
            #expect((wrapped as NSError).code == 123)
        } else {
            Issue.record("Expected .unknown, got \(result)")
        }
    }

    @Test("userMessage includes description")
    func userMessageIncludesDescription() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.contextWindowExceeded
        let message = AIErrorHandler.userMessage(for: error)

        #expect(message.contains("too complex"))
    }

    @Test("userMessage includes recovery suggestion when available")
    func userMessageIncludesRecovery() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.contentBlocked
        let message = AIErrorHandler.userMessage(for: error)

        #expect(message.contains("rephras"))
    }

    @Test("userMessage works for cancelled (no recovery)")
    func userMessageForCancelled() {
        guard #available(macOS 26.0, *) else { return }
        let error = AIError.cancelled
        let message = AIErrorHandler.userMessage(for: error)

        #expect(message.contains("cancelled"))
    }

    @Test("handleAndMessage returns nil for cancelled")
    func handleAndMessageCancelledReturnsNil() {
        guard #available(macOS 26.0, *) else { return }
        let error = CancellationError()
        let message = AIErrorHandler.handleAndMessage(error, context: "test")

        #expect(message == nil)
    }

    @Test("handleAndMessage returns message for displayable errors")
    func handleAndMessageReturnsMessage() {
        guard #available(macOS 26.0, *) else { return }
        let error = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Test error",
        ])
        let message = AIErrorHandler.handleAndMessage(error, context: "test operation")

        #expect(message != nil)
        #expect(message?.contains("Test error") == true)
    }
}
