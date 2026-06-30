import AppKit
import Testing
@testable import Kaset

@Suite("Main window layout", .serialized)
struct MainWindowLayoutTests {
    @Test("Clamps undersized restored content frames")
    func clampsUndersizedContentFrames() {
        let clamped = MainWindowLayout.clampedContentSize(NSSize(width: 640, height: 420))

        #expect(clamped.width == MainWindowLayout.minimumWidth)
        #expect(clamped.height == MainWindowLayout.minimumHeight)
    }

    @Test("Leaves larger content frames unchanged")
    func leavesLargerContentFramesUnchanged() {
        let size = NSSize(width: 1400, height: 900)

        #expect(MainWindowLayout.clampedContentSize(size) == size)
    }

    @Test("Minimum AppKit content size matches SwiftUI content floor")
    func minimumContentSizeMatchesSwiftUIFloor() {
        #expect(MainWindowLayout.minimumContentSize.width == MainWindowLayout.minimumWidth)
        #expect(MainWindowLayout.minimumContentSize.height == MainWindowLayout.minimumHeight)
    }

    @Test("Primary window identity excludes other regular scene windows")
    func primaryWindowIdentityExcludesOtherRegularSceneWindows() {
        #expect(MainWindowLayout.isPrimaryWindowIdentity(title: MainWindowLayout.windowTitle, frameAutosaveName: ""))
        #expect(MainWindowLayout.isPrimaryWindowIdentity(title: "Settings", frameAutosaveName: MainWindowLayout.autosaveName))
        #expect(!MainWindowLayout.isPrimaryWindowIdentity(title: "Settings", frameAutosaveName: ""))
    }
}
