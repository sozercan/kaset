import AppKit
import Testing
@testable import Kaset

// MARK: - YouTubeWatchSurfaceOwnershipTests

@MainActor
struct YouTubeWatchSurfaceOwnershipTests {
    @Test("A late outgoing Shorts host cannot reclaim the selected surface")
    func lateOutgoingShortsHostCannotReclaimSelectedSurface() {
        let surface = NSView()
        let firstContainer = NSView()
        let secondContainer = NSView()

        #expect(YouTubeWatchSurfaceAttachment.claim(
            surface: surface,
            in: firstContainer,
            expectedVideoId: "short-a",
            currentVideoId: "short-a"
        ))
        #expect(YouTubeWatchSurfaceAttachment.claim(
            surface: surface,
            in: secondContainer,
            expectedVideoId: "short-b",
            currentVideoId: "short-b"
        ))
        #expect(!YouTubeWatchSurfaceAttachment.claim(
            surface: surface,
            in: firstContainer,
            expectedVideoId: "short-a",
            currentVideoId: "short-b"
        ))
        #expect(!YouTubeWatchSurfaceAttachment.claim(
            surface: surface,
            in: firstContainer,
            expectedVideoId: "short-a",
            currentVideoId: nil
        ))

        #expect(surface.superview === secondContainer)
        #expect(!firstContainer.subviews.contains { $0 === surface })
    }

    @Test("Unscoped watch and floating hosts retain existing handoff behavior")
    func unscopedHostsCanClaimSurface() {
        let surface = NSView()
        let watchContainer = NSView()
        let floatingContainer = NSView()

        #expect(YouTubeWatchSurfaceAttachment.claim(
            surface: surface,
            in: watchContainer,
            expectedVideoId: nil,
            currentVideoId: nil
        ))
        #expect(YouTubeWatchSurfaceAttachment.claim(
            surface: surface,
            in: floatingContainer,
            expectedVideoId: nil,
            currentVideoId: "current-video"
        ))
        #expect(surface.superview === floatingContainer)
    }
}
