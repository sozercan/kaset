import AppKit
import SwiftUI

// MARK: - HomeItemShelfSection

// A header plus a horizontal shelf of ``HomeSectionItem`` cards for the Home,
// Explore, Charts, New Releases and Moods pages. Only the header is SwiftUI: the
// shelf is a plain `NSScrollView` of single-view native cards, with native glass
// paging arrows. See ADR-0038 for the measurements behind each piece.

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
                accessibilityLabel: self.accessibilityLabel
            )
            .frame(height: HomeItemCell.height)
            // The paging arrows are native (see `HomeItemShelfContainerView`);
            // only the shelf's accessibility container stays in SwiftUI.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(self.accessibilityLabel)
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

// MARK: - HomeItemCollectionShelf

/// Thin SwiftUI wrapper around ``HomeItemShelfView``.
struct HomeItemCollectionShelf: NSViewRepresentable {
    let items: [HomeSectionItem]
    let isChart: Bool
    let contentInset: CGFloat
    let action: (HomeSectionItem, Int) -> Void
    let playlistPlayAction: (HomeSectionItem) -> (() -> Void)?
    let contextMenu: ((HomeSectionItem, Int) -> AnyView)?
    let accessibilityLabel: String

    /// Forwarded into the hosted play overlay and context menu so they see the
    /// same observable services as the rest of the page.
    @Environment(\.self) private var environment

    func makeCoordinator() -> HomeItemShelfView {
        HomeItemShelfView(contentInset: self.contentInset)
    }

    func makeNSView(context: Context) -> HomeItemShelfContainerView {
        let shelf = context.coordinator
        self.configure(shelf)
        shelf.installObservers()
        return shelf.containerView
    }

    func updateNSView(_: HomeItemShelfContainerView, context: Context) {
        self.configure(context.coordinator)
    }

    /// The shelf's size is fixed by its container. Without this, SwiftUI sizes the
    /// platform view through Auto Layout (`intrinsicLayoutTraits` and a window
    /// constraint pass) every time a shelf is realized mid-scroll.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: HomeItemShelfContainerView, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: HomeItemCell.height)
    }

    static func dismantleNSView(_: HomeItemShelfContainerView, coordinator: HomeItemShelfView) {
        coordinator.removeObservers()
    }

    private func configure(_ view: HomeItemShelfView) {
        view.apply(HomeItemShelfView.Configuration(
            items: self.items,
            isChart: self.isChart,
            action: self.action,
            playlistPlayAction: self.playlistPlayAction,
            contextMenu: self.contextMenu,
            accessibilityLabel: self.accessibilityLabel,
            environment: self.environment
        ))
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
        var accessibilityLabel = ""
        var environment: EnvironmentValues
    }

    static let itemSpacing: CGFloat = 16
    static let pageFraction: CGFloat = 0.85

    let scrollView = NSScrollView()
    let containerView = HomeItemShelfContainerView()
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
    /// Which logical directions can still scroll; drives the paging arrows.
    private(set) var overflow = CarouselShelfOverflow()
    private var hasReportedOverflow = false
    private var hoveredIndex: Int?
    private var observers: [NSObjectProtocol] = []
    private var layoutViewportWidth: CGFloat = 0
    private var scrollOffsetFromLeading: CGFloat = 0
    private var isLayingOutCells = false

    private var isRightToLeft: Bool {
        self.configuration.environment.layoutDirection == .rightToLeft
    }

    init(contentInset: CGFloat) {
        self.contentInset = contentInset
        super.init()

        self.documentView.hoverHandler = { [weak self] point in
            guard let self else { return }
            self.updateHover(at: point)
            self.containerView.setHovering(point != nil)
        }
        self.documentView.windowHandler = { [weak self] hasWindow in
            guard let self else { return }
            if hasWindow {
                self.refreshHoverFromMouseLocation()
            } else {
                // A shelf detached while hovered never receives `mouseExited`.
                self.updateHover(at: nil)
                self.containerView.setHovering(false)
            }
        }
        self.documentView.clickHandler = { [weak self] index, isLikeControl in
            if isLikeControl {
                self?.cells[index].toggleLike()
            } else {
                self?.activate(index)
            }
        }

        self.scrollView.documentView = self.documentView
        self.containerView.install(scrollView: self.scrollView, contentInset: contentInset)
        self.containerView.pageHandler = { [weak self] side in
            guard let self else { return }
            // Arrows are physical; paging is logical.
            self.page((side == .left) != self.isRightToLeft ? .leading : .trailing)
        }
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
        // A resize can change the frame without posting a bounds notification.
        self.scrollView.contentView.postsFrameChangedNotifications = true
    }

    /// Scroll observers live only while the shelf is installed. SwiftUI
    /// removes and re-adds platform views as they cross the viewport, so this
    /// must survive multiple attach/detach cycles.
    func installObservers() {
        guard self.observers.isEmpty else { return }
        self.observers = [
            NSView.boundsDidChangeNotification,
            NSView.frameDidChangeNotification,
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: self.scrollView.contentView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scrollGeometryDidChange()
                }
            }
        }
        self.scrollGeometryDidChange()
        self.observeLikeStatus()
        self.pushLikedState()
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
        let directionChanged = self.configuration.environment.layoutDirection != configuration.environment.layoutDirection
        let structureChanged = layoutKey(self.configuration.items) != layoutKey(configuration.items)
            || self.configuration.isChart != configuration.isChart
            || directionChanged
        self.configuration = configuration
        self.containerView.configure(
            shelfLabel: configuration.accessibilityLabel,
            usesLegacyMaterial: configuration.environment.usesLegacyMacOS15UI
        )
        if directionChanged {
            self.scrollOffsetFromLeading = 0
        }
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
        self.documentView.cells = self.cells
        self.layoutCells()
        // Drop the previous hover explicitly (the cell may have been retained)
        // and re-resolve it from the pointer for the new layout.
        if let hovered = self.hoveredIndex, hovered < self.cells.count {
            self.cells[hovered].setHovered(false, animated: false)
        }
        self.hoveredIndex = nil
        self.updateOverflow()
        self.refreshHoverFromMouseLocation()
    }

    private func layoutCells() {
        self.isLayingOutCells = true
        defer { self.isLayingOutCells = false }

        let clipView = self.scrollView.contentView
        self.layoutViewportWidth = clipView.bounds.width
        let widths = self.configuration.items.map { HomeItemCell.width(for: $0) }
        let contentWidth = widths.isEmpty ? 0 : widths.reduce(0, +)
            + CGFloat(widths.count - 1) * Self.itemSpacing + 2 * self.contentInset
        // Fill the viewport so a short RTL shelf still starts at the right inset.
        let documentWidth = max(contentWidth, self.layoutViewportWidth)
        var position = self.contentInset
        for (index, width) in widths.enumerated() {
            let x = self.isRightToLeft ? documentWidth - position - width : position
            self.cells[index].frame = NSRect(x: x, y: 0, width: width, height: HomeItemCell.height)
            position += width + Self.itemSpacing
        }
        self.documentView.frame = NSRect(x: 0, y: 0, width: documentWidth, height: HomeItemCell.height)

        let maxX = max(0, documentWidth - self.layoutViewportWidth)
        self.scrollOffsetFromLeading = min(max(self.scrollOffsetFromLeading, 0), maxX)
        let x = self.isRightToLeft ? maxX - self.scrollOffsetFromLeading : self.scrollOffsetFromLeading
        clipView.scroll(to: NSPoint(x: x, y: clipView.bounds.minY))
        self.scrollView.reflectScrolledClipView(clipView)
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
        // Keep the registration for unchanged songs, but resolve their current
        // metadata fallback even when the manager's cache has not changed.
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
        withObservationTracking {
            _ = self.observationTick.value
            for (_, song) in songs {
                _ = manager.isLiked(song)
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.likeObservationGeneration == generation else { return }
                self.observeLikeStatus(force: true)
                self.pushLikedState()
            }
        }
    }

    private func pushLikedState() {
        let manager = SongLikeStatusManager.shared
        for (index, item) in self.configuration.items.enumerated() where index < self.cells.count {
            guard case let .song(song) = item else { continue }
            self.cells[index].setLiked(manager.isLiked(song))
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
        // The tracking area is active only in the key window, so no
        // `mouseExited` would clear hover resolved while the window is not key.
        let inside = window.isKeyWindow && self.documentView.visibleRect.contains(point)
        self.updateHover(at: inside ? point : nil)
        self.containerView.setHovering(inside)
    }

    // MARK: Overflow + paging

    private func scrollGeometryDidChange() {
        guard !self.isLayingOutCells else { return }
        let visible = self.scrollView.contentView.bounds
        if visible.width != self.layoutViewportWidth {
            // AppKit may already have clamped the physical origin after a
            // resize. Preserve the previously recorded distance from leading.
            self.layoutCells()
        } else {
            let maxX = max(0, self.documentView.frame.width - visible.width)
            let offset = self.isRightToLeft ? maxX - visible.minX : visible.minX
            self.scrollOffsetFromLeading = min(max(offset, 0), maxX)
        }
        self.updateOverflow()
        self.refreshHoverFromMouseLocation()
    }

    private func updateOverflow() {
        let visible = self.scrollView.contentView.bounds
        let contentWidth = self.documentView.frame.width
        let left = visible.minX > 1
        let right = contentWidth - visible.maxX > 1
        self.overflow = CarouselShelfOverflow(
            leading: self.isRightToLeft ? right : left,
            trailing: self.isRightToLeft ? left : right
        )
        // The first report lands while the shelf is being built (often as it
        // scrolls into view); only later changes animate.
        self.containerView.setArrows(left: left, right: right, animated: self.hasReportedOverflow)
        self.hasReportedOverflow = true
    }

    func page(_ direction: CarouselShelfDirection) {
        let clipView = self.scrollView.contentView
        let visible = clipView.bounds
        let contentWidth = self.documentView.frame.width
        let pageWidth = max(1, visible.width * Self.pageFraction)
        let maxX = max(0, contentWidth - visible.width)
        let offset = self.isRightToLeft ? maxX - visible.minX : visible.minX
        let destination = switch direction {
        case .leading: offset - pageWidth
        case .trailing: offset + pageWidth
        }
        let clamped = min(max(destination, 0), maxX)
        let target = NSPoint(x: self.isRightToLeft ? maxX - clamped : clamped, y: visible.minY)

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
    /// Called with whether the view is now in a window.
    var windowHandler: ((Bool) -> Void)?
    /// `(index, isLikeControl)`.
    var clickHandler: ((Int, Bool) -> Void)?
    var cells: [HomeItemCell] = []
    private var trackingArea: NSTrackingArea?
    private var scrollsPageForGesture: Bool?
    private var pendingScrollStartEvents: [NSEvent] = []

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.windowHandler?(self.window != nil)
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

    /// Choose the recipient once per gesture, including its momentum and
    /// zero-delta end events. Wheel events without phases remain independent.
    override func scrollWheel(with event: NSEvent) {
        guard let page = self.enclosingScrollView?.enclosingScrollView else {
            self.scrollsPageForGesture = nil
            self.pendingScrollStartEvents = []
            super.scrollWheel(with: event)
            return
        }
        let phase = event.phase
        let momentum = event.momentumPhase
        let isVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        if phase.isEmpty, momentum.isEmpty {
            self.scrollsPageForGesture = nil
            self.pendingScrollStartEvents = []
            self.routeScrollEvent(event, to: isVertical ? page : nil)
            return
        }
        if phase.contains(.mayBegin) {
            self.scrollsPageForGesture = nil
            self.pendingScrollStartEvents = [event]
            return
        }
        if phase.contains(.began) {
            self.scrollsPageForGesture = nil
            self.pendingScrollStartEvents.removeAll { !$0.phase.contains(.mayBegin) }
        }

        let isEnding = !phase.isDisjoint(with: [.ended, .cancelled])
            || !momentum.isDisjoint(with: [.ended, .cancelled])
        if self.scrollsPageForGesture == nil {
            if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                self.scrollsPageForGesture = isVertical
            } else if isEnding {
                self.scrollsPageForGesture = false
            } else {
                // Start events can precede the first movement. Deliver them
                // to the chosen scroll view before its first nonzero sample.
                if phase.contains(.began) || momentum.contains(.began) {
                    self.pendingScrollStartEvents.append(event)
                }
                return
            }
        }
        let destination = self.scrollsPageForGesture == true ? page : nil
        let pending = self.pendingScrollStartEvents
        self.pendingScrollStartEvents = []
        for start in pending {
            self.routeScrollEvent(start, to: destination)
        }
        self.routeScrollEvent(event, to: destination)
        // A physical end can be followed by momentum. Retain the recipient
        // until momentum finishes or another gesture begins.
        if phase.contains(.cancelled) || !momentum.isDisjoint(with: [.ended, .cancelled]) {
            self.scrollsPageForGesture = nil
        }
    }

    private func routeScrollEvent(_ event: NSEvent, to page: NSScrollView?) {
        if let page {
            page.scrollWheel(with: event)
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
