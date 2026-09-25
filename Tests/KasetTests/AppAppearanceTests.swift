import AppKit
import Testing
@testable import Kaset

@MainActor
struct AppAppearanceTests {
    @Test
    func restoresSavedChoiceAndFallsBackToSystem() throws {
        let suiteName = "AppAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppAppearance.load(from: defaults) == .system)
        for appearance in AppAppearance.allCases {
            defaults.set(appearance.rawValue, forKey: SettingsManager.Keys.appearance)
            #expect(AppAppearance.load(from: defaults) == appearance)
        }
        defaults.set("unknown", forKey: SettingsManager.Keys.appearance)
        #expect(AppAppearance.load(from: defaults) == .system)
    }

    @Test
    func systemClearsOverrideAndExplicitModesSelectNativeAppearance() {
        #expect(AppAppearance.system.nsAppearance == nil)
        #expect(AppAppearance.light.nsAppearance?.name == .aqua)
        #expect(AppAppearance.dark.nsAppearance?.name == .darkAqua)
    }
}
