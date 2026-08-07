import SwiftUI
import Testing
@testable import Kaset

@Suite("YouTube Ask panel layout", .serialized)
@MainActor
struct YouTubeAskPanelLayoutTests {
    @Test("Short chip content remains compact like the Music command bar")
    func shortChipContentUsesIntrinsicHeight() async throws {
        let client = MockYouTubeClient()
        client.askConversation = YouTubeAskConversation.testing(suggestions: [
            "Summarize the video",
            "Recommend related content",
        ])
        let viewModel = YouTubeAskViewModel(videoID: "fixture-video", client: client)
        viewModel.seed(YouTubeAskBootstrap.testing(suggestions: [
            "Summarize the video",
            "Recommend related content",
        ]))
        viewModel.setExpanded(true)

        for _ in 0 ..< 100 where viewModel.activity != .idle || viewModel.suggestions.isEmpty {
            await Task.yield()
        }
        #expect(viewModel.activity == .idle)
        #expect(viewModel.suggestions.count == 2)

        let renderer = ImageRenderer(content: YouTubeAskPanelView(
            viewModel: viewModel,
            maximumHeight: 700,
            playerOffsetMilliseconds: 0
        ))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 500, height: 700)

        let image = try #require(renderer.nsImage)
        #expect(image.size.height < 300)
    }

    @Test("Long replies use the bounded scrolling height")
    func longReplyUsesBoundedHeight() async throws {
        let client = MockYouTubeClient()
        let longReply = Array(repeating: "A detailed generated response that remains selectable.", count: 80)
            .joined(separator: "\n\n")
        client.askConversation = YouTubeAskConversation.testing(
            messages: [
                YouTubeAskMessage(role: .user, text: "Summarize the video"),
                YouTubeAskMessage(role: .assistant, text: longReply),
            ],
            suggestions: ["Ask a follow-up"]
        )
        let viewModel = YouTubeAskViewModel(videoID: "fixture-video", client: client)
        viewModel.seed(YouTubeAskBootstrap.testing(suggestions: ["Summarize the video"]))
        viewModel.setExpanded(true)

        for _ in 0 ..< 100 where viewModel.activity != .idle || viewModel.messages.isEmpty {
            await Task.yield()
        }
        #expect(viewModel.messages.count == 2)

        let renderer = ImageRenderer(content: YouTubeAskPanelView(
            viewModel: viewModel,
            maximumHeight: 700,
            playerOffsetMilliseconds: 0
        ))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 500, height: 700)

        let image = try #require(renderer.nsImage)
        #expect(image.size.height > 300)
        #expect(image.size.height <= 580)
    }

    @Test("Free-text composer and Music-style chips remain compact")
    func composerAndWrappedSuggestionsUseCompactHeight() async throws {
        let client = MockYouTubeClient()
        let suggestions = [
            "Summarize the video",
            "Recommend related content",
            "Explain the main claim",
            "List the key moments",
            "What should I know?",
            "Ask about a detail",
        ]
        let viewModel = YouTubeAskViewModel(videoID: "fixture-video", client: client)
        viewModel.seed(YouTubeAskBootstrap.testing(
            suggestions: suggestions,
            allowsFreeText: true
        ))
        viewModel.setExpanded(true)

        for _ in 0 ..< 100 where viewModel.activity != .idle || !viewModel.acceptsFreeTextInput {
            await Task.yield()
        }
        #expect(viewModel.acceptsFreeTextInput)
        #expect(viewModel.suggestions.count == suggestions.count)

        let renderer = ImageRenderer(content: YouTubeAskPanelView(
            viewModel: viewModel,
            maximumHeight: 700,
            playerOffsetMilliseconds: 0
        ))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 500, height: 700)

        let image = try #require(renderer.nsImage)
        #expect(image.size.height > 150)
        #expect(image.size.height < 400)
    }
}
