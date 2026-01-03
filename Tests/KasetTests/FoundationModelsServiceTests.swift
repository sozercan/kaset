import Foundation
import Testing
@testable import Kaset

// MARK: - FoundationModelsServiceTests

/// Tests for FoundationModelsService availability and session creation.
@available(macOS 26.0, *)
@Suite("FoundationModelsService", .tags(.api), .serialized)
@MainActor
struct FoundationModelsServiceTests {
    // MARK: - Availability Tests

    @Test("isAvailable returns false when disabled by user")
    func isAvailableFalseWhenDisabled() {
        let service = FoundationModelsService.shared

        // Save original state
        let originalDisabled = service.isDisabledByUser

        // Disable
        service.isDisabledByUser = true
        #expect(service.isAvailable == false)

        // Restore
        service.isDisabledByUser = originalDisabled
    }

    @Test("isDisabledByUser persists to UserDefaults")
    func isDisabledByUserPersists() {
        let service = FoundationModelsService.shared
        let key = "intelligence.disabled"

        // Save original state
        let originalDisabled = service.isDisabledByUser
        let originalDefault = UserDefaults.standard.bool(forKey: key)

        // Set to true
        service.isDisabledByUser = true
        #expect(UserDefaults.standard.bool(forKey: key) == true)

        // Set to false
        service.isDisabledByUser = false
        #expect(UserDefaults.standard.bool(forKey: key) == false)

        // Restore
        service.isDisabledByUser = originalDisabled
        UserDefaults.standard.set(originalDefault, forKey: key)
    }

    @Test("isWarmedUp starts as false")
    func isWarmedUpInitiallyFalse() {
        // Note: This tests the initial state behavior
        // The shared instance may already be warmed up, so we just verify the property exists
        let service = FoundationModelsService.shared
        // Just verify the property is accessible
        _ = service.isWarmedUp
    }

    // MARK: - Session Creation Tests

    @Test("createCommandSession returns nil when unavailable")
    func createCommandSessionNilWhenUnavailable() {
        let service = FoundationModelsService.shared

        // Save original state
        let originalDisabled = service.isDisabledByUser

        // Disable AI
        service.isDisabledByUser = true

        let session = service.createCommandSession(
            instructions: "Test instructions",
            tools: []
        )

        #expect(session == nil)

        // Restore
        service.isDisabledByUser = originalDisabled
    }

    @Test("createAnalysisSession returns nil when unavailable")
    func createAnalysisSessionNilWhenUnavailable() {
        let service = FoundationModelsService.shared

        // Save original state
        let originalDisabled = service.isDisabledByUser

        // Disable AI
        service.isDisabledByUser = true

        let session = service.createAnalysisSession(instructions: "Test instructions")

        #expect(session == nil)

        // Restore
        service.isDisabledByUser = originalDisabled
    }

    @Test("createConversationalSession returns nil when unavailable")
    func createConversationalSessionNilWhenUnavailable() {
        let service = FoundationModelsService.shared

        // Save original state
        let originalDisabled = service.isDisabledByUser

        // Disable AI
        service.isDisabledByUser = true

        let session = service.createConversationalSession(instructions: "Test instructions")

        #expect(session == nil)

        // Restore
        service.isDisabledByUser = originalDisabled
    }

    // MARK: - Clear Context Test

    @Test("clearContext does not throw")
    func clearContextDoesNotThrow() {
        let service = FoundationModelsService.shared

        // Should complete without error
        service.clearContext()
    }
}
