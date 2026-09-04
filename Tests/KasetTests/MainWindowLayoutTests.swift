import AppKit
import Testing
@testable import Kaset

@Suite("Main window layout", .serialized)
struct MainWindowLayoutTests {
    @Test("AI task surfaces use the shared 72-point top inset")
    func aiTaskSurfaceTopPadding() {
        #expect(MainWindowLayout.aiTaskSurfaceTopPadding == 72)
    }

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

    @Test("Configure primary window sets transparent titlebar properties")
    @MainActor
    func configurePrimaryWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = MainWindowLayout.windowTitle

        MainWindowLayout.configure(window)

        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent == true)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.isMovableByWindowBackground == false)
    }

    @Test("Restore windowed appearance sets transparent titlebar properties")
    @MainActor
    func restoreWindowedAppearance() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = MainWindowLayout.windowTitle

        MainWindowLayout.restoreWindowedAppearance(window)

        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent == true)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.isMovableByWindowBackground == false)
    }
}
