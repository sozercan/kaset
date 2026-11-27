import AppKit
import SwiftUI

struct HomeItemShelfSection<Header: View, MenuContent: View>: View {
    let accessibilityLabel: String
    let items: [HomeSectionItem]
    let isChart: Bool
    let contentInset: CGFloat
    let action: (HomeSectionItem, Int) -> Void
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

struct HomeItemCollectionShelf: NSViewRepresentable {
    let items: [HomeSectionItem]
    let isChart: Bool
    let contentInset: CGFloat
    let action: (HomeSectionItem, Int) -> Void
    let playlistPlayAction: (HomeSectionItem) -> (() -> Void)?
    let contextMenu: ((HomeSectionItem, Int) -> AnyView)?
    let accessibilityLabel: String

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
            self.page(CarouselShelfDirection(isLeft: side == .left, in: self.configuration.environment.layoutDirection))
        }
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.hasVerticalScroller = false
        self.scrollView.horizontalScrollElasticity = .allowed
        self.scrollView.verticalScrollElasticity = .none
        self.scrollView.usesPredominantAxisScrolling = true
        self.scrollView.drawsBackground = false
        self.scrollView.contentView.postsBoundsChangedNotifications = true
        self.scrollView.contentView.postsFrameChangedNotifications = true
    }

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
        self.likeObservationGeneration += 1
        self.observedSongIDs = []
        self.observationTick.value += 1
    }

    func apply(_ configuration: Configuration) {
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
            self.configureCells()
        }
    }

    private func rebuildCells() {
        let items = self.configuration.items
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
        self.observeLikeStatus()
        self.pushLikedState()
    }

    private var likeObservationGeneration = 0
    private var observedSongIDs: [String] = []
    private let observationTick = ObservationTick()

    private func observeLikeStatus(force: Bool = false) {
        let songs: [(Int, Song)] = self.configuration.items.enumerated().compactMap { index, item in
            if case let .song(song) = item {
                return (index, song)
            }
            return nil
        }
        let songIDs = songs.map { "\($0.0):\($0.1.id)" }
        guard force || songIDs != self.observedSongIDs else { return }
        self.observedSongIDs = songIDs
        self.likeObservationGeneration += 1
        let generation = self.likeObservationGeneration
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
        let inside = window.isKeyWindow && self.documentView.visibleRect.contains(point)
        self.updateHover(at: inside ? point : nil)
        self.containerView.setHovering(inside)
    }

    private func scrollGeometryDidChange() {
        guard !self.isLayingOutCells else { return }
        let visible = self.scrollView.contentView.bounds
        if visible.width != self.layoutViewportWidth {
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
        guard visible.width > 0 else { return }
        let contentWidth = self.documentView.frame.width
        self.containerView.setArrows(
            left: visible.minX > 1,
            right: contentWidth - visible.maxX > 1,
            animated: self.hasReportedOverflow
        )
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

@MainActor
@Observable
private final class ObservationTick {
    var value = 0
}

@MainActor
private final class HomeItemShelfDocumentView: NSView {
    var hoverHandler: ((NSPoint?) -> Void)?
    var windowHandler: ((Bool) -> Void)?
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
