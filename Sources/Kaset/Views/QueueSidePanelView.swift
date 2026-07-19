import AppKit
import SwiftUI

// MARK: - QueueSidePanelView

struct QueueSidePanelView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager

    var body: some View {
        // Use regular material: GlassEffectContainer breaks NSTableView drag-and-drop
        // (drop target gap and acceptDrop never fire when the table is inside glass).
        VStack(spacing: 0) {
            QueueSidePanelHeader()

            Divider()
                .opacity(0.3)

            if self.playerService.queue.isEmpty {
                self.emptyQueueView
            } else {
                QueueListControllerRepresentable(
                    entries: self.playerService.queueEntries,
                    currentIndex: self.playerService.activePlaybackQueueIndex ?? -1,
                    isPlaying: self.playerService.isPlaying,
                    favoritesManager: self.favoritesManager,
                    likeStatusManager: self.likeStatusManager,
                    allowsLikeActions: self.authService.hasPersonalAccount,
                    likeStatusEvent: self.likeStatusManager.lastLikeEvent,
                    onSelect: { entryID in
                        let reservation = self.playerService.reserveMusicPlaybackIntent()
                        Task { @MainActor in
                            guard let intent = self.playerService.claimMusicPlaybackIntent(
                                reservation,
                                queueEntryID: entryID
                            ) else { return }
                            await self.playerService.playFromQueue(entryID: entryID, intent: intent)
                        }
                    },
                    onReorder: { entryID, beforeEntryID in
                        self.playerService.reorderQueue(entryID: entryID, before: beforeEntryID)
                    },
                    onRemove: { entryID in
                        self.playerService.removeFromQueue(entryIDs: [entryID])
                    },
                    onStartRadio: { song in
                        let intent = self.playerService.beginMusicPlaybackIntent()
                        Task {
                            await self.playerService.playWithRadio(song: song, intent: intent)
                        }
                    }
                )
                .accessibilityIdentifier(AccessibilityID.Queue.scrollView)
            }

            Divider()
                .opacity(0.3)

            QueueFooterActions()
        }
        .frame(width: 400)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier(AccessibilityID.Queue.container)
    }

    private var emptyQueueView: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(String(localized: "No Queue"))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(String(localized: "Play songs from a playlist or album to build your queue."))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityID.Queue.emptyState)
    }
}

// MARK: - QueueListControllerRepresentable

struct QueueListControllerRepresentable: NSViewControllerRepresentable {
    let entries: [QueueEntry]
    let currentIndex: Int
    let isPlaying: Bool
    let favoritesManager: FavoritesManager
    let likeStatusManager: SongLikeStatusManager
    let allowsLikeActions: Bool
    /// Observed to refresh visible AppKit rows after optimistic like updates and rollbacks.
    let likeStatusEvent: LikeStatusEvent?
    let onSelect: (UUID) -> Void
    let onReorder: (UUID, UUID?) -> Void
    let onRemove: (UUID) -> Void
    let onStartRadio: (Song) -> Void

    func makeNSViewController(context: Context) -> QueueListViewController {
        let viewController = QueueListViewController()
        viewController.coordinator = context.coordinator
        context.coordinator.viewController = viewController
        return viewController
    }

    func updateNSViewController(_ viewController: QueueListViewController, context: Context) {
        context.coordinator.favoritesManager = self.favoritesManager
        context.coordinator.likeStatusManager = self.likeStatusManager
        context.coordinator.allowsLikeActions = self.allowsLikeActions
        context.coordinator.lastLikeEvent = self.likeStatusEvent

        if context.coordinator.isDragging {
            context.coordinator.pendingEntries = self.entries
            context.coordinator.pendingCurrentIndex = self.currentIndex
            context.coordinator.pendingIsPlaying = self.isPlaying
            return
        } else {
            context.coordinator.entries = self.entries
            context.coordinator.currentIndex = self.currentIndex
            context.coordinator.isPlaying = self.isPlaying
            viewController.tableView?.reloadData()
            viewController.tableView?.normalizeVisibleRowFrames()
        }

        // Update current track highlighting and waveform animation
        if let tableView = viewController.tableView {
            for row in 0 ..< self.entries.count {
                if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueTableCellView {
                    cellView.updateAppearance(
                        isCurrentTrack: row == self.currentIndex,
                        isPlaying: self.isPlaying,
                        index: row
                    )
                    cellView.updateLikeState(isLiked: self.allowsLikeActions && self.likeStatusManager.isLiked(self.entries[row].song))
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            entries: self.entries,
            currentIndex: self.currentIndex,
            isPlaying: self.isPlaying,
            favoritesManager: self.favoritesManager,
            likeStatusManager: self.likeStatusManager,
            allowsLikeActions: self.allowsLikeActions,
            onSelect: self.onSelect,
            onReorder: self.onReorder,
            onRemove: self.onRemove,
            onStartRadio: self.onStartRadio
        )
    }

    // MARK: - View Controller

    @MainActor
    class QueueListViewController: NSViewController {
        var tableView: DraggableTableView?
        weak var coordinator: Coordinator?

        override func loadView() {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.backgroundColor = .clear
            scrollView.drawsBackground = false
            scrollView.hasHorizontalScroller = false // Disable horizontal scrolling
            scrollView.horizontalScrollElasticity = .none // No horizontal bounce

            let tableView = DraggableTableView()
            tableView.headerView = nil
            tableView.selectionHighlightStyle = .none
            tableView.backgroundColor = .clear
            tableView.allowsEmptySelection = true
            tableView.allowsColumnResizing = false
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            tableView.intercellSpacing = NSSize(width: 0, height: 0)
            tableView.rowHeight = 56

            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("QueueColumn"))
            column.title = ""
            column.minWidth = 350
            column.maxWidth = 400
            column.width = 350 // Matches container width minus scroll bar space
            tableView.addTableColumn(column)

            let dragType = NSPasteboard.PasteboardType("com.kaset.queueitem")
            tableView.registerForDraggedTypes([dragType, .string])
            tableView.verticalMotionCanBeginDrag = true
            tableView.draggingDestinationFeedbackStyle = .gap // Show gap where item will be dropped

            scrollView.documentView = tableView
            self.tableView = tableView
            self.view = scrollView
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            if let tableView {
                tableView.delegate = self.coordinator
                tableView.dataSource = self.coordinator
                tableView.coordinator = self.coordinator
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        private static let cellIdentifier = NSUserInterfaceItemIdentifier("QueueTableCell")

        var entries: [QueueEntry]
        var currentIndex: Int
        var isPlaying: Bool
        var favoritesManager: FavoritesManager
        var likeStatusManager: SongLikeStatusManager
        var allowsLikeActions: Bool
        var lastLikeEvent: LikeStatusEvent?
        let onSelect: (UUID) -> Void
        let onReorder: (UUID, UUID?) -> Void
        let onRemove: (UUID) -> Void
        let onStartRadio: (Song) -> Void
        weak var viewController: QueueListViewController?
        var isDragging = false
        var pendingEntries: [QueueEntry]?
        var pendingCurrentIndex: Int?
        var pendingIsPlaying: Bool?
        private let dragType = NSPasteboard.PasteboardType("com.kaset.queueitem")

        init(entries: [QueueEntry], currentIndex: Int, isPlaying: Bool, favoritesManager: FavoritesManager,
             likeStatusManager: SongLikeStatusManager,
             allowsLikeActions: Bool,
             onSelect: @escaping (UUID) -> Void, onReorder: @escaping (UUID, UUID?) -> Void, onRemove: @escaping (UUID) -> Void, onStartRadio: @escaping (Song) -> Void)
        {
            self.entries = entries
            self.currentIndex = currentIndex
            self.isPlaying = isPlaying
            self.favoritesManager = favoritesManager
            self.likeStatusManager = likeStatusManager
            self.allowsLikeActions = allowsLikeActions
            self.onSelect = onSelect
            self.onReorder = onReorder
            self.onRemove = onRemove
            self.onStartRadio = onStartRadio
            super.init()
        }

        /// Removes the displayed entry with slide-out animation, then calls onRemove.
        /// - Parameter slideDirection: -1 = slide left, +1 = slide right (matches swipe direction).
        func removeRowWithAnimation(row: Int, slideDirection: CGFloat) {
            guard let entryID = self.entries[safe: row]?.id else { return }
            guard let tableView = self.viewController?.tableView else {
                self.onRemove(entryID)
                return
            }
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else {
                self.onRemove(entryID)
                return
            }
            let offsetX = slideDirection * rowView.bounds.width
            let originalFrame = rowView.frame
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                rowView.animator().alphaValue = 0
                rowView.animator().frame.origin.x += offsetX
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    rowView.alphaValue = 1
                    var resetFrame = originalFrame
                    resetFrame.origin.x = 0
                    rowView.frame = resetFrame
                    self?.onRemove(entryID)
                }
            }
        }

        func numberOfRows(in _: NSTableView) -> Int {
            self.entries.count
        }

        func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let cellView = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? QueueTableCellView) ?? {
                let view = QueueTableCellView()
                view.identifier = Self.cellIdentifier
                return view
            }()
            let entry = self.entries[row]
            let song = entry.song
            let isLiked = self.allowsLikeActions && self.likeStatusManager.isLiked(song)
            cellView.configure(
                song: song,
                index: row,
                isCurrentTrack: row == self.currentIndex,
                isPlaying: self.isPlaying,
                isSuggested: entry.source == .suggested,
                actions: QueueCellActions(
                    onPlay: { [weak self] in self?.onSelect(entry.id) },
                    onRemove: { [weak self] in self?.onRemove(entry.id) },
                    onToggleLike: { [weak self] in
                        guard let self else { return }
                        guard self.allowsLikeActions else { return }
                        if self.likeStatusManager.isLiked(song) {
                            SongActionsHelper.unlikeSong(song, likeStatusManager: self.likeStatusManager)
                        } else {
                            SongActionsHelper.likeSong(song, likeStatusManager: self.likeStatusManager)
                        }
                    },
                    allowsLikeAction: self.allowsLikeActions,
                    isLiked: isLiked
                )
            )
            return cellView
        }

        func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
            56
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            let selectedRow = tableView.selectedRow
            if selectedRow >= 0, let entry = self.entries[safe: selectedRow] {
                self.onSelect(entry.id)
                tableView.deselectAll(nil)
            }
        }

        /// Drag Source
        func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let entry = self.entries[safe: row], entry.id != self.currentEntryID else { return nil }
            let item = NSPasteboardItem()
            item.setString(entry.id.uuidString, forType: self.dragType)
            self.isDragging = true
            return item
        }

        func tableView(_: NSTableView, draggingSession _: NSDraggingSession, willBeginAt _: NSPoint, forRowIndexes _: IndexSet) {
            // Dragging session began
        }

        func tableView(_ tableView: NSTableView, draggingSession _: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
            self.isDragging = false
            self.applyPendingSnapshot()
            tableView.reloadData()
            (tableView as? DraggableTableView)?.normalizeVisibleRowFrames()
        }

        /// Drop Destination
        func tableView(_: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard dropOperation == .above,
                  let sourceEntryID = self.draggedEntryID(from: info),
                  sourceEntryID != self.currentEntryID
            else { return [] }
            let beforeEntryID = self.entries[safe: row]?.id
            guard beforeEntryID != sourceEntryID,
                  !self.dropWouldKeepEntryInPlace(sourceEntryID: sourceEntryID, proposedRow: row)
            else { return [] }
            return .move
        }

        func tableView(_: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation _: NSTableView.DropOperation) -> Bool {
            guard let sourceEntryID = self.draggedEntryID(from: info),
                  sourceEntryID != self.currentEntryID,
                  !self.dropWouldKeepEntryInPlace(sourceEntryID: sourceEntryID, proposedRow: row)
            else { return false }
            self.onReorder(sourceEntryID, self.entries[safe: row]?.id)
            return true
        }

        private func applyPendingSnapshot() {
            if let pendingEntries {
                self.entries = pendingEntries
            }
            if let pendingCurrentIndex {
                self.currentIndex = pendingCurrentIndex
            }
            if let pendingIsPlaying {
                self.isPlaying = pendingIsPlaying
            }
            self.pendingEntries = nil
            self.pendingCurrentIndex = nil
            self.pendingIsPlaying = nil
        }

        var currentEntryID: UUID? {
            self.entries[safe: self.currentIndex]?.id
        }

        private func draggedEntryID(from info: NSDraggingInfo) -> UUID? {
            guard let value = info.draggingPasteboard.string(forType: self.dragType) else { return nil }
            return UUID(uuidString: value)
        }

        private func dropWouldKeepEntryInPlace(sourceEntryID: UUID, proposedRow: Int) -> Bool {
            guard let sourceRow = self.entries.firstIndex(where: { $0.id == sourceEntryID }) else { return true }
            return proposedRow == sourceRow || proposedRow == sourceRow + 1
        }

        // MARK: - Context Menu

        func tableView(_: NSTableView, menuForRow row: Int, event _: NSEvent) -> NSMenu? {
            guard row >= 0, let entry = entries[safe: row] else { return nil }
            let song = entry.song
            let menu = NSMenu()
            if self.allowsLikeActions {
                let manager = self.favoritesManager
                let isPinned = MainActor.assumeIsolated { manager.isPinned(song: song) }

                let favoritesItem = NSMenuItem(
                    title: isPinned ? "Remove from Favorites" : "Add to Favorites",
                    action: #selector(Coordinator.contextMenuFavorites(_:)),
                    keyEquivalent: ""
                )
                favoritesItem.target = self
                favoritesItem.representedObject = song
                favoritesItem.image = NSImage(systemSymbolName: isPinned ? "heart.slash" : "heart", accessibilityDescription: nil)
                menu.addItem(favoritesItem)

                menu.addItem(NSMenuItem.separator())
            }

            let startRadioItem = NSMenuItem(title: "Start Radio", action: #selector(Coordinator.contextMenuStartRadio(_:)), keyEquivalent: "")
            startRadioItem.target = self
            startRadioItem.representedObject = song
            startRadioItem.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
            menu.addItem(startRadioItem)

            menu.addItem(NSMenuItem.separator())

            if song.shareURL != nil {
                let shareItem = NSMenuItem(title: "Share", action: #selector(Coordinator.contextMenuShare(_:)), keyEquivalent: "")
                shareItem.target = self
                shareItem.representedObject = song
                shareItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
                menu.addItem(shareItem)
                menu.addItem(NSMenuItem.separator())
            }

            if entry.id != self.currentEntryID {
                let removeItem = NSMenuItem(title: "Remove from Queue", action: #selector(Coordinator.contextMenuRemove(_:)), keyEquivalent: "")
                removeItem.target = self
                removeItem.representedObject = entry.id.uuidString
                removeItem.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)
                menu.addItem(removeItem)
            }

            return menu
        }

        @objc private func contextMenuFavorites(_ sender: NSMenuItem) {
            guard self.allowsLikeActions, let song = sender.representedObject as? Song else { return }
            let manager = self.favoritesManager
            MainActor.assumeIsolated { manager.toggle(song: song) }
        }

        @objc private func contextMenuStartRadio(_ sender: NSMenuItem) {
            guard let song = sender.representedObject as? Song else { return }
            self.onStartRadio(song)
        }

        @objc private func contextMenuShare(_ sender: NSMenuItem) {
            guard let song = sender.representedObject as? Song, let url = song.shareURL else { return }
            MainActor.assumeIsolated {
                ShareContextMenu.showSharePicker(for: url)
            }
        }

        @objc private func contextMenuRemove(_ sender: NSMenuItem) {
            guard let entryIDString = sender.representedObject as? String,
                  let entryID = UUID(uuidString: entryIDString)
            else { return }
            self.onRemove(entryID)
        }
    }
}

// MARK: - DraggableTableView

@MainActor
class DraggableTableView: NSTableView {
    weak var coordinator: QueueListControllerRepresentable.Coordinator?

    /// Accumulated scroll deltas during the current gesture (used to detect swipe-to-remove).
    private var horizontalSwipeAccumulator: CGFloat = 0
    private var verticalSwipeAccumulator: CGFloat = 0
    /// Row index under the cursor when the gesture *started* (.began), so we remove that row even if content scrolls by .ended.
    private var swipeRemoveTargetRow: Int = -1
    private var swipeRemoveTargetEntryID: UUID?
    /// When non-nil, we're showing real-time slide feedback; value is the row view's initial origin.x to restore on cancel.
    private var swipeTrackedInitialOriginX: CGFloat?
    /// Cooldown after a remove so we don't trigger again from leftover events.
    private var swipeRemoveCooldownUntil: CFAbsoluteTime = 0
    /// Minimum horizontal delta to "commit" and start moving the row (avoids vertical scroll moving a row).
    private static let swipeCommitThreshold: CGFloat = 10
    /// Horizontal swipe distance (pt) beyond which release counts as delete. Increase for a more deliberate confirm, decrease for quicker remove.
    private static let swipeRemoveDeltaThreshold: CGFloat = 100
    private static let swipeRemoveCooldown: CFAbsoluteTime = 0.5
    /// Max horizontal drag (multiple of row width) for real-time feedback.
    private static let swipeMaxDragFactor: CGFloat = 1.2

    override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated {
            self.setupTable()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        MainActor.assumeIsolated {
            self.setupTable()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        MainActor.assumeIsolated {
            self.setupTable()
        }
    }

    private func setupTable() {
        // Enable gap feedback style for drag-and-drop
        self.draggingDestinationFeedbackStyle = .gap
    }

    /// Resets row views that still carry a horizontal offset from swipe-to-remove feedback.
    func normalizeVisibleRowFrames() {
        let visibleRange = self.rows(in: self.visibleRect)
        guard visibleRange.length > 0 else { return }

        for row in visibleRange.location ..< NSMaxRange(visibleRange) {
            Self.normalizeRowView(self.rowView(atRow: row, makeIfNecessary: false))
        }
    }

    private static func normalizeRowView(_ rowView: NSTableRowView?) {
        guard let rowView else { return }

        var frame = rowView.frame
        guard frame.origin.x != 0 || rowView.alphaValue != 1 else { return }

        frame.origin.x = 0
        rowView.frame = frame
        rowView.alphaValue = 1
    }

    /// Two-finger horizontal trackpad swipe: row follows finger in real time; release past threshold to remove, or return to cancel.
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        switch event.phase {
        case .began:
            self.handleSwipeBegan(dx: dx, dy: dy, event: event)
        case .changed:
            self.handleSwipeChanged(dx: dx, dy: dy)
        case .ended, .cancelled:
            if self.handleSwipeEnded(event: event) {
                return
            }
        default:
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                self.horizontalSwipeAccumulator = 0
                self.verticalSwipeAccumulator = 0
                self.swipeRemoveTargetRow = -1
                self.swipeRemoveTargetEntryID = nil
                self.swipeTrackedInitialOriginX = nil
            }
        }

        super.scrollWheel(with: event)
    }

    /// Handles the `.began` phase of a trackpad swipe gesture.
    private func handleSwipeBegan(dx: CGFloat, dy: CGFloat, event: NSEvent) {
        self.horizontalSwipeAccumulator = dx
        self.verticalSwipeAccumulator = dy
        self.swipeRemoveTargetRow = -1
        self.swipeRemoveTargetEntryID = nil
        self.swipeTrackedInitialOriginX = nil
        if let coordinator = self.coordinator {
            let point = event.locationInWindow
            let localPoint = self.convert(point, from: nil)
            let rowAtStart = self.row(at: localPoint)
            self.swipeRemoveTargetRow = rowAtStart
            self.swipeRemoveTargetEntryID = coordinator.entries[safe: rowAtStart]?.id
            if rowAtStart >= 0 {
                Self.normalizeRowView(self.rowView(atRow: rowAtStart, makeIfNecessary: false))
            }
            self.swipeTrackedInitialOriginX = 0
        }
    }

    /// Handles the `.changed` phase of a trackpad swipe gesture, sliding the row in real time.
    private func handleSwipeChanged(dx: CGFloat, dy: CGFloat) {
        self.horizontalSwipeAccumulator += dx
        self.verticalSwipeAccumulator += dy
        // Real-time row slide: once horizontal movement passes commit threshold, move the row with the finger.
        if let coord = coordinator,
           let swipeRemoveTargetEntryID,
           swipeRemoveTargetRow >= 0,
           swipeRemoveTargetEntryID != coord.currentEntryID,
           coord.entries.contains(where: { $0.id == swipeRemoveTargetEntryID }),
           abs(horizontalSwipeAccumulator) > Self.swipeCommitThreshold,
           abs(horizontalSwipeAccumulator) > abs(verticalSwipeAccumulator)
        {
            guard let rowView = self.rowView(atRow: swipeRemoveTargetRow, makeIfNecessary: false) else {
                return
            }
            if self.swipeTrackedInitialOriginX == nil {
                Self.normalizeRowView(rowView)
                self.swipeTrackedInitialOriginX = 0
            }
            let initialX = self.swipeTrackedInitialOriginX ?? 0
            let maxDrag = rowView.bounds.width * Self.swipeMaxDragFactor
            let clamped = max(-maxDrag, min(maxDrag, self.horizontalSwipeAccumulator))
            var f = rowView.frame
            f.origin.x = initialX + clamped
            rowView.frame = f
        }
    }

    /// Handles the `.ended` / `.cancelled` phase of a trackpad swipe gesture. Returns `true` if the event was fully consumed.
    private func handleSwipeEnded(event: NSEvent) -> Bool {
        let accH = self.horizontalSwipeAccumulator
        let accV = self.verticalSwipeAccumulator
        let rowAtEnd = self.row(at: self.convert(event.locationInWindow, from: nil))
        self.horizontalSwipeAccumulator = 0
        self.verticalSwipeAccumulator = 0

        if let initialX = swipeTrackedInitialOriginX {
            self.swipeTrackedInitialOriginX = nil
            guard let coord = coordinator,
                  swipeRemoveTargetRow >= 0,
                  let entryID = swipeRemoveTargetEntryID
            else {
                self.swipeRemoveTargetRow = -1
                self.swipeRemoveTargetEntryID = nil
                return false
            }
            let row = self.swipeRemoveTargetRow
            self.swipeRemoveTargetRow = -1
            self.swipeRemoveTargetEntryID = nil
            guard let rowView = self.rowView(atRow: row, makeIfNecessary: false) else {
                return false
            }

            let passed = CFAbsoluteTimeGetCurrent() >= self.swipeRemoveCooldownUntil
                && abs(accH) >= Self.swipeRemoveDeltaThreshold
                && abs(accH) > abs(accV)
                && entryID != coord.entries[safe: coord.currentIndex]?.id

            if passed {
                let slideDirection: CGFloat = accH > 0 ? 1 : -1
                let targetX = initialX + slideDirection * rowView.bounds.width
                self.swipeRemoveCooldownUntil = CFAbsoluteTimeGetCurrent() + Self.swipeRemoveCooldown
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    var f = rowView.frame
                    f.origin.x = targetX
                    rowView.animator().frame = f
                    rowView.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated {
                        Self.normalizeRowView(rowView)
                        coord.onRemove(entryID)
                    }
                }
                return true
            } else {
                // Cancel: animate row back to initial position.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    var f = rowView.frame
                    f.origin.x = 0
                    rowView.animator().frame = f
                } completionHandler: {
                    MainActor.assumeIsolated {
                        Self.normalizeRowView(rowView)
                    }
                }
                return true
            }
        }

        if CFAbsoluteTimeGetCurrent() < self.swipeRemoveCooldownUntil {
            return false
        }
        guard abs(accH) >= Self.swipeRemoveDeltaThreshold,
              abs(accH) > abs(accV)
        else { return false }
        guard let coord = coordinator else { return false }
        let row = self.swipeRemoveTargetRow >= 0 ? self.swipeRemoveTargetRow : rowAtEnd
        self.swipeRemoveTargetRow = -1
        if row < 0 {
            return false
        }
        if row == coord.currentIndex {
            return false
        }
        guard coord.entries[safe: row] != nil else { return false }
        let slideDirection: CGFloat = accH > 0 ? 1 : -1
        self.swipeRemoveCooldownUntil = CFAbsoluteTimeGetCurrent() + Self.swipeRemoveCooldown
        coord.removeRowWithAnimation(row: row, slideDirection: slideDirection)
        return true
    }
}

// MARK: - QueueSidePanelHeader

private struct QueueSidePanelHeader: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        HStack {
            Text(String(localized: "Up Next"))
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Text("\(self.playerService.queue.count) songs", comment: "Queue song count")
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                Button {
                    guard self.playerService.queueHasDuplicateEntries else { return }
                    self.playerService.removeDuplicateQueueEntries()
                } label: {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .opacity(self.playerService.queueHasDuplicateEntries ? 1 : 0.45)
                .allowsHitTesting(self.playerService.queueHasDuplicateEntries)
            }
            .help(String(localized: "Remove Duplicates: delete repeated songs from the queue and keep the first occurrence of each."))
            .accessibilityLabel(String(localized: "Remove Duplicates"))
            .accessibilityIdentifier(AccessibilityID.Queue.removeDuplicatesButton)

            Button {
                self.playerService.toggleQueueDisplayMode()
            } label: {
                Label(String(localized: "Done"), systemImage: "checkmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Close side panel"))
            .accessibilityLabel(String(localized: "Close side panel"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Preview

#Preview("Queue Side Panel") {
    let playerService = PlayerService()
    QueueSidePanelView()
        .environment(playerService)
        .environment(FavoritesManager.shared)
        .frame(height: 600)
}
