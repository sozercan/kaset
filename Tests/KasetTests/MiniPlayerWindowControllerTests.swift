import AppKit
import Testing
@testable import Kaset

// MARK: - MiniPlayerWindowControllerTests

@Suite("Mini player playback hosting", .serialized, .tags(.service))
@MainActor
struct MiniPlayerWindowControllerTests {
    @Test("Minimizing and restoring an open mini player transfers playback hosting", arguments: [
        PlayerService.MiniPlayerMode.auxiliary,
        .switchFromMainWindow,
    ])
    func miniaturizationTransfersPlaybackHosting(mode: PlayerService.MiniPlayerMode) {
        let playerService = PlayerService()
        playerService.openMiniPlayer(mode: mode)
        let window = Self.makeWindow()
        let controller = MiniPlayerWindowController.makeTestInstance(window: window, playerService: playerService)
        defer { controller.close() }
        #expect(playerService.shouldHostPlaybackInMiniPlayer)

        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)

        #expect(playerService.isMiniPlayerVisible)
        #expect(playerService.isMiniPlayerMiniaturized)
        #expect(!playerService.shouldHostPlaybackInMiniPlayer)

        let otherWindow = Self.makeWindow()
        defer { otherWindow.close() }
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: otherWindow)
        #expect(!playerService.shouldHostPlaybackInMiniPlayer)

        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)

        #expect(playerService.isMiniPlayerVisible)
        #expect(!playerService.isMiniPlayerMiniaturized)
        #expect(playerService.shouldHostPlaybackInMiniPlayer)

        playerService.showVideo = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        #expect(!playerService.shouldHostPlaybackInMiniPlayer)
    }

    @Test("Closing a minimized window clears its state and ignores late notifications")
    func closingMinimizedWindowClearsState() {
        let playerService = PlayerService()
        playerService.openMiniPlayer()
        let window = Self.makeWindow()
        let controller = MiniPlayerWindowController.makeTestInstance(window: window, playerService: playerService)
        defer { controller.close() }
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(playerService.isMiniPlayerMiniaturized)

        controller.closeFromUserAction()

        #expect(!playerService.isMiniPlayerVisible)
        #expect(!playerService.isMiniPlayerMiniaturized)
        #expect(!playerService.shouldHostPlaybackInMiniPlayer)

        playerService.openMiniPlayer()
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(!playerService.isMiniPlayerMiniaturized)
        #expect(playerService.shouldHostPlaybackInMiniPlayer)
    }

    private static func makeWindow() -> NSWindow {
        let window = MiniPlayerTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 184),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}

// MARK: - MiniPlayerTestWindow

@MainActor
private final class MiniPlayerTestWindow: NSWindow {
    override func saveFrame(usingName _: NSWindow.FrameAutosaveName) {}
}
