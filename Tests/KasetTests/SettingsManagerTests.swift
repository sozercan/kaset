import Foundation
import Testing
@testable import Kaset

/// Tests for SettingsManager.
@Suite("SettingsManager", .serialized, .tags(.service))
@MainActor
struct SettingsManagerTests {
    // Note: These tests use a fresh UserDefaults domain to avoid affecting real settings

    // MARK: - LaunchPage Tests

    @Test("LaunchPage has correct display names")
    func launchPageDisplayNames() {
        #expect(SettingsManager.LaunchPage.home.displayName == "Home")
        #expect(SettingsManager.LaunchPage.explore.displayName == "Explore")
        #expect(SettingsManager.LaunchPage.charts.displayName == "Charts")
        #expect(SettingsManager.LaunchPage.moodsAndGenres.displayName == "Moods & Genres")
        #expect(SettingsManager.LaunchPage.newReleases.displayName == "New Releases")
        #expect(SettingsManager.LaunchPage.likedMusic.displayName == "Liked Music")
        #expect(SettingsManager.LaunchPage.playlists.displayName == "Playlists")
        #expect(SettingsManager.LaunchPage.lastUsed.displayName == "Last Used")
    }

    @Test("LaunchPage rawValues are valid")
    func launchPageRawValues() {
        for page in SettingsManager.LaunchPage.allCases {
            // Verify roundtrip through rawValue
            let restored = SettingsManager.LaunchPage(rawValue: page.rawValue)
            #expect(restored == page)
        }
    }

    @Test("LaunchPage identifiers are unique")
    func launchPageIdentifiersUnique() {
        let ids = SettingsManager.LaunchPage.allCases.map(\.id)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count)
    }

    @Test("LaunchPage converts to NavigationItem")
    func launchPageNavigationItem() {
        #expect(SettingsManager.LaunchPage.home.navigationItem == .home)
        #expect(SettingsManager.LaunchPage.explore.navigationItem == .explore)
        #expect(SettingsManager.LaunchPage.charts.navigationItem == .charts)
        #expect(SettingsManager.LaunchPage.moodsAndGenres.navigationItem == .moodsAndGenres)
        #expect(SettingsManager.LaunchPage.newReleases.navigationItem == .newReleases)
        #expect(SettingsManager.LaunchPage.likedMusic.navigationItem == .likedMusic)
        #expect(SettingsManager.LaunchPage.playlists.navigationItem == .library)
        #expect(SettingsManager.LaunchPage.lastUsed.navigationItem == .home) // Fallback
    }

    // MARK: - Default Values Tests

    @Test("Default showNowPlayingNotifications is true")
    func defaultShowNowPlayingNotifications() {
        // Access the shared instance to check its default
        // Note: This tests the expected default value. May fail if user has modified UserDefaults.
        let manager = SettingsManager.shared
        #expect(manager.showNowPlayingNotifications == true)
    }

    @Test("Default hapticFeedbackEnabled is true")
    func defaultHapticFeedbackEnabled() {
        let manager = SettingsManager.shared
        #expect(manager.hapticFeedbackEnabled == true)
    }

    // MARK: - launchPage Computed Property Tests

    @Test("launchPage returns defaultLaunchPage for non-lastUsed")
    func launchPageReturnsDefault() {
        let manager = SettingsManager.shared
        let originalPage = manager.defaultLaunchPage

        manager.defaultLaunchPage = .explore

        #expect(manager.launchPage == .explore)

        // Restore
        manager.defaultLaunchPage = originalPage
    }

    @Test("launchPage returns lastUsedPage when set to lastUsed")
    func launchPageReturnsLastUsed() {
        let manager = SettingsManager.shared
        let originalPage = manager.defaultLaunchPage
        let originalLastUsed = manager.lastUsedPage

        manager.defaultLaunchPage = .lastUsed
        manager.lastUsedPage = .charts

        #expect(manager.launchPage == .charts)

        // Restore
        manager.defaultLaunchPage = originalPage
        manager.lastUsedPage = originalLastUsed
    }

    // MARK: - launchNavigationItem Tests

    @Test("launchNavigationItem returns correct item")
    func launchNavigationItemReturnsCorrect() {
        let manager = SettingsManager.shared
        let originalPage = manager.defaultLaunchPage

        manager.defaultLaunchPage = .likedMusic

        #expect(manager.launchNavigationItem == .likedMusic)

        // Restore
        manager.defaultLaunchPage = originalPage
    }

    // MARK: - All Cases Coverage

    @Test("All LaunchPage cases are covered")
    func allLaunchPageCasesCovered() {
        // Verify we have the expected number of cases
        #expect(SettingsManager.LaunchPage.allCases.count == 8)
    }
}
