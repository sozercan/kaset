import SwiftUI

// MARK: - Main View

@available(macOS 26.0, *)
struct QueueSidePanelView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager

    var body: some View {
        // Note: Removed GlassEffectContainer to test drag-and-drop
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
                    }
                )
                .accessibilityIdentifier(AccessibilityID.Queue.scrollView)
            }

            Divider()
                .opacity(0.3)

            QueueFooterActions()
        }
        .frame(width: 350)
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
            onRemove: onRemove
        )
    }

    // MARK: - View Controller

    class QueueListViewController: NSViewController {
        var tableView: NSTableView?
        weak var coordinator: Coordinator?

        override func loadView() {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.backgroundColor = .clear
            scrollView.drawsBackground = false

            let tableView = NSTableView()
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
            column.maxWidth = 350
            tableView.addTableColumn(column)

            let dragType = NSPasteboard.PasteboardType("com.kaset.queueitem")
            tableView.registerForDraggedTypes([dragType, .string])
            tableView.verticalMotionCanBeginDrag = true

            scrollView.documentView = tableView
            self.tableView = tableView
            self.view = scrollView
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            if let tableView = tableView {
                tableView.delegate = coordinator
                tableView.dataSource = coordinator
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
        weak var viewController: QueueListViewController?
        var isDragging = false
        private let dragType = NSPasteboard.PasteboardType("com.kaset.queueitem")

        init(queue: [Song], currentIndex: Int, isPlaying: Bool, favoritesManager: FavoritesManager,
             onSelect: @escaping (Int) -> Void, onReorder: @escaping (Int, Int) -> Void, onRemove: @escaping (String) -> Void) {
            self.queue = queue
            self.currentIndex = currentIndex
            self.isPlaying = isPlaying
            self.favoritesManager = favoritesManager
            self.onSelect = onSelect
            self.onReorder = onReorder
            self.onRemove = onRemove
            super.init()
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
            // For moving down: use row directly (move API handles the shift)
            // For moving up: use row directly
            let destRow = row
            guard destRow != currentIndex && srcRow != destRow else { return [] }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let str = info.draggingPasteboard.string(forType: dragType),
                  let srcRow = Int(str) else { return false }
            // Use row directly - move(fromOffsets:toOffset:) handles the index adjustment
            let destRow = row
            guard srcRow != currentIndex && destRow != currentIndex && srcRow != destRow else { return false }
            onReorder(srcRow, destRow)
            isDragging = false
            return true
        }
    }
}

// MARK: - Cell View

@available(macOS 26.0, *)
class QueueTableCellView: NSView {
    private var onPlay: (() -> Void)?
    private let indicatorLabel = NSTextField()
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

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 12
        stackView.alignment = .centerY
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        indicatorLabel.isEditable = false
        indicatorLabel.isBordered = false
        indicatorLabel.backgroundColor = .clear
        indicatorLabel.alignment = .center
        indicatorLabel.font = NSFont.systemFont(ofSize: 12)
        indicatorLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true

        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = 4
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailImageView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        thumbnailImageView.heightAnchor.constraint(equalToConstant: 40).isActive = true

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

        stackView.addArrangedSubview(indicatorLabel)
        stackView.addArrangedSubview(thumbnailImageView)
        stackView.addArrangedSubview(infoStackView)
        stackView.addArrangedSubview(NSView())
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

    func configure(song: Song, index: Int, isCurrentTrack: Bool, isPlaying: Bool, favoritesManager: FavoritesManager, onPlay: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.onPlay = onPlay
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
        if isCurrentTrack {
            indicatorLabel.stringValue = isPlaying ? "♪" : "♪"
            indicatorLabel.textColor = isPlaying ? NSColor.systemRed : NSColor.tertiaryLabelColor
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        } else {
            indicatorLabel.stringValue = "\(index + 1)"
            indicatorLabel.textColor = NSColor.tertiaryLabelColor
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @objc private func handleClick() {
        onPlay?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailImageView.image = nil
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
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Switch to compact view")
            .accessibilityLabel("Switch to compact queue view")
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
                self.playerService.shuffleQueue()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(self.playerService.queue.isEmpty)
            .buttonStyle(.plain)

            Button {
                self.playerService.clearQueue()
            } label: {
                Label("Clear", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .disabled(self.playerService.queue.count <= 1)
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
