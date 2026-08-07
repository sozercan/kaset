import Testing
@testable import Kaset

@Suite("App activation window policy", .tags(.service))
struct AppActivationWindowPolicyTests {
    @Test("Auxiliary key windows do not reveal the main window")
    func auxiliaryKeyWindowDoesNotRevealMainWindow() {
        #expect(!AppActivationWindowPolicy.shouldRevealMainWindow(
            keyWindowIdentifier: AccessibilityID.YouTubeContent.videoWindow,
            mainWindowIdentifier: nil
        ))
    }

    @Test("Auxiliary main windows do not reveal the main window")
    func auxiliaryMainWindowDoesNotRevealMainWindow() {
        #expect(!AppActivationWindowPolicy.shouldRevealMainWindow(
            keyWindowIdentifier: nil,
            mainWindowIdentifier: AccessibilityID.MiniPlayer.container
        ))
    }

    @Test("Ordinary or absent active windows allow normal activation behavior")
    func ordinaryActivationRevealsMainWindow() {
        #expect(AppActivationWindowPolicy.shouldRevealMainWindow(
            keyWindowIdentifier: "settings",
            mainWindowIdentifier: nil
        ))
        #expect(AppActivationWindowPolicy.shouldRevealMainWindow(
            keyWindowIdentifier: nil,
            mainWindowIdentifier: nil
        ))
    }
}
