import SwiftUI
import Testing
@testable import Kaset

@Suite("Back navigation")
struct BackNavigationTests {
    @Test("YouTube mode goes back in the YouTube stack, whatever the music selection")
    func youtubeModeTargetsYouTubeStack() {
        let target = MainWindow.backNavigationTarget(
            appSource: .video,
            pinnedItemContentId: "pinned-album",
            navigationSelection: .explore
        )
        #expect(target == .youtube)
    }

    @Test("A selected pinned item takes precedence over the section selection")
    func pinnedItemTargetsItsOwnStack() {
        let target = MainWindow.backNavigationTarget(
            appSource: .music,
            pinnedItemContentId: "pinned-album",
            navigationSelection: .explore
        )
        #expect(target == .pinnedItem(contentId: "pinned-album"))
    }

    @Test("Music mode without a pinned item goes back in the selected section")
    func sectionTargetsSelectedSection() {
        let target = MainWindow.backNavigationTarget(
            appSource: .music,
            pinnedItemContentId: nil,
            navigationSelection: .library
        )
        #expect(target == .section(.library))
    }

    @Test("Nothing selected means nothing to go back in")
    func noSelectionHasNoTarget() {
        let target = MainWindow.backNavigationTarget(
            appSource: .music,
            pinnedItemContentId: nil,
            navigationSelection: nil
        )
        #expect(target == nil)
    }

    @Test("Going back removes one page")
    func removesOnePage() {
        var path = NavigationPath(["artist", "album"])
        path.removeLastIfNotEmpty()
        #expect(path.count == 1)
    }

    @Test("Going back at the root leaves the path empty")
    func emptyPathStaysEmpty() {
        var path = NavigationPath()
        path.removeLastIfNotEmpty()
        #expect(path.isEmpty)
    }
}
