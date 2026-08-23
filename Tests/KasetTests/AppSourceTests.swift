import Foundation
import Testing
@testable import Kaset

/// Tests for the AppSource model and its SettingsManager persistence.
@Suite("AppSource", .serialized, .tags(.model))
@MainActor
struct AppSourceTests {
    @Test("Raw values round-trip")
    func rawValueRoundTrip() {
        for source in AppSource.allCases {
            #expect(AppSource(rawValue: source.rawValue) == source)
        }
    }

    @Test("Identifiers are unique")
    func identifiersUnique() {
        let ids = AppSource.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Display names and icons are non-empty")
    func displayNamesAndIcons() {
        for source in AppSource.allCases {
            #expect(!source.displayName.isEmpty)
            #expect(!source.icon.isEmpty)
        }
    }

    @Test("Music is the first segment in the toggle order")
    func musicIsFirst() {
        #expect(AppSource.allCases.first == .music)
    }

    @Test("SettingsManager persists appSource to UserDefaults")
    func settingsManagerPersistsAppSource() {
        let manager = SettingsManager.shared
        let original = manager.appSource
        defer {
            manager.appSource = original
        }

        manager.appSource = .video
        #expect(
            UserDefaults.standard.string(forKey: SettingsManager.Keys.appSource)
                == AppSource.video.rawValue
        )

        manager.appSource = .music
        #expect(
            UserDefaults.standard.string(forKey: SettingsManager.Keys.appSource)
                == AppSource.music.rawValue
        )
    }
}
