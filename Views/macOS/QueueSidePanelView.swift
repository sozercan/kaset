import SwiftUI

// MARK: - Main View

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
                emptyQueueView
            } else {
                QueueListControllerRepresentable(
                    queue: self.playerService.queue,
                    currentIndex: self.playerService.currentIndex,
                    isPlaying: self.playerService.isPlaying,
                    favoritesManager: self.favoritesManager,
                    onSelect: { index in
                        DiagnosticsLogger.ui.info("Queue row tapped: \(index)")
                        Task {
                            await self.playerService.playFromQueue(at: index)
                        }
                    },
                    onReorder: { source, destination in
                        DiagnosticsLogger.ui.info("Queue reorder requested: \(source) -> \(destination)")
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

// MARK: - NSViewController Representable

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
        context.coordinator.queue = queue
        context.coordinator.currentIndex = currentIndex
        context.coordinator.isPlaying = isPlaying
        context.coordinator.favoritesManager = favoritesManager

        if !context.coordinator.isDragging {
            viewController.tableView?.reloadData()
        }

        // Update current track highlighting and waveform animation
        if let tableView = viewController.tableView {
            for row in 0..<queue.count {
                if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueTableCellView {
                    cellView.updateAppearance(
                        isCurrentTrack: row == currentIndex,
                        isPlaying: isPlaying,
                        index: row
                    )
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            queue: queue,
            currentIndex: currentIndex,
            isPlaying: isPlaying,
            favoritesManager: favoritesManager,
            onSelect: onSelect,
            onReorder: onReorder,
            onRemove: onRemove,
            onStartRadio: onStartRadio
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
            scrollView.hasHorizontalScroller = false  // Disable horizontal scrolling
            scrollView.horizontalScrollElasticity = .none  // No horizontal bounce

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
            column.width = 350  // Matches container width minus scroll bar space
            tableView.addTableColumn(column)

            let dragType = NSPasteboard.PasteboardType("com.kaset.queueitem")
            tableView.registerForDraggedTypes([dragType, .string])
            tableView.verticalMotionCanBeginDrag = true
            tableView.draggingDestinationFeedbackStyle = .gap  // Show gap where item will be dropped

            scrollView.documentView = tableView
            self.tableView = tableView
            self.view = scrollView
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            if let tableView = tableView {
                tableView.delegate = coordinator
                tableView.dataSource = coordinator
                tableView.coordinator = coordinator
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
             onSelect: @escaping (Int) -> Void, onReorder: @escaping (Int, Int) -> Void, onRemove: @escaping (String) -> Void, onStartRadio: @escaping (Song) -> Void) {
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
                onRemove(song.videoId)
                return
            }
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else {
                onRemove(song.videoId)
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

        func numberOfRows(in tableView: NSTableView) -> Int {
            return queue.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cellView = QueueTableCellView()
            let song = queue[row]
            cellView.configure(
                song: song,
                index: row,
                isCurrentTrack: row == currentIndex,
                isPlaying: isPlaying,
                favoritesManager: favoritesManager,
                onPlay: { [weak self] in self?.onSelect(row) },
                onRemove: { [weak self] in self?.onRemove(song.videoId) }
            )
            return cellView
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            return 56
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            let selectedRow = tableView.selectedRow
            if selectedRow >= 0 {
                onSelect(selectedRow)
                tableView.deselectAll(nil)
            }
        }

        // Drag Source
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row != currentIndex else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(row), forType: dragType)
            isDragging = true
            return item
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            DiagnosticsLogger.ui.info("Queue drag: willBeginAt (\(screenPoint.x), \(screenPoint.y))")
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            DiagnosticsLogger.ui.info("Queue drag: endedAt (\(screenPoint.x), \(screenPoint.y)) op: \(operation.rawValue)")
            isDragging = false
        }

        // Drop Destination
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard dropOperation == .above else { return [] }
            guard let str = info.draggingPasteboard.string(forType: dragType),
                  let srcRow = Int(str) else { return [] }
            let destRow = row
            guard destRow != currentIndex && srcRow != destRow else { return [] }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let str = info.draggingPasteboard.string(forType: dragType),
                  let srcRow = Int(str) else { return false }
            let destRow = row
            guard srcRow != currentIndex && destRow != currentIndex && srcRow != destRow else { return false }
            onReorder(srcRow, destRow)
            isDragging = false
            return true
        }

        // MARK: - Context Menu

        func tableView(_ tableView: NSTableView, menuForRow row: Int, event: NSEvent) -> NSMenu? {
            guard row >= 0, let song = queue[safe: row] else { return nil }
            let menu = NSMenu()
            let manager = favoritesManager
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

            if row != currentIndex {
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
            let manager = favoritesManager
            MainActor.assumeIsolated { manager.toggle(song: song) }
        }

        @objc private func contextMenuStartRadio(_ sender: NSMenuItem) {
            guard let song = sender.representedObject as? Song else { return }
            onStartRadio(song)
        }

        @objc private func contextMenuShare(_ sender: NSMenuItem) {
            guard let song = sender.representedObject as? Song, let url = song.shareURL else { return }
            MainActor.assumeIsolated {
                ShareContextMenu.showSharePicker(for: url)
            }
        }

        @objc private func contextMenuRemove(_ sender: NSMenuItem) {
            guard let song = sender.representedObject as? Song else { return }
            onRemove(song.videoId)
        }
    }
}

// MARK: - Custom Table View with Drag Visual Feedback

@available(macOS 26.0, *)
class DraggableTableView: NSTableView {
    weak var coordinator: QueueListControllerRepresentable.Coordinator?

    /// Accumulated scroll deltas during the current gesture (used to detect swipe-to-remove).
    private var horizontalSwipeAccumulator: CGFloat = 0
    private var verticalSwipeAccumulator: CGFloat = 0
    /// Row index under the cursor when the gesture *started* (.began), so we remove that row even if content scrolls by .ended.
    private var swipeRemoveTargetRow: Int = -1
    /// Cooldown after a remove so we don't trigger again from leftover events.
    private var swipeRemoveCooldownUntil: CFAbsoluteTime = 0
    private static let swipeRemoveDeltaThreshold: CGFloat = 40
    private static let swipeRemoveCooldown: CFAbsoluteTime = 0.5

    override func awakeFromNib() {
        super.awakeFromNib()
        setupTable()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTable()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTable()
    }

    private func setupTable() {
        // Enable gap feedback style for drag-and-drop
        self.draggingDestinationFeedbackStyle = .gap
    }

    /// Two-finger horizontal trackpad swipe: only remove when the gesture *ends* with enough horizontal movement.
    /// One remove per gesture, with slide-out animation. Cooldown prevents multiple removes from one swipe.
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        switch event.phase {
        case .began:
            horizontalSwipeAccumulator = dx
            verticalSwipeAccumulator = dy
            swipeRemoveTargetRow = -1
            if let coord = coordinator {
                let point = event.locationInWindow
                let localPoint = self.convert(point, from: nil)
                let rowAtStart = self.row(at: localPoint)
                swipeRemoveTargetRow = rowAtStart
            }
        case .changed:
            horizontalSwipeAccumulator += dx
            verticalSwipeAccumulator += dy
        case .ended, .cancelled:
            let accH = horizontalSwipeAccumulator
            let accV = verticalSwipeAccumulator
            let point = event.locationInWindow
            let localPoint = self.convert(point, from: nil)
            let rowAtEnd = self.row(at: localPoint)
            horizontalSwipeAccumulator = 0
            verticalSwipeAccumulator = 0
            if CFAbsoluteTimeGetCurrent() < swipeRemoveCooldownUntil { break }
            guard abs(accH) >= Self.swipeRemoveDeltaThreshold,
                  abs(accH) > abs(accV)
            else { break }
            guard let coord = coordinator else { break }
            let row = swipeRemoveTargetRow >= 0 ? swipeRemoveTargetRow : rowAtEnd
            if row < 0 { break }
            if row == coord.currentIndex { break }
            guard let song = coord.queue[safe: row] else { break }
            let slideDirection: CGFloat = accH > 0 ? 1 : -1
            DiagnosticsLogger.ui.info("[SwipeRemove] remove row=\(row) title=\"\(song.title)\"")
            swipeRemoveCooldownUntil = CFAbsoluteTimeGetCurrent() + Self.swipeRemoveCooldown
            coord.removeRowWithAnimation(row: row, song: song, slideDirection: slideDirection)
            return
        default:
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                horizontalSwipeAccumulator = 0
                verticalSwipeAccumulator = 0
                swipeRemoveTargetRow = -1
            }
            break
        }

        super.scrollWheel(with: event)
    }
}

// MARK: - Cell View

@available(macOS 26.0, *)
class QueueTableCellView: NSView {
    private var onPlay: (() -> Void)?
    private var onRemove: (() -> Void)?
    private var isCurrentTrack: Bool = false
    private var isPlaying: Bool = false
    private var indicatorLabel = NSTextField()
    private var waveformView: NSView?
    private let thumbnailImageView = NSImageView()
    private let titleLabel = NSTextField()
    private let artistLabel = NSTextField()
    private let durationLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        // Fill the row view so layout is consistent when the table reuses row views (fixes misaligned rows).
        autoresizingMask = [.width, .height]

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 12
        stackView.alignment = .centerY
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)  // Reduced right padding
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Indicator container (for number or waveform) — keep fixed so long text doesn't shift row layout
        let indicatorContainer = NSView()
        indicatorContainer.translatesAutoresizingMaskIntoConstraints = false
        let indicatorWidth = indicatorContainer.widthAnchor.constraint(equalToConstant: 24)
        indicatorWidth.priority = .required
        indicatorWidth.isActive = true
        indicatorContainer.heightAnchor.constraint(equalToConstant: 20).isActive = true
        indicatorContainer.setContentHuggingPriority(.required, for: .horizontal)
        indicatorContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        indicatorLabel.isEditable = false
        indicatorLabel.isBordered = false
        indicatorLabel.backgroundColor = .clear
        indicatorLabel.alignment = .center
        indicatorLabel.font = NSFont.systemFont(ofSize: 12)
        indicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        indicatorContainer.addSubview(indicatorLabel)
        NSLayoutConstraint.activate([
            indicatorLabel.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            indicatorLabel.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor)
        ])

        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = 4
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailImageView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        thumbnailImageView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        thumbnailImageView.setContentHuggingPriority(.required, for: .horizontal)
        thumbnailImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let infoStackView = NSStackView()
        infoStackView.orientation = .vertical
        infoStackView.spacing = 2
        infoStackView.alignment = .leading

        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.backgroundColor = .clear
        titleLabel.lineBreakMode = .byTruncatingTail

        artistLabel.isEditable = false
        artistLabel.isBordered = false
        artistLabel.backgroundColor = .clear
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.font = NSFont.systemFont(ofSize: 11)
        artistLabel.textColor = NSColor.secondaryLabelColor

        infoStackView.addArrangedSubview(titleLabel)
        infoStackView.addArrangedSubview(artistLabel)

        durationLabel.isEditable = false
        durationLabel.isBordered = false
        durationLabel.backgroundColor = .clear
        durationLabel.alignment = .right
        durationLabel.font = NSFont.systemFont(ofSize: 11)
        durationLabel.textColor = NSColor.tertiaryLabelColor
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)  // Don't compress duration

        // Spacer takes all flexible space so title/artist and duration stay consistently aligned across rows
        let spacerView = NSView()
        spacerView.translatesAutoresizingMaskIntoConstraints = false
        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        infoStackView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)  // Truncate before spacer grows

        stackView.addArrangedSubview(indicatorContainer)
        stackView.addArrangedSubview(thumbnailImageView)
        stackView.addArrangedSubview(infoStackView)
        stackView.addArrangedSubview(spacerView)
        stackView.addArrangedSubview(durationLabel)

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickGesture)
    }

    override func layout() {
        super.layout()
        // Ensure we always fill the row view so reused rows don't keep a stale frame (fixes misaligned rows).
        if let sv = superview, !sv.bounds.isEmpty, frame != sv.bounds {
            frame = sv.bounds
        }
    }

    func configure(song: Song, index: Int, isCurrentTrack: Bool, isPlaying: Bool, favoritesManager: FavoritesManager, onPlay: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.onPlay = onPlay
        self.onRemove = onRemove
        self.isCurrentTrack = isCurrentTrack
        self.isPlaying = isPlaying
        updateAppearance(isCurrentTrack: isCurrentTrack, isPlaying: isPlaying, index: index)

        titleLabel.stringValue = song.title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: isCurrentTrack ? .semibold : .regular)
        titleLabel.textColor = isCurrentTrack ? NSColor.systemRed : NSColor.labelColor

        artistLabel.stringValue = song.artistsDisplay.isEmpty ? "Unknown Artist" : song.artistsDisplay

        if let duration = song.duration {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            durationLabel.stringValue = String(format: "%d:%02d", mins, secs)
        } else {
            durationLabel.stringValue = ""
        }

        if let url = song.thumbnailURL?.highQualityThumbnailURL {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data = data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { self?.thumbnailImageView.image = image }
            }.resume()
        } else {
            thumbnailImageView.image = nil
        }
    }

    func updateAppearance(isCurrentTrack: Bool, isPlaying: Bool, index: Int) {
        self.isCurrentTrack = isCurrentTrack
        self.isPlaying = isPlaying

        if isCurrentTrack {
            // Show animated waveform for current track
            indicatorLabel.stringValue = ""
            indicatorLabel.isHidden = true

            // Create or update waveform view
            if waveformView == nil {
                let waveView = WaveformView(frame: NSRect(x: 0, y: 0, width: 24, height: 16))
                waveView.translatesAutoresizingMaskIntoConstraints = false
                waveformView = waveView

                // Find indicator container and add waveform
                if let indicatorContainer = indicatorLabel.superview {
                    indicatorContainer.addSubview(waveView)
                    NSLayoutConstraint.activate([
                        waveView.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
                        waveView.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
                        waveView.widthAnchor.constraint(equalToConstant: 24),
                        waveView.heightAnchor.constraint(equalToConstant: 16)
                    ])
                }
            }

            if let waveView = waveformView as? WaveformView {
                waveView.isHidden = false
                waveView.isAnimating = isPlaying
                waveView.tintColor = isPlaying ? NSColor.systemRed : NSColor.tertiaryLabelColor
            }

            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        } else {
            // Show number for non-current tracks
            indicatorLabel.isHidden = false
            indicatorLabel.stringValue = "\(index + 1)"
            indicatorLabel.textColor = NSColor.tertiaryLabelColor

            // Hide waveform
            waveformView?.isHidden = true

            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @objc private func handleClick() {
        onPlay?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailImageView.image = nil
        waveformView?.removeFromSuperview()
        waveformView = nil
    }
}

// MARK: - Animated Waveform View

@available(macOS 26.0, *)
class WaveformView: NSView {
    var isAnimating: Bool = false {
        didSet {
            updateAnimation()
        }
    }
    var tintColor: NSColor = .systemRed {
        didSet {
            layer?.sublayers?.forEach { $0.backgroundColor = tintColor.cgColor }
        }
    }

    private var timer: Timer?
    private var bars: [CALayer] = []
    private var startTime: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBars()
    }

    private func setupBars() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Create 3 bars for the waveform
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 2
        let totalWidth = CGFloat(3) * barWidth + CGFloat(2) * barSpacing
        let startX = (bounds.width - totalWidth) / 2

        for i in 0..<3 {
            let bar = CALayer()
            bar.backgroundColor = tintColor.cgColor
            bar.cornerRadius = 1
            bar.frame = NSRect(
                x: startX + CGFloat(i) * (barWidth + barSpacing),
                y: bounds.height / 2 - 4,
                width: barWidth,
                height: 8
            )
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    private func updateAnimation() {
        if isAnimating {
            startAnimation()
        } else {
            stopAnimation()
            // Reset to static middle position
            for bar in bars {
                bar.frame.size.height = 8
                bar.frame.origin.y = (bounds.height - 8) / 2
            }
        }
    }

    private func startAnimation() {
        guard timer == nil else { return }

        startTime = CACurrentMediaTime()

        // Use Timer for 30fps animation - simpler and safer than CVDisplayLink
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
        // Add to common run loop modes to ensure it runs during tracking/dragging
        if let timer = timer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    private func updateBars() {
        guard isAnimating else { return }

        let elapsed = CACurrentMediaTime() - startTime
        let barHeights: [CGFloat] = [
            4 + 8 * CGFloat(abs(sin(elapsed * 4))),
            4 + 10 * CGFloat(abs(sin(elapsed * 3 + 1))),
            4 + 6 * CGFloat(abs(sin(elapsed * 5 + 2)))
        ]

        CATransaction.begin()
        CATransaction.setDisableActions(true)  // Disable implicit animations
        for (i, bar) in bars.enumerated() {
            let height = min(barHeights[i], bounds.height)
            bar.frame.size.height = height
            bar.frame.origin.y = (bounds.height - height) / 2
        }
        CATransaction.commit()
    }

    deinit {
        stopAnimation()
    }
}

// MARK: - Header

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

// MARK: - Footer

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
