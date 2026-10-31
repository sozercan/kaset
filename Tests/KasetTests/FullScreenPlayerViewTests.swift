import Foundation
import Testing
@testable import Kaset

@MainActor
struct FullScreenPlayerViewTests {
    @Test("Shuffle accessibility distinguishes off, on, and smart")
    func shuffleAccessibilityStates() {
        #expect(FullScreenPlayerView.shuffleAccessibilityValue(for: .off) == String(localized: "Off"))
        #expect(FullScreenPlayerView.shuffleAccessibilityValue(for: .on) == String(localized: "On"))
        #expect(FullScreenPlayerView.shuffleAccessibilityValue(for: .smart) == String(localized: "Smart"))
    }

    @Test("Repeat accessibility distinguishes off, all, and one")
    func repeatAccessibilityStates() {
        #expect(FullScreenPlayerView.repeatAccessibilityValue(for: .off) == String(localized: "Off"))
        #expect(FullScreenPlayerView.repeatAccessibilityValue(for: .all) == String(localized: "All"))
        #expect(FullScreenPlayerView.repeatAccessibilityValue(for: .one) == String(localized: "One"))
    }

    @Test("Like accessibility reports the current rating")
    func likeAccessibilityStates() {
        #expect(FullScreenPlayerView.likeAccessibilityValue(for: .like) == String(localized: "Liked"))
        #expect(FullScreenPlayerView.likeAccessibilityValue(for: .dislike) == String(localized: "Not liked"))
        #expect(FullScreenPlayerView.likeAccessibilityValue(for: .indifferent) == String(localized: "Not liked"))
    }
}
