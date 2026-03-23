import SwiftUI

// MARK: - QueueSidePanelView

@available(macOS 26.0, *)
struct QueueSidePanelView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager

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
                    queue: self.playerService.queue,
                    currentIndex: self.playerService.currentIndex,
                    isPlaying: self.playerService.isPlaying,
                    favoritesManager: self.favoritesManager,
                    onSelect: { index in
                        Task {
                            await self.playerService.playFromQueue(at: index)
                        }
                    },
                    onReorder: { source, destination in
                        self.playerService.reorderQueue(from: IndexSet(integer: source), to: destination)
                    },
                    onRemove: { videoId in
                        Task {
                            await self.playerService.removeFromQueue(videoIds: Set([videoId]))
                        }
                    },
                    onStartRadio: { song in
                        Task {
                            await self.playerService.playWithRadio(song: song)
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

            Text("No Queue")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Play songs from a playlist or album to build your queue.")
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

@available(macOS 26.0, *)
struct QueueListControllerRepresentable: NSViewControllerRepresentable {
    let queue: [Song]
    let currentIndex: Int
    let isPlaying: Bool
    let favoritesManager: FavoritesManager
    let onSelect: (Int) -> Void
    let onReorder: (Int, Int) -> Void
    let onRemove: (String) -> Void
    let onStartRadio: (Song) -> Void

    func makeNSViewController(context: Context) -> QueueListViewController {
        let viewController = QueueListViewController()
        viewController.coordinator = context.coordinator
        context.coordinator.viewController = viewController
        return viewController
    }

    func updateNSViewController(_ viewController: QueueListViewController, context: Context) {
        context.coordinator.queue = self.queue
        context.coordinator.currentIndex = self.currentIndex
        context.coordinator.isPlaying = self.isPlaying
        context.coordinator.favoritesManager = self.favoritesManager

        if !context.coordinator.isDragging {
            viewController.tableView?.reloadData()
        }

        // Update current track highlighting and waveform animation
        if let tableView = viewController.tableView {
            for row in 0 ..< self.queue.count {
                if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueTableCellView {
                    cellView.updateAppearance(
                        isCurrentTrack: row == self.currentIndex,
                        isPlaying: self.isPlaying,
                        index: row
                    )
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            queue: self.queue,
            currentIndex: self.currentIndex,
            isPlaying: self.isPlaying,
            favoritesManager: self.favoritesManager,
            onSelect: self.onSelect,
            onReorder: self.onReorder,
            onRemove: self.onRemove,
            onStartRadio: self.onStartRadio
        )
    }

    // MARK: - View Controller

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

    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var queue: [Song]
        var currentIndex: Int
        var isPlaying: Bool
        var favoritesManager: FavoritesManager
        let onSelect: (Int) -> Void
        let onReorder: (Int, Int) -> Void
        let onRemove: (String) -> Void
        let onStartRadio: (Song) -> Void
        weak var viewController: QueueListViewController?
        var isDragging = false
        private let dragType = NSPasteboard.PasteboardType("com.kaset.queueitem")

        init(queue: [Song], currentIndex: Int, isPlaying: Bool, favoritesManager: FavoritesManager,
             onSelect: @escaping (Int) -> Void, onReorder: @escaping (Int, Int) -> Void, onRemove: @escaping (String) -> Void, onStartRadio: @escaping (Song) -> Void)
        {
            self.queue = queue
            self.currentIndex = currentIndex
            self.isPlaying = isPlaying
            self.favoritesManager = favoritesManager
            self.onSelect = onSelect
            self.onReorder = onReorder
            self.onRemove = onRemove
            self.onStartRadio = onStartRadio
            super.init()
        }

        /// Removes the row with slide-out animation, then calls onRemove.
        /// - Parameter slideDirection: -1 = slide left, +1 = slide right (matches swipe direction).
        func removeRowWithAnimation(row: Int, song: Song, slideDirection: CGFloat) {
            guard let tableView = viewController?.tableView else {
                self.onRemove(song.videoId)
                return
            }
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else {
                self.onRemove(song.videoId)
                return
            }
            let videoId = song.videoId
            let offsetX = slideDirection * rowView.bounds.width
            let originalFrame = rowView.frame
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                rowView.animator().alphaValue = 0
                rowView.animator().frame.origin.x += offsetX
            } completionHandler: { [weak self] in
                // Reset row view so it can be reused without a stuck frame/alpha (fixes misaligned rows).
                rowView.alphaValue = 1
                rowView.frame = originalFrame
                self?.onRemove(videoId)
            }
        }

        func numberOfRows(in _: NSTableView) -> Int {
            self.queue.count
        }

        func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let cellView = QueueTableCellView()
            let song = self.queue[row]
            cellView.configure(
                song: song,
                index: row,
                isCurrentTrack: row == self.currentIndex,
                isPlaying: self.isPlaying,
                actions: QueueCellActions(
                    onPlay: { [weak self] in self?.onSelect(row) },
                    onRemove: { [weak self] in self?.onRemove(song.videoId) }
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
            if selectedRow >= 0 {
                self.onSelect(selectedRow)
                tableView.deselectAll(nil)
            }
        }

        /// Drag Source
        func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row != self.currentIndex else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(row), forType: self.dragType)
            self.isDragging = true
            return item
        }

        func tableView(_: NSTableView, draggingSession _: NSDraggingSession, willBeginAt _: NSPoint, forRowIndexes _: IndexSet) {
            // Dragging session began
        }

        func tableView(_: NSTableView, draggingSession _: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
            self.isDragging = false
        }

        /// Drop Destination
        func tableView(_: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard dropOperation == .above else { return [] }
            guard let str = info.draggingPasteboard.string(forType: dragType),
                  let srcRow = Int(str) else { return [] }
            let destRow = row
            guard destRow != self.currentIndex, srcRow != destRow else { return [] }
            return .move
        }

        func tableView(_: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation _: NSTableView.DropOperation) -> Bool {
            guard let str = info.draggingPasteboard.string(forType: dragType),
                  let srcRow = Int(str) else { return false }
            let destRow = row
            guard srcRow != self.currentIndex, destRow != self.currentIndex, srcRow != destRow else { return false }
            self.onReorder(srcRow, destRow)
            self.isDragging = false
            return true
        }

        // MARK: - Context Menu

        func tableView(_: NSTableView, menuForRow row: Int, event _: NSEvent) -> NSMenu? {
            guard row >= 0, let song = queue[safe: row] else { return nil }
            let menu = NSMenu()
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

            if row != self.currentIndex {
                let removeItem = NSMenuItem(title: "Remove from Queue", action: #selector(Coordinator.contextMenuRemove(_:)), keyEquivalent: "")
                removeItem.target = self
                removeItem.representedObject = song
                removeItem.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)
                menu.addItem(removeItem)
            }

            return menu
        }

        @objc private func contextMenuFavorites(_ sender: NSMenuItem) {
            guard let song = sender.representedObject as? Song else { return }
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
            guard let song = sender.representedObject as? Song else { return }
            self.onRemove(song.videoId)
        }
    }
}

// MARK: - DraggableTableView

@available(macOS 26.0, *)
class DraggableTableView: NSTableView {
    weak var coordinator: QueueListControllerRepresentable.Coordinator?

    /// Accumulated scroll deltas during the current gesture (used to detect swipe-to-remove).
    private var horizontalSwipeAccumulator: CGFloat = 0
    private var verticalSwipeAccumulator: CGFloat = 0
    /// Row index under the cursor when the gesture *started* (.began), so we remove that row even if content scrolls by .ended.
    private var swipeRemoveTargetRow: Int = -1
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
        self.setupTable()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setupTable()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupTable()
    }

    private func setupTable() {
        // Enable gap feedback style for drag-and-drop
        self.draggingDestinationFeedbackStyle = .gap
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
            if self.handleSwipeEnded(event: event) { return }
        default:
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                self.horizontalSwipeAccumulator = 0
                self.verticalSwipeAccumulator = 0
                self.swipeRemoveTargetRow = -1
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
        self.swipeTrackedInitialOriginX = nil
        if self.coordinator != nil {
            let point = event.locationInWindow
            let localPoint = self.convert(point, from: nil)
            let rowAtStart = self.row(at: localPoint)
            self.swipeRemoveTargetRow = rowAtStart
        }
    }

    /// Handles the `.changed` phase of a trackpad swipe gesture, sliding the row in real time.
    private func handleSwipeChanged(dx: CGFloat, dy: CGFloat) {
        self.horizontalSwipeAccumulator += dx
        self.verticalSwipeAccumulator += dy
        // Real-time row slide: once horizontal movement passes commit threshold, move the row with the finger.
        if let coord = coordinator,
           swipeRemoveTargetRow >= 0,
           swipeRemoveTargetRow != coord.currentIndex,
           coord.queue[safe: swipeRemoveTargetRow] != nil,
           abs(horizontalSwipeAccumulator) > Self.swipeCommitThreshold,
           abs(horizontalSwipeAccumulator) > abs(verticalSwipeAccumulator)
        {
            guard let rowView = self.rowView(atRow: swipeRemoveTargetRow, makeIfNecessary: false) else {
                return
            }
            if self.swipeTrackedInitialOriginX == nil {
                self.swipeTrackedInitialOriginX = rowView.frame.origin.x
            }
            let initialX = self.swipeTrackedInitialOriginX!
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
                  let song = coord.queue[safe: swipeRemoveTargetRow]
            else {
                self.swipeRemoveTargetRow = -1
                return false
            }
            let row = self.swipeRemoveTargetRow
            self.swipeRemoveTargetRow = -1
            guard let rowView = self.rowView(atRow: row, makeIfNecessary: false) else {
                return false
            }

            let passed = CFAbsoluteTimeGetCurrent() >= self.swipeRemoveCooldownUntil
                && abs(accH) >= Self.swipeRemoveDeltaThreshold
                && abs(accH) > abs(accV)
                && row != coord.currentIndex

            if passed {
                let slideDirection: CGFloat = accH > 0 ? 1 : -1
                let targetX = initialX + slideDirection * rowView.bounds.width
                let videoId = song.videoId
                self.swipeRemoveCooldownUntil = CFAbsoluteTimeGetCurrent() + Self.swipeRemoveCooldown
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    var f = rowView.frame
                    f.origin.x = targetX
                    rowView.animator().frame = f
                    rowView.animator().alphaValue = 0
                } completionHandler: {
                    rowView.alphaValue = 1
                    var f = rowView.frame
                    f.origin.x = initialX
                    rowView.frame = f
                    coord.onRemove(videoId)
                }
                return true
            } else {
                // Cancel: animate row back to initial position.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    var f = rowView.frame
                    f.origin.x = initialX
                    rowView.animator().frame = f
                } completionHandler: {}
                return true
            }
        }

        if CFAbsoluteTimeGetCurrent() < self.swipeRemoveCooldownUntil { return false }
        guard abs(accH) >= Self.swipeRemoveDeltaThreshold,
              abs(accH) > abs(accV)
        else { return false }
        guard let coord = coordinator else { return false }
        let row = self.swipeRemoveTargetRow >= 0 ? self.swipeRemoveTargetRow : rowAtEnd
        self.swipeRemoveTargetRow = -1
        if row < 0 { return false }
        if row == coord.currentIndex { return false }
        guard let song = coord.queue[safe: row] else { return false }
        let slideDirection: CGFloat = accH > 0 ? 1 : -1
        self.swipeRemoveCooldownUntil = CFAbsoluteTimeGetCurrent() + Self.swipeRemoveCooldown
        coord.removeRowWithAnimation(row: row, song: song, slideDirection: slideDirection)
        return true
    }
}

// MARK: - QueueSidePanelHeader

@available(macOS 26.0, *)
private struct QueueSidePanelHeader: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        HStack {
            Text("Up Next")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Text("\(self.playerService.queue.count) songs")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                self.playerService.toggleQueueDisplayMode()
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close side panel")
            .accessibilityLabel("Close side panel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - QueueFooterActions

@available(macOS 26.0, *)
private struct QueueFooterActions: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        HStack(spacing: 12) {
            Button {
                self.playerService.undoQueue()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!self.playerService.canUndoQueue)
            .buttonStyle(.plain)

            Button {
                self.playerService.redoQueue()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!self.playerService.canRedoQueue)
            .buttonStyle(.plain)

            Button {
                self.playerService.shuffleQueue()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(self.playerService.queue.isEmpty)
            .buttonStyle(.plain)

            Button {
                Task {
                    if self.playerService.isPlaying {
                        await self.playerService.stop()
                    }
                    self.playerService.clearQueueEntirely()
                }
            } label: {
                Label("Clear", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .disabled(self.playerService.queue.isEmpty)
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview("Queue Side Panel") {
    let playerService = PlayerService()
    QueueSidePanelView()
        .environment(playerService)
        .environment(FavoritesManager.shared)
        .frame(height: 600)
}
