import SwiftUI
import Testing
@testable import Kaset

@Suite("YouTube chapters section layout", .serialized)
@MainActor
struct YouTubeChaptersSectionLayoutTests {
    @Test("Expanded shelf hugs the cards and the header collapses it")
    func shelfHugsCardsAndHeaderCollapses() throws {
        let expanded = try Self.renderedHeight(initiallyExpanded: true)
        #expect(expanded > 140)
        #expect(expanded < 320)

        let collapsed = try Self.renderedHeight(initiallyExpanded: false)
        #expect(collapsed < 96)
        #expect(expanded - collapsed >= 80)
    }

    private static func renderedHeight(initiallyExpanded: Bool) throws -> CGFloat {
        let chapters = [
            YouTubeChapter(
                videoId: "watch-video",
                title: "Intro",
                startTime: 0,
                endTime: 75,
                timeText: "0:00",
                thumbnailURL: nil
            ),
            YouTubeChapter(
                videoId: "watch-video",
                title: "A longer chapter title that wraps onto a second line",
                startTime: 75,
                endTime: nil,
                timeText: "1:15",
                thumbnailURL: nil
            ),
        ]
        let renderer = ImageRenderer(content: YouTubeChaptersSection(
            chapters: chapters,
            isActiveChapter: { _ in false },
            canSeekToChapter: { _ in false },
            seekToChapter: { _ in },
            initiallyExpanded: initiallyExpanded
        ))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 720, height: 980)

        let image = try #require(renderer.nsImage)
        return image.size.height
    }
}
