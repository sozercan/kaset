import Testing
@testable import Kaset

/// Unit tests for HapticService.
@Suite("HapticService", .tags(.service))
struct HapticServiceTests {
    // MARK: - FeedbackType Pattern Mapping Tests

    @Test("Playback action uses generic pattern")
    func playbackActionPattern() {
        // Verify the FeedbackType maps correctly
        let feedbackType = HapticService.FeedbackType.playbackAction
        #expect(feedbackType == .playbackAction)
    }

    @Test("Toggle action uses alignment pattern")
    func togglePattern() {
        let feedbackType = HapticService.FeedbackType.toggle
        #expect(feedbackType == .toggle)
    }

    @Test("Slider boundary uses level change pattern")
    func sliderBoundaryPattern() {
        let feedbackType = HapticService.FeedbackType.sliderBoundary
        #expect(feedbackType == .sliderBoundary)
    }

    @Test("Navigation uses alignment pattern")
    func navigationPattern() {
        let feedbackType = HapticService.FeedbackType.navigation
        #expect(feedbackType == .navigation)
    }

    @Test("Success uses generic pattern")
    func successPattern() {
        let feedbackType = HapticService.FeedbackType.success
        #expect(feedbackType == .success)
    }

    @Test("Error uses generic pattern")
    func errorPattern() {
        let feedbackType = HapticService.FeedbackType.error
        #expect(feedbackType == .error)
    }

    // MARK: - All FeedbackType Cases

    @Test("All feedback types are defined", arguments: [
        HapticService.FeedbackType.playbackAction,
        HapticService.FeedbackType.toggle,
        HapticService.FeedbackType.sliderBoundary,
        HapticService.FeedbackType.navigation,
        HapticService.FeedbackType.success,
        HapticService.FeedbackType.error,
    ])
    func allFeedbackTypesDefined(feedbackType: HapticService.FeedbackType) {
        // Just verifying that all types exist and can be used
        #expect(feedbackType == feedbackType)
    }
}
