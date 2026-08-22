import Foundation
import Testing
@testable import Kaset

@MainActor
@Suite(.serialized, .tags(.viewModel))
struct PlaylistAutoLoadSettingTests {
    @Test("autoLoadFullPlaylistOnOpen persists round-trip")
    func persistsRoundTrip() {
        let manager = SettingsManager.shared
        let original = manager.autoLoadFullPlaylistOnOpen
        defer { manager.autoLoadFullPlaylistOnOpen = original }

        manager.autoLoadFullPlaylistOnOpen = true
        #expect(UserDefaults.standard.bool(forKey: "settings.autoLoadFullPlaylistOnOpen") == true)

        manager.autoLoadFullPlaylistOnOpen = false
        #expect(UserDefaults.standard.object(forKey: "settings.autoLoadFullPlaylistOnOpen") as? Bool == false)
    }
}
