import AppKit
import Testing
@testable import Kaset

/// Tests for the trackpad swipe-back recognizer.
struct NavigationSwipeTrackerTests {
    private let distance = NavigationSwipeTracker.completionDistance

    @Test("A rightward swipe past the completion distance goes back")
    func rightwardSwipeCompletes() {
        var tracker = NavigationSwipeTracker()

        #expect(tracker.handle(.began, dx: 4, dy: 0, canGoBack: true) == .passThrough)
        #expect(tracker.handle(.changed, dx: 10, dy: 1, canGoBack: true) == .tracking(progress: 14 / self.distance))
        #expect(tracker.handle(.changed, dx: self.distance, dy: 0, canGoBack: true) == .tracking(progress: 1))
        #expect(tracker.isTracking)
        #expect(tracker.handle(.ended, dx: 0, dy: 0, canGoBack: true) == .completed)
        #expect(!tracker.isTracking)
    }

    @Test("A swipe that falls short, or turns back, is cancelled")
    func shortSwipeCancels() {
        var tracker = NavigationSwipeTracker()
        _ = tracker.handle(.began, dx: 0, dy: 0, canGoBack: true)
        _ = tracker.handle(.changed, dx: 60, dy: 0, canGoBack: true)
        #expect(tracker.handle(.ended, dx: 0, dy: 0, canGoBack: true) == .cancelled)

        _ = tracker.handle(.began, dx: 0, dy: 0, canGoBack: true)
        _ = tracker.handle(.changed, dx: self.distance + 20, dy: 0, canGoBack: true)
        // Moving back past the start clamps at zero instead of going negative.
        #expect(tracker.handle(.changed, dx: -400, dy: 0, canGoBack: true) == .tracking(progress: 0))
        #expect(tracker.handle(.ended, dx: 0, dy: 0, canGoBack: true) == .cancelled)
    }

    @Test("Vertical, diagonal, and leftward scrolls stay scrolls for the whole gesture")
    func otherDirectionsPassThrough() {
        for (dx, dy) in [(CGFloat(0), CGFloat(20)), (15, 12), (-20, 0)] {
            var tracker = NavigationSwipeTracker()
            #expect(tracker.handle(.began, dx: dx, dy: dy, canGoBack: true) == .passThrough)
            #expect(!tracker.isDeciding)
            // Once rejected, later rightward motion in the same gesture is not taken.
            #expect(tracker.handle(.changed, dx: 200, dy: 0, canGoBack: true) == .passThrough)
            #expect(tracker.handle(.ended, dx: 0, dy: 0, canGoBack: true) == .passThrough)
        }
    }

    @Test("Nothing is taken without a page to go back to")
    func cannotGoBackPassesThrough() {
        var tracker = NavigationSwipeTracker()
        #expect(tracker.handle(.began, dx: 30, dy: 0, canGoBack: false) == .passThrough)
        #expect(tracker.handle(.changed, dx: 200, dy: 0, canGoBack: true) == .passThrough)
        #expect(tracker.handle(.ended, dx: 0, dy: 0, canGoBack: true) == .passThrough)
    }

    @Test("Small motion waits for the direction before deciding")
    func slopDefersDecision() {
        var tracker = NavigationSwipeTracker()
        #expect(tracker.handle(.began, dx: 2, dy: 1, canGoBack: true) == .passThrough)
        #expect(tracker.handle(.changed, dx: 2, dy: 1, canGoBack: true) == .passThrough)
        #expect(tracker.isDeciding)
        #expect(!tracker.isTracking)
        #expect(tracker.handle(.changed, dx: 6, dy: 0, canGoBack: true) == .tracking(progress: 10 / self.distance))
    }

    @Test("Updates without a beginning, and cancelled gestures, are handled")
    func strayAndCancelledGestures() {
        var tracker = NavigationSwipeTracker()
        #expect(tracker.handle(.changed, dx: 200, dy: 0, canGoBack: true) == .passThrough)
        #expect(tracker.handle(.ended, dx: 0, dy: 0, canGoBack: true) == .passThrough)

        _ = tracker.handle(.began, dx: 0, dy: 0, canGoBack: true)
        _ = tracker.handle(.changed, dx: 50, dy: 0, canGoBack: true)
        #expect(tracker.handle(.cancelled, dx: 0, dy: 0, canGoBack: true) == .cancelled)
        #expect(tracker.handle(.cancelled, dx: 0, dy: 0, canGoBack: true) == .passThrough)
    }

    @Test("A shelf inset under the sidebar keeps the swipe until it reaches that edge")
    func shelfScrollRoom() {
        // Measured from an artist page's albums shelf: the clip view is inset
        // 200 pt for the sidebar, at its leading edge, with 99 pt left to scroll.
        let insets = NSEdgeInsets(top: 0, left: 200, bottom: 0, right: 0)
        let document = CGRect(x: 0, y: 0, width: 1592, height: 185)
        let atLeadingEdge = CGRect(x: -200, y: 0, width: 1693, height: 185)

        #expect(!NavigationSwipeTracker.hasHorizontalScrollRoom(
            visible: atLeadingEdge, document: document, clipInsets: insets, towardLeadingEdge: true
        ))
        #expect(NavigationSwipeTracker.hasHorizontalScrollRoom(
            visible: atLeadingEdge, document: document, clipInsets: insets, towardLeadingEdge: false
        ))

        let atTrailingEdge = CGRect(x: -101, y: 0, width: 1693, height: 185)
        #expect(NavigationSwipeTracker.hasHorizontalScrollRoom(
            visible: atTrailingEdge, document: document, clipInsets: insets, towardLeadingEdge: true
        ))
        #expect(!NavigationSwipeTracker.hasHorizontalScrollRoom(
            visible: atTrailingEdge, document: document, clipInsets: insets, towardLeadingEdge: false
        ))
    }

    @Test("A vertical page never claims horizontal scroll room")
    func verticalPageHasNoScrollRoom() {
        // The page's own scroll view: insets on the scroll view, none on the clip view.
        let visible = CGRect(x: 0, y: -52, width: 1693, height: 1074)
        let document = CGRect(x: 0, y: 0, width: 1693, height: 1831)
        for towardLeadingEdge in [true, false] {
            #expect(!NavigationSwipeTracker.hasHorizontalScrollRoom(
                visible: visible,
                document: document,
                clipInsets: NSEdgeInsets(top: 52, left: 0, bottom: 60, right: 0),
                towardLeadingEdge: towardLeadingEdge
            ))
        }
    }
}
