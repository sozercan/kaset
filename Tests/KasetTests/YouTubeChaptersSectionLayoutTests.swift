import SwiftUI
import Testing
@testable import Kaset

@Suite("YouTube chapters section layout", .serialized)
@MainActor
struct YouTubeChaptersSectionLayoutTests {
    private static let longTitle = "A longer chapter title that wraps onto a second line"

    @Test("Expanded shelf hugs the cards and the header collapses it")
    func shelfHugsCardsAndHeaderCollapses() throws {
        let chapters = [
            Self.chapter(index: 0, title: "Intro"),
            Self.chapter(index: 1, title: Self.longTitle),
        ]
        let expanded = try Self.renderedHeight(chapters: chapters, initiallyExpanded: true)
        #expect(expanded > 140)
        #expect(expanded < 320)

        let collapsed = try Self.renderedHeight(chapters: chapters, initiallyExpanded: false)
        #expect(collapsed < 96)
        #expect(expanded - collapsed >= 80)
    }

    /// The row is lazy and can size from its first card, so every card must
    /// reserve the same height. Otherwise a wrapping title after the first card,
    /// visible or still offscreen, is clipped.
    @Test("Shelf leaves room for a wrapping title on any card")
    func shelfHeightIsStableAcrossTitleLengths() throws {
        let wrappingFirst = try Self.renderedHeight(
            chapters: [Self.chapter(index: 0, title: Self.longTitle)],
            initiallyExpanded: true
        )
        let shortTitles = (0 ..< 12).map { Self.chapter(index: $0, title: "Part \($0)") }
        var wrappingVisible = shortTitles
        wrappingVisible[1] = Self.chapter(index: 1, title: Self.longTitle)
        var wrappingOffscreen = shortTitles
        wrappingOffscreen[11] = Self.chapter(index: 11, title: Self.longTitle)

        #expect(try Self.renderedHeight(chapters: wrappingVisible, initiallyExpanded: true) == wrappingFirst)
        #expect(try Self.renderedHeight(chapters: wrappingOffscreen, initiallyExpanded: true) == wrappingFirst)
        #expect(try Self.renderedHeight(chapters: shortTitles, initiallyExpanded: true) == wrappingFirst)
    }

    private static func chapter(index: Int, title: String) -> YouTubeChapter {
        YouTubeChapter(
            videoId: "watch-video",
            title: title,
            startTime: TimeInterval(index * 75),
            endTime: nil,
            timeText: nil,
            thumbnailURL: nil
        )
    }

    private static func renderedHeight(
        chapters: [YouTubeChapter],
        initiallyExpanded: Bool
    ) throws -> CGFloat {
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
