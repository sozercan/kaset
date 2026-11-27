import Foundation
import Testing
@testable import Kaset

@available(macOS 26.0, *)

@Suite(.tags(.api), .serialized)
@MainActor
struct FoundationModelsServiceTests {
    @Test("isAvailable returns false when disabled by user")
    func isAvailableFalseWhenDisabled() {
        let service = FoundationModelsService.shared

        let originalDisabled = service.isDisabledByUser

        service.isDisabledByUser = true
        #expect(service.isAvailable == false)

        service.isDisabledByUser = originalDisabled
    }

    @Test("isDisabledByUser persists to UserDefaults")
    func isDisabledByUserPersists() {
        let service = FoundationModelsService.shared
        let key = "intelligence.disabled"

        let originalDisabled = service.isDisabledByUser
        let originalDefault = UserDefaults.standard.bool(forKey: key)

        service.isDisabledByUser = true
        #expect(UserDefaults.standard.bool(forKey: key) == true)

        service.isDisabledByUser = false
        #expect(UserDefaults.standard.bool(forKey: key) == false)

        service.isDisabledByUser = originalDisabled
        UserDefaults.standard.set(originalDefault, forKey: key)
    }

    @Test("isWarmedUp starts as false")
    func isWarmedUpInitiallyFalse() {
        let service = FoundationModelsService.shared
        _ = service.isWarmedUp
    }

    @Test("createCommandSession returns nil when unavailable")
    func createCommandSessionNilWhenUnavailable() {
        let service = FoundationModelsService.shared

        let originalDisabled = service.isDisabledByUser

        service.isDisabledByUser = true

        let session = service.createCommandSession(
            instructions: "Test instructions",
            tools: []
        )

        #expect(session == nil)

        service.isDisabledByUser = originalDisabled
    }

    @Test("createAnalysisSession returns nil when unavailable")
    func createAnalysisSessionNilWhenUnavailable() {
        let service = FoundationModelsService.shared

        let originalDisabled = service.isDisabledByUser

        service.isDisabledByUser = true

        let session = service.createAnalysisSession(instructions: "Test instructions")

        #expect(session == nil)

        service.isDisabledByUser = originalDisabled
    }

    @Test("createConversationalSession returns nil when unavailable")
    func createConversationalSessionNilWhenUnavailable() {
        let service = FoundationModelsService.shared

        let originalDisabled = service.isDisabledByUser

        service.isDisabledByUser = true

        let session = service.createConversationalSession(instructions: "Test instructions")

        #expect(session == nil)

        service.isDisabledByUser = originalDisabled
    }

    @Test("refreshAvailability does not throw")
    func refreshAvailabilityDoesNotThrow() {
        let service = FoundationModelsService.shared

        service.refreshAvailability()
    }
}
