import AppKit
import Testing
@testable import Kaset

/// Tests for the persisted app appearance override.
@Suite(.serialized, .tags(.service))
@MainActor
struct AppAppearanceTests {
    @Test("Saved appearance loads, falling back to system")
    func restoresSavedChoiceAndFallsBackToSystem() throws {
        let suiteName = "AppAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsManager.loadAppearance(from: defaults) == .system)
        for appearance in AppAppearance.allCases {
            defaults.set(appearance.rawValue, forKey: SettingsManager.Keys.appearance)
            #expect(SettingsManager.loadAppearance(from: defaults) == appearance)
        }
        defaults.set("unknown", forKey: SettingsManager.Keys.appearance)
        #expect(SettingsManager.loadAppearance(from: defaults) == .system)
    }

    @Test("Changing appearance persists it and applies it app-wide")
    func changingAppearancePersistsAndApplies() {
        let manager = SettingsManager.shared
        let application = NSApplication.shared
        let originalValue = manager.appearance
        let originalAppearance = application.appearance
        defer {
            manager.appearance = originalValue
            application.appearance = originalAppearance
        }

        let expectedNames: [AppAppearance: NSAppearance.Name] = [.light: .aqua, .dark: .darkAqua]
        // End on the original value so every assignment is a real change.
        for appearance in AppAppearance.allCases.filter({ $0 != originalValue }) + [originalValue] {
            manager.appearance = appearance
            #expect(UserDefaults.standard.string(forKey: SettingsManager.Keys.appearance) == appearance.rawValue)
            #expect(application.appearance?.name == expectedNames[appearance])
        }
    }

    @Test("Launch applies the saved appearance")
    func launchAppliesSavedAppearance() {
        let manager = SettingsManager.shared
        let application = NSApplication.shared
        let originalValue = manager.appearance
        let originalAppearance = application.appearance
        defer {
            manager.appearance = originalValue
            application.appearance = originalAppearance
        }

        manager.appearance = originalValue == .dark ? .light : .dark
        application.appearance = nil

        AppDelegate().applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))

        #expect(application.appearance?.name == manager.appearance.nsAppearance?.name)
    }
}
