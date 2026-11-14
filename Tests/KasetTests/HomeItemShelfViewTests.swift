import AppKit
import SwiftUI
import Testing
@testable import Kaset

// MARK: - HomeItemShelfViewTests

@Suite(.tags(.model))
@MainActor
struct HomeItemShelfViewTests {
    @Test("Same-ID rating metadata refreshes the glyph and accessibility action")
    func refreshesRatingMetadata() throws {
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.completeLogin(sapisid: "mock-token")
        let id = UUID().uuidString
        var song = Song(id: id, title: "Track", artists: [], videoId: id, likeStatus: .indifferent)
        let shelf = HomeItemShelfView(contentInset: 20)
        defer { shelf.removeObservers() }
        shelf.apply(Self.configuration(items: [.song(song)], authService: authService))
        let cell = try #require(Self.cells(in: shelf).first)
        #expect(cell.likeButtonFrame == nil)

        song.likeStatus = .like
        shelf.apply(Self.configuration(items: [.song(song)], authService: authService))
        #expect(Self.cells(in: shelf).first === cell)
        #expect(cell.likeButtonFrame != nil)
        #expect(cell.accessibilityCustomActions()?.first?.name == String(localized: "Unlike"))

        song.likeStatus = .indifferent
        shelf.apply(Self.configuration(items: [.song(song)], authService: authService))
        #expect(cell.likeButtonFrame == nil)
        #expect(cell.accessibilityCustomActions()?.first?.name == String(localized: "Like"))
    }

    @Test("RTL shelves start at their leading edge with items in reading order")
    func rightToLeftInitialLayout() throws {
        let shelf = Self.shelf(width: 320, layoutDirection: .rightToLeft)
        defer { shelf.removeObservers() }
        let cells = Self.cells(in: shelf)
        let first = try #require(cells.first)
        let last = try #require(cells.last)
        let visible = shelf.scrollView.contentView.bounds

        #expect(first.frame.minX > last.frame.minX)
        #expect(first.frame.maxX == visible.maxX - 20)
        #expect(last.frame.minX == 20)
        #expect(visible.minX > 0)
    }

    @Test("RTL shelves stay at the leading edge when the viewport arrives or resizes")
    func rightToLeftViewportChanges() throws {
        let shelf = Self.shelf(width: 0, layoutDirection: .rightToLeft)
        defer { shelf.removeObservers() }
        let first = try #require(Self.cells(in: shelf).first)

        for width: CGFloat in [320, 480, 280] {
            Self.resize(shelf, to: width)
            #expect(first.frame.maxX == shelf.scrollView.contentView.bounds.maxX - 20)
        }
    }

    @Test("A short RTL shelf aligns its first card to the right inset")
    func rightToLeftShortShelf() throws {
        let shelf = Self.shelf(width: 640, layoutDirection: .rightToLeft, items: Self.items(count: 2))
        defer { shelf.removeObservers() }
        let first = try #require(Self.cells(in: shelf).first)
        #expect(first.frame.maxX == 620)
        #expect(shelf.scrollView.contentView.bounds.minX == 0)

        Self.resize(shelf, to: 720)
        #expect(first.frame.maxX == 700)
    }

    @Test("Arrows wait for the shelf's width instead of flashing on short shelves", arguments: [6, 2])
    func arrowsWaitForWidth(itemCount: Int) {
        let shelf = Self.shelf(width: 0, layoutDirection: .leftToRight, items: Self.items(count: itemCount))
        defer { shelf.removeObservers() }
        let right = shelf.containerView.arrow(.right)
        #expect(!right.isVisible && right.isHidden)

        Self.resize(shelf, to: 640)
        if itemCount > 2 {
            // The first sized report shows the arrow without animating.
            #expect(right.isVisible && !right.isHidden)
            #expect(abs(right.alphaValue - 0.72) < 0.01)
        } else {
            #expect(!right.isVisible && right.isHidden && right.alphaValue == 0)
        }
        #expect(!shelf.containerView.isShowingArrow(.left))
    }

    @Test("Paging follows reading direction and preserves its position through resize", arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func pagingAndResize(layoutDirection: LayoutDirection) throws {
        let shelf = Self.shelf(width: 320, layoutDirection: layoutDirection)
        defer { shelf.removeObservers() }
        let first = try #require(Self.cells(in: shelf).first)

        let trailingX = shelf.scrollView.contentView.bounds.minX + (layoutDirection == .rightToLeft ? -272 : 272)
        shelf.page(.trailing)
        #expect(shelf.scrollView.contentView.bounds.minX == trailingX)
        let offset = layoutDirection == .rightToLeft
            ? first.frame.maxX + 20 - shelf.scrollView.contentView.bounds.maxX
            : shelf.scrollView.contentView.bounds.minX
        #expect(offset == 272)
        #expect(shelf.containerView.isShowingArrow(.left) && shelf.containerView.isShowingArrow(.right))

        Self.resize(shelf, to: 400)
        let resizedOffset = layoutDirection == .rightToLeft
            ? first.frame.maxX + 20 - shelf.scrollView.contentView.bounds.maxX
            : shelf.scrollView.contentView.bounds.minX
        #expect(resizedOffset == 272)

        let leadingX = layoutDirection == .rightToLeft ? first.frame.maxX + 20 - shelf.scrollView.contentView.bounds.width : 0
        shelf.page(.leading)
        #expect(shelf.scrollView.contentView.bounds.minX == leadingX)
        if layoutDirection == .rightToLeft {
            #expect(first.frame.maxX == shelf.scrollView.contentView.bounds.maxX - 20)
        } else {
            #expect(shelf.scrollView.contentView.bounds.minX == 0)
        }
        // Arrows are physical: the trailing arrow sits on the left in right-to-left layouts.
        let trailingSide: HomeItemShelfContainerView.Side = layoutDirection == .rightToLeft ? .left : .right
        let leadingSide: HomeItemShelfContainerView.Side = layoutDirection == .rightToLeft ? .right : .left
        #expect(shelf.containerView.isShowingArrow(trailingSide))
        #expect(!shelf.containerView.isShowingArrow(leadingSide))
    }

    @Test("Physical arrows page in the matching visual direction", arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func arrowsPagePhysically(layoutDirection: LayoutDirection) {
        let shelf = Self.shelf(width: 320, layoutDirection: layoutDirection)
        defer { shelf.removeObservers() }
        // The trailing arrow is the right one in LTR and the left one in RTL;
        // either way pressing it moves the content toward the trailing edge.
        let isRightToLeft = layoutDirection == .rightToLeft
        let start = shelf.scrollView.contentView.bounds.minX
        #expect(shelf.containerView.arrow(isRightToLeft ? .left : .right).accessibilityPerformPress())
        let end = shelf.scrollView.contentView.bounds.minX
        #expect(isRightToLeft ? end < start : end > start)
        // Leaving the leading edge reveals the leading arrow.
        #expect(shelf.containerView.isShowingArrow(isRightToLeft ? .right : .left))
    }

    @Test("Only a showing arrow's circle takes clicks and presses")
    func arrowHitTesting() {
        let shelf = Self.shelf(width: 320, layoutDirection: .leftToRight)
        defer { shelf.removeObservers() }
        var pressed: [HomeItemShelfContainerView.Side] = []
        shelf.containerView.pageHandler = { pressed.append($0) }
        let right = shelf.containerView.arrow(.right)
        let center = NSPoint(x: right.frame.midX, y: right.frame.midY)
        #expect(right.hitTest(center) === right)
        #expect(right.hitTest(NSPoint(x: right.frame.minX + 2, y: right.frame.minY + 2)) == nil)

        // Reaching the end starts the arrow's fade-out; it must stop
        // intercepting the card beneath right away.
        shelf.containerView.setArrows(left: true, right: false, animated: true)
        #expect(right.hitTest(center) == nil)
        #expect(!right.accessibilityPerformPress())
        #expect(pressed.isEmpty)
    }

    @Test("Arrows are labeled buttons without an unlabeled image inside")
    func arrowAccessibility() {
        let shelf = Self.shelf(width: 320, layoutDirection: .leftToRight)
        defer { shelf.removeObservers() }
        var configuration = Self.configuration(items: Self.items())
        configuration.accessibilityLabel = "Quick picks"
        shelf.apply(configuration)
        let right = shelf.containerView.arrow(.right)
        #expect(right.accessibilityRole() == .button)
        #expect(right.accessibilityLabel() == String(localized: "Scroll Quick picks right"))
        #expect(right.accessibilityChildren()?.isEmpty ?? true)
    }

    @Test("Changing layout direction repositions retained cards and resets to the leading edge")
    func layoutDirectionChanges() throws {
        let items = Self.items()
        let shelf = Self.shelf(width: 320, layoutDirection: .leftToRight, items: items)
        defer { shelf.removeObservers() }
        let first = try #require(Self.cells(in: shelf).first)

        shelf.apply(Self.configuration(items: items, layoutDirection: .rightToLeft))
        #expect(Self.cells(in: shelf).first === first)
        #expect(first.frame.maxX == shelf.scrollView.contentView.bounds.maxX - 20)
        #expect(shelf.scrollView.contentView.bounds.minX > 0)

        shelf.apply(Self.configuration(items: items, layoutDirection: .leftToRight))
        #expect(first.frame.minX == 20)
        #expect(shelf.scrollView.contentView.bounds.minX == 0)
    }

    @Test("A scroll gesture keeps its destination through diagonal movement and momentum", arguments: [true, false])
    func scrollGestureDestination(startsVertically: Bool) throws {
        let shelf = Self.shelf(width: 320, layoutDirection: .leftToRight)
        defer { shelf.removeObservers() }
        let outer = Self.page(containing: shelf)
        let events = try [
            Self.scrollEvent(phase: .mayBegin),
            Self.scrollEvent(phase: .began),
            Self.scrollEvent(x: startsVertically ? 0 : 12, y: startsVertically ? 12 : 0, phase: .changed),
            Self.scrollEvent(x: startsVertically ? 8 : 1, y: startsVertically ? 1 : 8, phase: .changed),
            Self.scrollEvent(phase: .ended),
            Self.scrollEvent(x: startsVertically ? 4 : 1, y: startsVertically ? 1 : 4, momentum: .begin),
            Self.scrollEvent(momentum: .end),
        ]
        for event in events {
            shelf.scrollView.documentView?.scrollWheel(with: event)
        }
        #expect(outer.scrollEvents == (startsVertically ? events : []))
    }

    @Test("Cancellation, empty gestures, and wheel events do not retain a previous scroll destination")
    func scrollGestureDestinationResets() throws {
        let shelf = Self.shelf(width: 320, layoutDirection: .leftToRight)
        defer { shelf.removeObservers() }
        let outer = Self.page(containing: shelf)
        let vertical = try [
            Self.scrollEvent(y: 12, phase: .began),
            Self.scrollEvent(phase: .cancelled),
        ]
        for event in vertical {
            shelf.scrollView.documentView?.scrollWheel(with: event)
        }
        #expect(outer.scrollEvents == vertical)
        outer.scrollEvents = []

        let emptyAndHorizontal = try [
            Self.scrollEvent(phase: .mayBegin),
            Self.scrollEvent(phase: .began),
            Self.scrollEvent(phase: .ended),
            Self.scrollEvent(x: 12, phase: .began),
            Self.scrollEvent(phase: .ended),
        ]
        for event in emptyAndHorizontal {
            shelf.scrollView.documentView?.scrollWheel(with: event)
        }
        #expect(outer.scrollEvents.isEmpty)

        let wheel = try Self.scrollEvent(y: 12)
        shelf.scrollView.documentView?.scrollWheel(with: wheel)
        try shelf.scrollView.documentView?.scrollWheel(with: Self.scrollEvent(x: 12))
        #expect(outer.scrollEvents == [wheel])
    }

    @Test("Scroll gestures that start on an arrow route like the shelf's own")
    func arrowScrollRouting() throws {
        let shelf = Self.shelf(width: 320, layoutDirection: .leftToRight)
        defer { shelf.removeObservers() }
        let outer = Self.page(containing: shelf)
        let arrow = shelf.containerView.arrow(.right)
        let vertical = try [
            Self.scrollEvent(y: 12, phase: .began),
            Self.scrollEvent(phase: .ended),
        ]
        for event in vertical {
            arrow.scrollWheel(with: event)
        }
        #expect(outer.scrollEvents == vertical)
        outer.scrollEvents = []

        try arrow.scrollWheel(with: Self.scrollEvent(x: 12))
        #expect(outer.scrollEvents.isEmpty)
    }

    /// Places the shelf's container (scroll view and arrows) on a page inside
    /// an outer scroll view, like the Home page's vertical `ScrollView`.
    private static func page(containing shelf: HomeItemShelfView) -> HomeItemTestScrollView {
        let outer = HomeItemTestScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1200))
        page.addSubview(shelf.containerView)
        outer.documentView = page
        return outer
    }

    private static func scrollEvent(
        x: Int32 = 0,
        y: Int32 = 0,
        phase: CGScrollPhase? = nil,
        momentum: CGMomentumScrollPhase? = nil
    ) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum?.rawValue ?? 0))
        return try #require(NSEvent(cgEvent: event))
    }

    private static func items(count: Int = 6) -> [HomeSectionItem] {
        (0 ..< count).map { index in
            .song(Song(id: "shelf-\(index)", title: "Track \(index)", artists: [], videoId: "shelf-\(index)"))
        }
    }

    private static func configuration(
        items: [HomeSectionItem],
        layoutDirection: LayoutDirection = .leftToRight,
        authService: AuthService? = nil
    ) -> HomeItemShelfView.Configuration {
        var environment = EnvironmentValues()
        environment.layoutDirection = layoutDirection
        environment[AuthService.self] = authService
        return HomeItemShelfView.Configuration(
            items: items,
            isChart: false,
            action: { _, _ in },
            playlistPlayAction: { _ in nil },
            contextMenu: nil,
            environment: environment
        )
    }

    private static func shelf(
        width: CGFloat,
        layoutDirection: LayoutDirection,
        items: [HomeSectionItem] = Self.items()
    ) -> HomeItemShelfView {
        let shelf = HomeItemShelfView(contentInset: 20)
        let originalClipView = shelf.scrollView.contentView
        let clipView = HomeItemTestClipView(frame: .zero)
        clipView.postsBoundsChangedNotifications = originalClipView.postsBoundsChangedNotifications
        clipView.postsFrameChangedNotifications = originalClipView.postsFrameChangedNotifications
        let documentView = shelf.scrollView.documentView
        shelf.scrollView.contentView = clipView
        shelf.scrollView.documentView = documentView
        Self.resize(shelf, to: width)
        shelf.apply(Self.configuration(items: items, layoutDirection: layoutDirection))
        shelf.installObservers()
        return shelf
    }

    private static func cells(in shelf: HomeItemShelfView) -> [HomeItemCell] {
        shelf.scrollView.documentView?.subviews.compactMap { $0 as? HomeItemCell } ?? []
    }

    /// Sizes the container as SwiftUI would; its layout sizes the scroll view
    /// and places the arrows.
    private static func resize(_ shelf: HomeItemShelfView, to width: CGFloat) {
        shelf.containerView.frame = NSRect(x: 0, y: 0, width: width, height: HomeItemCell.height)
        shelf.containerView.needsLayout = true
        shelf.containerView.layoutSubtreeIfNeeded()
    }
}

// MARK: - HomeItemTestClipView

@MainActor
private final class HomeItemTestClipView: NSClipView {
    /// Apply paging destinations without requiring an onscreen animation clock.
    override func animator() -> Self {
        self
    }
}

// MARK: - HomeItemTestScrollView

@MainActor
private final class HomeItemTestScrollView: NSScrollView {
    var scrollEvents: [NSEvent] = []

    override func scrollWheel(with event: NSEvent) {
        self.scrollEvents.append(event)
    }
}
