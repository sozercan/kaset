import Testing
@testable import Kaset

@Suite("Accessibility identifiers")
struct AccessibilityIdentifiersTests {
    @Test("Player window identifiers are auxiliary")
    func playerWindowIdentifiersAreAuxiliary() {
        #expect(AccessibilityID.isAuxiliaryPlayerWindowIdentifier(AccessibilityID.VideoWindow.container))
        #expect(AccessibilityID.isAuxiliaryPlayerWindowIdentifier(AccessibilityID.MiniPlayer.container))
        #expect(AccessibilityID.isAuxiliaryPlayerWindowIdentifier(AccessibilityID.YouTubeContent.videoWindow))
    }

    @Test("YouTube video window identifiers are stable")
    func youtubeVideoWindowIdentifiersAreStable() {
        #expect(AccessibilityID.YouTubeContent.videoWindow == "youtubeContent.videoWindow")
        #expect(AccessibilityID.YouTubeContent.videoWindowFloatOnTop == "youtubeContent.videoWindow.floatOnTop")
    }

    @Test("Missing and unrelated identifiers are not auxiliary")
    func missingAndUnrelatedIdentifiersAreNotAuxiliary() {
        #expect(!AccessibilityID.isAuxiliaryPlayerWindowIdentifier(nil))
        #expect(!AccessibilityID.isAuxiliaryPlayerWindowIdentifier(""))
        #expect(!AccessibilityID.isAuxiliaryPlayerWindowIdentifier("unrelated.window"))
    }
}
