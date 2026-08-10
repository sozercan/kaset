import Testing
@testable import Kaset

@Suite("YouTube watch regressions")
@MainActor
struct YouTubeWatchRegressionTests {
    @Test("Ask player offset converts normal progress to rounded milliseconds")
    func askPlayerOffsetConvertsNormalProgress() {
        #expect(YouTubeAskPlayerOffset.milliseconds(for: 12.3456) == 12346)
    }

    @Test("Ask player offset clamps negative progress to zero")
    func askPlayerOffsetClampsNegativeProgress() {
        #expect(YouTubeAskPlayerOffset.milliseconds(for: -42) == 0)
    }

    @Test("Ask player offset clamps huge finite progress without trapping")
    func askPlayerOffsetClampsHugeFiniteProgress() {
        #expect(
            YouTubeAskPlayerOffset.milliseconds(for: Double.greatestFiniteMagnitude)
                == Int64.max
        )
    }

    @Test("Ask player offset maps non-finite progress to zero")
    func askPlayerOffsetRejectsNonFiniteProgress() {
        #expect(YouTubeAskPlayerOffset.milliseconds(for: .nan) == 0)
        #expect(YouTubeAskPlayerOffset.milliseconds(for: .infinity) == 0)
        #expect(YouTubeAskPlayerOffset.milliseconds(for: -.infinity) == 0)
    }

    @Test("UI-test Ask capability survives an account-scope session reset")
    func mockAskCapabilitySurvivesAccountReset() async throws {
        let client = MockUITestYouTubeClient(isAskGeminiEligible: true)

        let initialPage = try await client.getWatchPage(videoId: "mock-video-1")
        #expect(initialPage.askBootstrap != nil)

        client.resetSessionStateForAccountSwitch()

        let resetPage = try await client.getWatchPage(videoId: "mock-video-1")
        #expect(resetPage.askBootstrap != nil)
    }

    @Test("UI-test suggestion continuation keeps free-text Ask enabled")
    func mockSuggestionContinuationKeepsFreeTextEnabled() async throws {
        let client = MockUITestYouTubeClient(isAskGeminiEligible: true)
        let page = try await client.getWatchPage(videoId: "mock-video-1")
        let bootstrap = try #require(page.askBootstrap)
        let conversation = try await client.loadAskConversation(from: bootstrap)
        let suggestion = try #require(conversation.suggestions.first)
        let pendingConversation = try #require(
            conversation.appendingUserTurn(for: suggestion.id)
        )

        let continuedConversation = try await client.continueAskConversation(
            pendingConversation,
            selecting: suggestion.id
        )

        #expect(continuedConversation.canSubmitFreeText)
    }

    @Test("UI-test free-text continuation keeps free-text Ask enabled")
    func mockFreeTextContinuationKeepsFreeTextEnabled() async throws {
        let client = MockUITestYouTubeClient(isAskGeminiEligible: true)
        let page = try await client.getWatchPage(videoId: "mock-video-1")
        let bootstrap = try #require(page.askBootstrap)
        let conversation = try await client.loadAskConversation(from: bootstrap)
        let pendingConversation = try #require(
            conversation.appendingUserTurn(text: "What happens next?")
        )

        let continuedConversation = try await client.continueAskConversation(
            pendingConversation,
            submitting: "What happens next?",
            playerOffsetMilliseconds: 1000
        )

        #expect(continuedConversation.canSubmitFreeText)
    }
}
