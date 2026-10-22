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

    @Test("Persistent player mounts for authenticated preload or guest playback")
    func persistentPlayerMountingPolicy() {
        #expect(MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: true,
            pendingVideoId: nil,
            isPendingRestoredLoadDeferred: false,
            showVideo: false
        ))
        #expect(MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: false,
            pendingVideoId: "public-video",
            isPendingRestoredLoadDeferred: false,
            showVideo: false
        ))
        #expect(!MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: false,
            pendingVideoId: nil,
            isPendingRestoredLoadDeferred: false,
            showVideo: false
        ))
    }

    @Test("Persistent player defers guest restoration and respects video window ownership", arguments: [true, false])
    func persistentPlayerMountingRespectsPlaybackState(isLoggedIn: Bool) {
        #expect(MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: isLoggedIn,
            pendingVideoId: "restored-video",
            isPendingRestoredLoadDeferred: true,
            showVideo: false
        ) == isLoggedIn)
        #expect(!MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: isLoggedIn,
            pendingVideoId: "playing-video",
            isPendingRestoredLoadDeferred: false,
            showVideo: true
        ))
        #expect(!MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: isLoggedIn,
            pendingVideoId: "restored-video",
            isPendingRestoredLoadDeferred: true,
            showVideo: true
        ))
    }
}
