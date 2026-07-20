import Foundation
import Testing
@testable import Kaset

@Suite("Player bar progress lane", .tags(.model))
@MainActor
struct PlayerBarProgressLaneTests {
    @Test("Segment tooltip content stays within the track width")
    func segmentTooltipContentStaysWithinTrackWidth() {
        #expect(PlayerBarProgressLane.segmentTooltipContentMaxWidth(trackWidth: 320) == 298)
        #expect(PlayerBarProgressLane.segmentTooltipContentMaxWidth(trackWidth: 22) == 0)
        #expect(PlayerBarProgressLane.segmentTooltipContentMaxWidth(trackWidth: 10) == 0)
    }

    @Test("Segment lookup uses half-open boundaries and preserves temporal gaps")
    func segmentLookupUsesHalfOpenBoundaries() {
        let segments = self.gappedSegments

        #expect(PlayerBarProgressLane.segment(at: 0, in: segments)?.id == "first")
        #expect(PlayerBarProgressLane.segment(at: 0.25, in: segments)?.id == "second")
        #expect(PlayerBarProgressLane.segment(at: 0.4, in: segments)?.id == "second")
        #expect(PlayerBarProgressLane.segment(at: 0.55, in: segments) == nil)
        #expect(PlayerBarProgressLane.segment(at: 0.75, in: segments)?.id == "third")
        #expect(PlayerBarProgressLane.segment(at: 0.9, in: segments) == nil)
        #expect(PlayerBarProgressLane.segment(at: 1, in: segments) == nil)
        #expect(PlayerBarProgressLane.segment(at: 0.5, in: []) == nil)
    }

    @Test("Played fraction clamps before within and after a segment")
    func playedFractionClampsToSegment() {
        let segment = self.gappedSegments[1]

        #expect(PlayerBarProgressLane.playedFraction(at: 0.2, within: segment) == 0)
        #expect(PlayerBarProgressLane.playedFraction(at: 0.25, within: segment) == 0)
        #expect(PlayerBarProgressLane.playedFraction(at: 0.375, within: segment) == 0.5)
        #expect(PlayerBarProgressLane.playedFraction(at: 0.5, within: segment) == 1)
        #expect(PlayerBarProgressLane.playedFraction(at: 0.8, within: segment) == 1)

        let reversed = PlayerBarProgressSegment(
            id: "reversed",
            start: 0.7,
            end: 0.6,
            index: 0,
            count: 1,
            title: "Reversed"
        )
        #expect(PlayerBarProgressLane.playedFraction(at: 0.65, within: reversed) == 0)
    }

    @Test("Segment geometry preserves outer edges and point gaps")
    func segmentGeometryPreservesPointGaps() {
        let segments = self.contiguousSegments
        let first = PlayerBarProgressLane.geometry(for: segments[0], trackWidth: 120, gap: 3)
        let middle = PlayerBarProgressLane.geometry(for: segments[1], trackWidth: 120, gap: 3)
        let last = PlayerBarProgressLane.geometry(for: segments[2], trackWidth: 120, gap: 3)

        #expect(first == PlayerBarProgressSegmentGeometry(x: 0, width: 38.5))
        #expect(middle == PlayerBarProgressSegmentGeometry(x: 41.5, width: 37))
        #expect(last.x == 81.5)
        #expect(abs(last.width - 38.5) < 0.0001)
        #expect(middle.x - (first.x + first.width) == 3)
        #expect(last.x - (middle.x + middle.width) == 3)
        #expect(abs(last.x + last.width - 120) < 0.0001)

        let invalid = PlayerBarProgressSegment(
            id: "invalid",
            start: 0.6,
            end: 0.5,
            index: 1,
            count: 3,
            title: "Invalid"
        )
        #expect(PlayerBarProgressLane.geometry(for: invalid, trackWidth: 120, gap: 3).width == 0)

        let tinyFinal = PlayerBarProgressSegment(
            id: "tiny-final",
            start: 0.999,
            end: 1,
            index: 2,
            count: 3,
            title: "Tiny final"
        )
        let tinyFinalGeometry = PlayerBarProgressLane.geometry(for: tinyFinal, trackWidth: 120, gap: 3)
        #expect(tinyFinalGeometry.width <= 0.1201)
        #expect(tinyFinalGeometry.x >= 119.88)
        #expect(tinyFinalGeometry.x + tinyFinalGeometry.width <= 120.0001)

        let narrowMiddle = PlayerBarProgressSegment(
            id: "narrow-middle",
            start: 0.5,
            end: 0.5 + 2.0 / 120,
            index: 1,
            count: 3,
            title: "Narrow middle"
        )
        let narrowMiddleGeometry = PlayerBarProgressLane.geometry(for: narrowMiddle, trackWidth: 120, gap: 3)
        #expect(abs(narrowMiddleGeometry.width - 1) < 0.0001)
        #expect(narrowMiddleGeometry.x >= 60)
        #expect(narrowMiddleGeometry.x + narrowMiddleGeometry.width <= 62.0001)
    }

    @Test("Current and hovered segments are independently prominent")
    func currentAndHoveredSegmentsAreProminent() {
        #expect(PlayerBarProgressLane.isProminent(
            segmentID: "current",
            currentSegmentID: "current",
            hoveredSegmentID: nil
        ))
        #expect(PlayerBarProgressLane.isProminent(
            segmentID: "hovered",
            currentSegmentID: "current",
            hoveredSegmentID: "hovered"
        ))
        #expect(!PlayerBarProgressLane.isProminent(
            segmentID: "completed",
            currentSegmentID: "current",
            hoveredSegmentID: "hovered"
        ))
    }

    @Test("Accessibility value announces only the current mix segment")
    func accessibilityValueAnnouncesCurrentSegment() {
        let segment = self.gappedSegments[1]
        let description = segment.accessibilityDescription
        #expect(description.contains("Track 2/3"))
        #expect(description.contains("Second"))
        #expect(description.contains("Artist B"))
        #expect(description.contains("1:00 – 2:00"))

        let segmentedValue = PlayerBarProgressLane.accessibilityValue(
            isLive: false,
            elapsedText: "1:30",
            remainingText: "-4:30",
            currentSegment: segment
        )
        #expect(segmentedValue.contains("1:30, -4:30"))
        #expect(segmentedValue.contains(description))

        #expect(PlayerBarProgressLane.accessibilityValue(
            isLive: false,
            elapsedText: "1:30",
            remainingText: "-4:30",
            currentSegment: nil
        ) == "1:30, -4:30")
        #expect(PlayerBarProgressLane.accessibilityValue(
            isLive: true,
            elapsedText: "1:30",
            remainingText: "-4:30",
            currentSegment: segment
        ) == String(localized: "Live stream"))
    }

    private var gappedSegments: [PlayerBarProgressSegment] {
        [
            PlayerBarProgressSegment(
                id: "first",
                start: 0,
                end: 0.25,
                index: 0,
                count: 3,
                title: "First",
                subtitle: "Artist A",
                rangeText: "0:00 – 1:00"
            ),
            PlayerBarProgressSegment(
                id: "second",
                start: 0.25,
                end: 0.5,
                index: 1,
                count: 3,
                title: "Second",
                subtitle: "Artist B",
                rangeText: "1:00 – 2:00"
            ),
            PlayerBarProgressSegment(
                id: "third",
                start: 0.6,
                end: 0.8,
                index: 2,
                count: 3,
                title: "Third",
                rangeText: "2:30 – 3:30"
            ),
        ]
    }

    private var contiguousSegments: [PlayerBarProgressSegment] {
        (0 ..< 3).map { index in
            PlayerBarProgressSegment(
                id: "segment-\(index)",
                start: Double(index) / 3,
                end: Double(index + 1) / 3,
                index: index,
                count: 3,
                title: "Segment \(index)"
            )
        }
    }
}
