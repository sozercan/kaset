import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.api), .serialized)
@MainActor
struct FoundationModelsServiceTests {
    @available(macOS 26.0, *)
    private struct IsolatedService {
        let service: FoundationModelsService
        let defaults: UserDefaults
        let suiteName: String
    }

    @available(macOS 26.0, *)
    private func makeIsolatedService() throws -> IsolatedService {
        let suiteName = "FoundationModelsServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return IsolatedService(service: FoundationModelsService(defaults: defaults), defaults: defaults, suiteName: suiteName)
    }

    @Test("isAvailable returns false when disabled by user")
    func isAvailableFalseWhenDisabled() throws {
        guard #available(macOS 26.0, *) else { return }
        let isolated = try self.makeIsolatedService()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }

        isolated.service.isDisabledByUser = true
        #expect(isolated.service.isAvailable == false)
    }

    @Test("isDisabledByUser persists to UserDefaults")
    func isDisabledByUserPersists() throws {
        guard #available(macOS 26.0, *) else { return }
        let isolated = try self.makeIsolatedService()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        let key = "intelligence.disabled"

        isolated.service.isDisabledByUser = true
        #expect(isolated.defaults.bool(forKey: key) == true)

        isolated.service.isDisabledByUser = false
        #expect(isolated.defaults.bool(forKey: key) == false)
    }

    @Test("isWarmedUp starts as false on a fresh instance")
    func isWarmedUpInitiallyFalse() throws {
        guard #available(macOS 26.0, *) else { return }
        let isolated = try self.makeIsolatedService()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        #expect(isolated.service.isWarmedUp == false)
    }

    @Test("createCommandSession returns nil when unavailable")
    func createCommandSessionNilWhenUnavailable() throws {
        guard #available(macOS 26.0, *) else { return }
        let isolated = try self.makeIsolatedService()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }

        isolated.service.isDisabledByUser = true

        let session = isolated.service.createCommandSession(
            instructions: "Test instructions",
            tools: []
        )

        #expect(session == nil)
    }

    @Test("createAnalysisSession returns nil when unavailable")
    func createAnalysisSessionNilWhenUnavailable() throws {
        guard #available(macOS 26.0, *) else { return }
        let isolated = try self.makeIsolatedService()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }

        isolated.service.isDisabledByUser = true

        let session = isolated.service.createAnalysisSession(instructions: "Test instructions")

        #expect(session == nil)
    }

    @Test("createConversationalSession returns nil when unavailable")
    func createConversationalSessionNilWhenUnavailable() throws {
        guard #available(macOS 26.0, *) else { return }
        let isolated = try self.makeIsolatedService()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }

        isolated.service.isDisabledByUser = true

        let session = isolated.service.createConversationalSession(instructions: "Test instructions")

        #expect(session == nil)
    }

    @Test("refreshAvailability does not throw")
    func refreshAvailabilityDoesNotThrow() throws {
        guard #available(macOS 26.0, *) else { return }
        let isolated = try self.makeIsolatedService()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }

        isolated.service.refreshAvailability()
    }
}
