import AppKit
import Testing
@testable import Kaset

@Suite("YouTube video window level policy", .serialized, .tags(.service))
@MainActor
struct YouTubeVideoWindowLevelPolicyTests {
    @Test("Windowed unpinned state uses the normal level")
    func unpinnedUsesNormalLevel() {
        #expect(YouTubeVideoWindowLevelPolicy.windowedLevel(isPinned: false) == .normal)
    }

    @Test("Windowed pinned state uses the floating level")
    func pinnedUsesFloatingLevel() {
        #expect(YouTubeVideoWindowLevelPolicy.windowedLevel(isPinned: true) == .floating)
    }

    @Test("Live changes are allowed only outside fullscreen and transitions")
    func liveChangeGating() {
        #expect(YouTubeVideoWindowLevelPolicy.canApplyLiveChange(isFullscreenOrTransitioning: false))
        #expect(!YouTubeVideoWindowLevelPolicy.canApplyLiveChange(isFullscreenOrTransitioning: true))
    }

    @Test("Fullscreen phases gate windowed controls across both transitions")
    func fullscreenPhaseGating() {
        #expect(!YouTubeVideoWindowFullscreenPhase.windowed.blocksWindowedControls)
        #expect(YouTubeVideoWindowFullscreenPhase.entering.blocksWindowedControls)
        #expect(YouTubeVideoWindowFullscreenPhase.fullscreen.blocksWindowedControls)
        #expect(YouTubeVideoWindowFullscreenPhase.exiting.blocksWindowedControls)
    }

    @Test("Float on Top controls require a windowed floating surface")
    func controlAvailability() {
        #expect(YouTubeVideoWindowLevelPolicy.canToggleFloatOnTop(
            isFloating: true,
            isFullscreenOrTransitioning: false
        ))
        #expect(!YouTubeVideoWindowLevelPolicy.canToggleFloatOnTop(
            isFloating: false,
            isFullscreenOrTransitioning: false
        ))
        #expect(!YouTubeVideoWindowLevelPolicy.canToggleFloatOnTop(
            isFloating: true,
            isFullscreenOrTransitioning: true
        ))
    }

    @Test("Collection behavior preserves normal-window Mission Control and cycling behavior")
    func collectionBehaviorPreservesNormalWindowParticipation() {
        let behavior = YouTubeVideoWindowLevelPolicy.collectionBehavior(preserving: [
            .moveToActiveSpace,
            .transient,
            .ignoresCycle,
        ])

        #expect(behavior.contains(.moveToActiveSpace))
        #expect(behavior.contains(.managed))
        #expect(behavior.contains(.participatesInCycle))
        #expect(behavior.contains(.fullScreenPrimary))
        #expect(!behavior.contains(.transient))
        #expect(!behavior.contains(.stationary))
        #expect(!behavior.contains(.ignoresCycle))
    }
}
