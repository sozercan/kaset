import Foundation
import Testing
@testable import Kaset

/// Tests for the expanded Now Playing view state on PlayerService.
@Suite(.serialized, .tags(.service))
@MainActor
struct ExpandedPlayerStateTests {
    var playerService: PlayerService

    init() {
        // Reset UserDefaults to ensure clean initial state for tests
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        self.playerService = PlayerService()
    }

    @Test("Expanded player is hidden by default")
    func defaultsToHidden() {
        #expect(self.playerService.showExpandedPlayer == false)
    }

    @Test("Opening the expanded player does not mutate lyrics or queue panel state")
    func openingPreservesSidebarState() {
        self.playerService.showLyrics = true

        self.playerService.showExpandedPlayer = true

        #expect(self.playerService.showLyrics == true)
        #expect(self.playerService.showQueue == false)

        self.playerService.showExpandedPlayer = false

        #expect(self.playerService.showLyrics == true)
    }

    @Test("Toggling lyrics or queue does not close the expanded player")
    func sidebarTogglesPreserveExpandedPlayer() {
        self.playerService.showExpandedPlayer = true

        self.playerService.showLyrics = true
        #expect(self.playerService.showExpandedPlayer == true)

        self.playerService.showQueue = true
        #expect(self.playerService.showExpandedPlayer == true)
    }
}
