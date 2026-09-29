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
            shelf.scrollView.setFrameSize(NSSize(width: width, height: HomeItemCell.height))
            shelf.scrollView.layoutSubtreeIfNeeded()
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

        shelf.scrollView.setFrameSize(NSSize(width: 720, height: HomeItemCell.height))
        shelf.scrollView.layoutSubtreeIfNeeded()
        #expect(first.frame.maxX == 700)
    }

    @Test("Paging follows reading direction and preserves its position through resize", arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func pagingAndResize(layoutDirection: LayoutDirection) async throws {
        let shelf = Self.shelf(width: 320, layoutDirection: layoutDirection)
        defer { shelf.removeObservers() }
        let first = try #require(Self.cells(in: shelf).first)
        var overflow = CarouselShelfOverflow()
        shelf.onOverflowChange = { overflow = $0 }

        let trailingX = shelf.scrollView.contentView.bounds.minX + (layoutDirection == .rightToLeft ? -272 : 272)
        try await Self.page(.trailing, in: shelf) {
            shelf.scrollView.contentView.bounds.minX == trailingX
                && overflow == CarouselShelfOverflow(leading: true, trailing: true)
        }
        let offset = layoutDirection == .rightToLeft
            ? first.frame.maxX + 20 - shelf.scrollView.contentView.bounds.maxX
            : shelf.scrollView.contentView.bounds.minX
        #expect(offset == 272)
        #expect(overflow == CarouselShelfOverflow(leading: true, trailing: true))

        shelf.scrollView.setFrameSize(NSSize(width: 400, height: HomeItemCell.height))
        shelf.scrollView.layoutSubtreeIfNeeded()
        let resizedOffset = layoutDirection == .rightToLeft
            ? first.frame.maxX + 20 - shelf.scrollView.contentView.bounds.maxX
            : shelf.scrollView.contentView.bounds.minX
        #expect(resizedOffset == 272)

        let leadingX = layoutDirection == .rightToLeft ? first.frame.maxX + 20 - shelf.scrollView.contentView.bounds.width : 0
        try await Self.page(.leading, in: shelf) {
            shelf.scrollView.contentView.bounds.minX == leadingX
                && overflow == CarouselShelfOverflow(leading: false, trailing: true)
        }
        if layoutDirection == .rightToLeft {
            #expect(first.frame.maxX == shelf.scrollView.contentView.bounds.maxX - 20)
        } else {
            #expect(shelf.scrollView.contentView.bounds.minX == 0)
        }
        #expect(overflow == CarouselShelfOverflow(leading: false, trailing: true))
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

    private static func page(containing shelf: HomeItemShelfView) -> HomeItemTestScrollView {
        let outer = HomeItemTestScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1200))
        page.addSubview(shelf.scrollView)
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
            quickPlayAction: { _ in nil },
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
        shelf.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: HomeItemCell.height)
        shelf.apply(Self.configuration(items: items, layoutDirection: layoutDirection))
        shelf.installObservers()
        return shelf
    }

    private static func cells(in shelf: HomeItemShelfView) -> [HomeItemCell] {
        shelf.scrollView.documentView?.subviews.compactMap { $0 as? HomeItemCell } ?? []
    }

    private static func page(_ direction: CarouselShelfDirection, in shelf: HomeItemShelfView, until isSettled: () -> Bool) async throws {
        shelf.page(direction)
        // Overflow is delivered asynchronously even with immediate scrolling.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !isSettled(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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
