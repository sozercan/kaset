import AppKit
import SwiftUI

// MARK: - HomeItemShelfSection

// A header plus a horizontal shelf of ``HomeSectionItem`` cards, backed by
// `NSCollectionView` with native, reusable cells.
//
// This replaces `CarouselShelfSection` + `HomeSectionItemCard` for the Home,
// Explore, Charts, New Releases and Moods pages. Measured on a paginated Home
// (19 shelves, 120 Hz): the SwiftUI shelf dropped 10–14 frames per scroll pass
// at ~55% app CPU; the collection-view shelf drops <1 at ~33%. Hosting the
// SwiftUI card inside collection-view cells kept almost none of that win, so
// the card is native: what scrolls is an `NSImageView`-style layer, two text
// fields and a badge, with SwiftUI used only for the glass play overlay of the
// single hovered cell and for the context menu.

struct HomeItemShelfSection<Header: View, MenuContent: View>: View {
    let accessibilityLabel: String
    let items: [HomeSectionItem]
    let isChart: Bool
    let contentInset: CGFloat
    /// Invoked on click (or Return) with the item and its index in `items`.
    let action: (HomeSectionItem, Int) -> Void
    /// Optional quick-play action for playlists, exposed as an accessibility action.
    let playlistPlayAction: (HomeSectionItem) -> (() -> Void)?
    let header: () -> Header
    let contextMenu: ((HomeSectionItem, Int) -> MenuContent)?

    @State private var overflow = CarouselShelfOverflow()
    @State private var pager = HomeItemShelfPager()

    init(
        accessibilityLabel: String,
        items: [HomeSectionItem],
        isChart: Bool = false,
        contentInset: CGFloat = 0,
        action: @escaping (HomeSectionItem, Int) -> Void,
        playlistPlayAction: @escaping (HomeSectionItem) -> (() -> Void)? = { _ in nil },
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder contextMenu: @escaping (HomeSectionItem, Int) -> MenuContent
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.items = items
        self.isChart = isChart
        self.contentInset = contentInset
        self.action = action
        self.playlistPlayAction = playlistPlayAction
        self.header = header
        self.contextMenu = contextMenu
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.header()
                // The header keeps the resting inset; the shelf below reaches
                // edge-to-edge and insets its own content so items scroll under
                // the floating glass sidebar.
                .padding(.horizontal, self.contentInset)

            HomeItemCollectionShelf(
                items: self.items,
                isChart: self.isChart,
                contentInset: self.contentInset,
                action: self.action,
                playlistPlayAction: self.playlistPlayAction,
                contextMenu: self.contextMenu.map { menu in { item, index in AnyView(menu(item, index)) } },
                overflow: self.$overflow,
                pager: self.pager
            )
            .frame(height: HomeItemCell.height)
            .modifier(CarouselShelfPagingControls(
                accessibilityLabel: self.accessibilityLabel,
                showsLeading: self.overflow.leading,
                showsTrailing: self.overflow.trailing,
                controlVerticalAlignment: .center,
                contentInset: self.contentInset,
                page: { self.pager.page($0) }
            ))
        }
    }
}

extension HomeItemShelfSection where MenuContent == EmptyView {
    init(
        accessibilityLabel: String,
        items: [HomeSectionItem],
        isChart: Bool = false,
        contentInset: CGFloat = 0,
        action: @escaping (HomeSectionItem, Int) -> Void,
        playlistPlayAction: @escaping (HomeSectionItem) -> (() -> Void)? = { _ in nil },
        @ViewBuilder header: @escaping () -> Header
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.items = items
        self.isChart = isChart
        self.contentInset = contentInset
        self.action = action
        self.playlistPlayAction = playlistPlayAction
        self.header = header
        self.contextMenu = nil
    }
}

// MARK: - HomeItemShelfPager

/// Lets the SwiftUI paging buttons drive the AppKit scroll view without
/// routing a command through SwiftUI state.
@MainActor
final class HomeItemShelfPager {
    weak var shelfView: HomeItemShelfView?

    func page(_ direction: CarouselShelfDirection) {
        self.shelfView?.page(direction)
    }
}

// MARK: - HomeItemCollectionShelf

/// Thin SwiftUI wrapper around ``HomeItemShelfView``.
struct HomeItemCollectionShelf: NSViewRepresentable {
    let items: [HomeSectionItem]
    let isChart: Bool
    let contentInset: CGFloat
    let action: (HomeSectionItem, Int) -> Void
    let playlistPlayAction: (HomeSectionItem) -> (() -> Void)?
    let contextMenu: ((HomeSectionItem, Int) -> AnyView)?
    @Binding var overflow: CarouselShelfOverflow
    let pager: HomeItemShelfPager

    /// Forwarded into the hosted play overlay and context menu so they see the
    /// same observable services as the rest of the page.
    @Environment(\.self) private var environment

    func makeCoordinator() -> HomeItemShelfView {
        HomeItemShelfView(contentInset: self.contentInset)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let shelf = context.coordinator
        self.configure(shelf)
        shelf.installObservers()
        return shelf.scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        self.configure(context.coordinator)
    }

    static func dismantleNSView(_: NSScrollView, coordinator: HomeItemShelfView) {
        coordinator.removeObservers()
    }

    private func configure(_ view: HomeItemShelfView) {
        view.onOverflowChange = { overflow in
            if overflow != self.overflow {
                self.overflow = overflow
            }
        }
        view.apply(HomeItemShelfView.Configuration(
            items: self.items,
            isChart: self.isChart,
            action: self.action,
            playlistPlayAction: self.playlistPlayAction,
            contextMenu: self.contextMenu,
            environment: self.environment
        ))
        self.pager.shelfView = view
    }
}

// MARK: - HomeItemShelfView

/// The AppKit shelf: a horizontal `NSScrollView` whose document view owns one
/// ``HomeItemCell`` per item for the shelf's lifetime. A shelf holds at most a
/// few dozen items, so nothing is recycled: `NSCollectionView` reuse rebuilt
/// and reconfigured every cell each time a shelf scrolled back onto the page,
/// and that rebuild was the single dropped frame per shelf that remained.
@MainActor
final class HomeItemShelfView: NSObject {
    struct Configuration {
        var items: [HomeSectionItem]
        var isChart: Bool
        var action: (HomeSectionItem, Int) -> Void
        var playlistPlayAction: (HomeSectionItem) -> (() -> Void)?
        var contextMenu: ((HomeSectionItem, Int) -> AnyView)?
        var environment: EnvironmentValues
    }

    static let itemSpacing: CGFloat = 16
    static let pageFraction: CGFloat = 0.85

    var onOverflowChange: ((CarouselShelfOverflow) -> Void)?

    let scrollView = NSScrollView()
    private let documentView = HomeItemShelfDocumentView()
    private let contentInset: CGFloat
    private var cells: [HomeItemCell] = []
    private var configuration = Configuration(
        items: [],
        isChart: false,
        action: { _, _ in },
        playlistPlayAction: { _ in nil },
        contextMenu: nil,
        environment: EnvironmentValues()
    )
    private var overflow = CarouselShelfOverflow()
    private var hoveredIndex: Int?
    private var observers: [NSObjectProtocol] = []

    init(contentInset: CGFloat) {
        self.contentInset = contentInset
        super.init()

        self.documentView.hoverHandler = { [weak self] point in
            self?.updateHover(at: point)
        }
        self.documentView.clickHandler = { [weak self] index, isLikeControl in
            if isLikeControl {
                self?.cells[index].toggleLike()
            } else {
                self?.activate(index)
            }
        }

        self.scrollView.documentView = self.documentView
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.hasVerticalScroller = false
        self.scrollView.horizontalScrollElasticity = .allowed
        self.scrollView.verticalScrollElasticity = .none
        // Vertical wheel/trackpad scrolling over a shelf must reach the page's
        // vertical scroll view: with predominant-axis scrolling the shelf only
        // consumes horizontal gestures.
        self.scrollView.usesPredominantAxisScrolling = true
        self.scrollView.drawsBackground = false
        self.scrollView.contentView.postsBoundsChangedNotifications = true
    }

    /// Scroll observers live only while the shelf is installed. SwiftUI
    /// removes and re-adds platform views as they cross the viewport, so this
    /// must survive multiple attach/detach cycles.
    func installObservers() {
        guard self.observers.isEmpty else { return }
        self.observers = [
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: self.scrollView.contentView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateOverflow()
                    self?.refreshHoverFromMouseLocation()
                }
            },
        ]
        self.updateOverflow()
        self.observeLikeStatus()
    }

    func removeObservers() {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.observers = []
        // Retire the like-status observation with the rest: bumping the tick
        // fires and disposes the armed registration, whose callback is inert
        // for the old generation. `installObservers()` re-arms it.
        self.likeObservationGeneration += 1
        self.observedSongIDs = []
        self.observationTick.value += 1
    }

    // MARK: Configuration

    func apply(_ configuration: Configuration) {
        // Card widths depend on item metadata, so a same-ID item that gains or
        // loses video mode is a layout change too.
        let layoutKey = { (items: [HomeSectionItem]) in items.map { "\($0.id)@\(HomeItemCell.width(for: $0))" } }
        let structureChanged = layoutKey(self.configuration.items) != layoutKey(configuration.items)
            || self.configuration.isChart != configuration.isChart
        self.configuration = configuration
        if structureChanged {
            self.rebuildCells()
        } else {
            // Same items: reconfigure in place so titles, explicit flags, like
            // availability and the menu's captured item track the model.
            // `configure` is a no-op when nothing relevant changed.
            self.configureCells()
        }
    }

    private func rebuildCells() {
        let items = self.configuration.items
        // Grow or shrink the pool; existing cells are reconfigured in place.
        while self.cells.count > items.count {
            self.cells.removeLast().removeFromSuperview()
        }
        while self.cells.count < items.count {
            let cell = HomeItemCell(frame: .zero)
            cell.likeAction = { [weak cell] in cell?.toggleLike() }
            self.documentView.addSubview(cell)
            self.cells.append(cell)
        }
        self.configureCells()
        var x = self.contentInset
        for (index, item) in items.enumerated() {
            let width = HomeItemCell.width(for: item)
            self.cells[index].frame = NSRect(x: x, y: 0, width: width, height: HomeItemCell.height)
            x += width + Self.itemSpacing
        }
        let contentWidth = items.isEmpty ? 0 : x - Self.itemSpacing + self.contentInset
        self.documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: HomeItemCell.height)
        self.documentView.cells = self.cells
        // Drop the previous hover explicitly (the cell may have been retained)
        // and re-resolve it from the pointer for the new layout.
        if let hovered = self.hoveredIndex, hovered < self.cells.count {
            self.cells[hovered].setHovered(false, animated: false)
        }
        self.hoveredIndex = nil
        self.updateOverflow()
        self.refreshHoverFromMouseLocation()
    }

    private func configureCells() {
        let environment = self.configuration.environment
        let allowsLikeActions = environment[AuthService.self]?.hasPersonalAccount == true
        for (index, item) in self.configuration.items.enumerated() where index < self.cells.count {
            let cell = self.cells[index]
            cell.activateAction = { [weak self] in self?.activate(index) }
            cell.configure(
                item: item,
                rank: self.configuration.isChart ? index + 1 : nil,
                allowsLikeActions: allowsLikeActions,
                playlistPlayAction: self.configuration.playlistPlayAction(item),
                environment: environment
            )
            cell.menuProvider = { [weak self] in
                guard let self, let contextMenu = self.configuration.contextMenu else { return nil }
                return NSHostingMenu(rootView: contextMenu(item, index).environment(\.self, self.configuration.environment))
            }
        }
        // A new song set arms a fresh observation; an unchanged set re-pushes
        // the last known state, since `configure` may have reset a card.
        self.observeLikeStatus()
        self.pushLikedState()
    }

    // MARK: Like status

    private var likeObservationGeneration = 0
    private var observedSongIDs: [String] = []
    private let observationTick = ObservationTick()

    /// One armed observation per shelf: reads every song's liked state under
    /// tracking, pushes it to the cards, and re-arms from its own callback.
    /// Routine representable updates must not add registrations, so a new
    /// observation is only started when the observed song set changes.
    private func observeLikeStatus(force: Bool = false) {
        let songs: [(Int, Song)] = self.configuration.items.enumerated().compactMap { index, item in
            if case let .song(song) = item {
                return (index, song)
            }
            return nil
        }
        // Identity includes the position: non-song cards moving around the
        // same songs still changes which card each liked state belongs to.
        let songIDs = songs.map { "\($0.0):\($0.1.id)" }
        guard force || songIDs != self.observedSongIDs else { return }
        self.observedSongIDs = songIDs
        self.likeObservationGeneration += 1
        let generation = self.likeObservationGeneration
        // Bumping the tick fires (and so disposes) the previous one-shot
        // registration, whose callback is inert for the old generation.
        self.observationTick.value += 1
        let manager = SongLikeStatusManager.shared
        guard !songs.isEmpty else { return }
        let liked = withObservationTracking {
            _ = self.observationTick.value
            return songs.map { manager.isLiked($0.1) }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.likeObservationGeneration == generation else { return }
                self.observeLikeStatus(force: true)
            }
        }
        self.lastLikedBySongID = Dictionary(zip(songs.map(\.1.id), liked), uniquingKeysWith: { _, last in last })
        self.pushLikedState()
    }

    private var lastLikedBySongID: [String: Bool] = [:]

    private func pushLikedState() {
        for (index, item) in self.configuration.items.enumerated() where index < self.cells.count {
            guard case let .song(song) = item else { continue }
            self.cells[index].setLiked(self.lastLikedBySongID[song.id] ?? false)
        }
    }

    private func activate(_ index: Int) {
        guard index < self.configuration.items.count else { return }
        self.configuration.action(self.configuration.items[index], index)
    }

    // MARK: Hover

    /// Resolves which cell (if any) is under `point` in document coordinates
    /// and moves the hover state there. Driven by mouse moves and by
    /// scroll-bounds changes, so cells that slide out from under a stationary
    /// pointer (paging, momentum) drop their hover.
    private func updateHover(at point: NSPoint?) {
        let next = point.flatMap { self.documentView.cellIndex(at: $0) }
        guard next != self.hoveredIndex else { return }
        if let previous = self.hoveredIndex, previous < self.cells.count {
            self.cells[previous].setHovered(false, animated: true)
        }
        self.hoveredIndex = next
        if let next, next < self.cells.count {
            self.cells[next].setHovered(true, animated: true)
        }
    }

    private func refreshHoverFromMouseLocation() {
        guard let window = self.scrollView.window else { return }
        let point = self.documentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        self.updateHover(at: self.documentView.visibleRect.contains(point) ? point : nil)
    }

    // MARK: Overflow + paging

    private func updateOverflow() {
        let visible = self.scrollView.contentView.bounds
        let contentWidth = self.documentView.frame.width
        let next = CarouselShelfOverflow(
            leading: visible.minX > 1,
            trailing: contentWidth - visible.maxX > 1
        )
        guard next != self.overflow else { return }
        self.overflow = next
        // The first report happens while SwiftUI is still building the
        // representable; a state write at that point is discarded, so deliver
        // on the next turn.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onOverflowChange?(self.overflow)
        }
    }

    func page(_ direction: CarouselShelfDirection) {
        let clipView = self.scrollView.contentView
        let visible = clipView.bounds
        let contentWidth = self.documentView.frame.width
        let pageWidth = max(1, visible.width * Self.pageFraction)
        let destination = switch direction {
        case .leading: visible.minX - pageWidth
        case .trailing: visible.minX + pageWidth
        }
        let maxX = max(0, contentWidth - visible.width)
        let target = NSPoint(x: min(max(destination, 0), maxX), y: visible.minY)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clipView.animator().setBoundsOrigin(target)
            self.scrollView.reflectScrolledClipView(clipView)
        }
    }
}

// MARK: - ObservationTick

/// An observable counter read inside a tracked closure so that bumping it
/// fires — and thereby disposes — an otherwise one-shot observation.
@MainActor
@Observable
private final class ObservationTick {
    var value = 0
}

// MARK: - HomeItemShelfDocumentView

/// Flipped document view holding the shelf's cell views; owns the single
/// tracking area used for hover and turns clicks into item activations.
@MainActor
private final class HomeItemShelfDocumentView: NSView {
    var hoverHandler: ((NSPoint?) -> Void)?
    /// `(index, isLikeControl)`.
    var clickHandler: ((Int, Bool) -> Void)?
    var cells: [HomeItemCell] = []
    private var trackingArea: NSTrackingArea?

    private enum PressTarget: Equatable {
        case card(Int)
        case likeControl(Int)
    }

    private var pressTarget: PressTarget?

    override var isFlipped: Bool {
        true
    }

    func cellIndex(at point: NSPoint) -> Int? {
        self.cells.firstIndex { $0.frame.contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        self.hoverHandler?(self.convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        self.hoverHandler?(self.convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with _: NSEvent) {
        self.hoverHandler?(nil)
    }

    /// Vertically dominant wheel events belong to the page's vertical scroll
    /// view; the shelf only consumes horizontal gestures.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
           let outer = self.enclosingScrollView?.enclosingScrollView
        {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// What is under `point`: the card, its like control, or nothing.
    private func target(at point: NSPoint) -> PressTarget? {
        guard let index = self.cellIndex(at: point) else { return nil }
        let cell = self.cells[index]
        if let likeFrame = cell.likeButtonFrame, likeFrame.contains(self.convert(point, to: cell)) {
            return .likeControl(index)
        }
        return .card(index)
    }

    override func mouseDown(with event: NSEvent) {
        self.pressTarget = self.target(at: self.convert(event.locationInWindow, from: nil))
    }

    /// A press only dispatches if it is released on the same target it began
    /// on, so dragging off the like control (or onto it) cancels.
    override func mouseUp(with event: NSEvent) {
        defer { self.pressTarget = nil }
        let point = self.convert(event.locationInWindow, from: nil)
        guard event.clickCount == 1, let pressed = self.pressTarget, self.target(at: point) == pressed else { return }
        switch pressed {
        case let .card(index): self.clickHandler?(index, false)
        case let .likeControl(index): self.clickHandler?(index, true)
        }
    }
}
