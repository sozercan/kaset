import Foundation
import Testing
@testable import Kaset

@Suite("YouTube player bar", .tags(.model))
@MainActor
struct YouTubePlayerBarTests {
    @Test("Chapter segments resolve explicit, next-chapter, and duration end times")
    func chapterSegmentsResolveEndTimes() throws {
        let chapters = [
            self.chapter(title: "Opening", start: 0, end: 45),
            self.chapter(title: "Main topic", start: 60),
            self.chapter(title: "Closing", start: 180),
        ]

        let segments = YouTubePlayerBar.chapterProgressSegments(chapters: chapters, duration: 300)
        #expect(segments.count == 3)

        let opening = try #require(segments.first)
        #expect(opening.start == 0)
        #expect(abs(opening.end - 0.15) < 0.000_001)
        #expect(opening.title == "Opening")
        #expect(opening.itemLabel == String(localized: "Chapter"))
        #expect(opening.rangeText == "0:00 – 0:45")

        let mainTopic = segments[1]
        #expect(abs(mainTopic.start - 0.2) < 0.000_001)
        #expect(abs(mainTopic.end - 0.6) < 0.000_001)
        #expect(mainTopic.title == "Main topic")
        #expect(mainTopic.itemLabel == String(localized: "Chapter"))
        #expect(mainTopic.rangeText == "1:00 – 3:00")

        let closing = try #require(segments.last)
        #expect(abs(closing.start - 0.6) < 0.000_001)
        #expect(closing.end == 1)
        #expect(closing.title == "Closing")
        #expect(closing.itemLabel == String(localized: "Chapter"))
        #expect(closing.rangeText == "3:00 – 5:00")

        #expect(segments.map(\.index) == [0, 1, 2])
        #expect(segments.allSatisfy { $0.count == 3 })
    }

    @Test("Explicit chapter ends are capped by the next chapter and video duration")
    func explicitEndsAreCapped() throws {
        let chapters = [
            self.chapter(title: "Overlaps next", start: 0, end: 180),
            self.chapter(title: "Past duration", start: 100, end: 500),
        ]

        let segments = YouTubePlayerBar.chapterProgressSegments(chapters: chapters, duration: 240)
        #expect(segments.count == 2)

        let first = try #require(segments.first)
        #expect(first.start == 0)
        #expect(abs(first.end - (100.0 / 240.0)) < 0.000_001)
        #expect(first.rangeText == "0:00 – 1:40")

        let second = try #require(segments.last)
        #expect(abs(second.start - (100.0 / 240.0)) < 0.000_001)
        #expect(second.end == 1)
        #expect(second.rangeText == "1:40 – 4:00")
    }

    @Test("Invalid starts and duplicate boundaries are omitted and valid spans are reindexed")
    func invalidChaptersAreOmittedAndSegmentsAreReindexed() {
        let chapters = [
            self.chapter(title: "Intro", start: 0, end: 80),
            self.chapter(title: "Recovered end", start: 80, end: 80),
            self.chapter(title: "Final", start: 180),
            self.chapter(title: "Final", start: 180),
            self.chapter(title: "Negative", start: -1, end: 20),
            self.chapter(title: "Not a number", start: .nan, end: 20),
            self.chapter(title: "Infinite", start: .infinity, end: nil),
            self.chapter(title: "At duration", start: 300, end: nil),
            self.chapter(title: "Past duration", start: 450, end: nil),
        ]

        let segments = YouTubePlayerBar.chapterProgressSegments(chapters: chapters, duration: 300)

        #expect(segments.count == 3)
        #expect(segments.map(\.index) == [0, 1, 2])
        #expect(segments.allSatisfy { $0.count == 3 })
        #expect(segments.map(\.title) == ["Intro", "Recovered end", "Final"])

        #expect(segments[0].start == 0)
        #expect(abs(segments[0].end - (80.0 / 300.0)) < 0.000_001)
        #expect(abs(segments[1].start - (80.0 / 300.0)) < 0.000_001)
        #expect(abs(segments[1].end - (180.0 / 300.0)) < 0.000_001)
        #expect(segments[1].rangeText == "1:20 – 3:00")
        #expect(abs(segments[2].start - (180.0 / 300.0)) < 0.000_001)
        #expect(segments[2].end == 1)
    }

    private func chapter(
        title: String,
        start: TimeInterval,
        end: TimeInterval? = nil
    ) -> YouTubeChapter {
        YouTubeChapter(
            videoId: "video-id",
            title: title,
            startTime: start,
            endTime: end,
            timeText: nil,
            thumbnailURL: nil
        )
    }
}
