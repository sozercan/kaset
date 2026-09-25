import AppKit
import SwiftUI

// MARK: - QueueView

/// Right sidebar panel displaying the playback queue.
struct QueueView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(\.showCommandBar) private var showCommandBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drag: CompactQueueDrag?
    @State private var dragRegions: [UUID: CGRect] = [:]
    @State private var viewport = CGSize.zero
    @State private var scrollMetrics = CompactQueueScrollMetrics(offset: 0, maximum: 0)
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var suppressRowTap = false
    @State private var rejectedGesture = false
    @GestureState private var isDragging = false

    private static let rowHeight: CGFloat = 56
    private static let contentPadding: CGFloat = 8

    /// Namespace for glass effect morphing.
    @Namespace private var queueNamespace

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            VStack(spacing: 0) {
                // Header
                self.headerView

                Divider()
                    .opacity(0.3)

                // Content
                self.contentView
            }
            .frame(width: 280)
            .compatGlass(interactive: true, in: .rect(cornerRadius: 20))
            .compatGlassID("queuePanel", in: self.queueNamespace)
        }
        .compatGlassTransition(.materialize)
        .accessibilityIdentifier(AccessibilityID.Queue.container)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text(String(localized: "Up Next"))
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            // Clear queue button (only show if there are items beyond the current track)
            if self.playerService.queue.count > 1 {
                Button {
                    self.playerService.clearQueue()
                } label: {
                    Text(String(localized: "Clear"))
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Queue.clearButton)
            }

            Button {
                self.playerService.toggleQueueDisplayMode()
            } label: {
                Label(String(localized: "Edit"), systemImage: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open queue in side panel"))
            .accessibilityLabel(String(localized: "Open queue in side panel"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if self.playerService.queue.isEmpty {
            self.emptyQueueView
        } else {
            self.queueListView
        }
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

    private var presentationEntries: [QueueEntry] {
        let entries = self.playerService.queueEntries
        guard let drag = self.drag else { return entries }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return drag.session.previewIDs.compactMap { byID[$0] }
    }

    private var queueListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(self.presentationEntries.enumerated()), id: \.element.id) { index, entry in
                    self.queueRow(entry, index: index)
                        .frame(height: Self.rowHeight)
                        .opacity(self.drag?.session.sourceID == entry.id ? 0 : 1)
                        .overlay {
                            if self.drag?.session.sourceID == entry.id {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.red.opacity(0.06))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(.red.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                    }
                                    .padding(.horizontal, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.Queue.row(index: index))
                        .accessibilityAdjustableAction { direction in
                            self.moveAccessibly(entry, direction: direction)
                        }
                }
            }
            .padding(.vertical, Self.contentPadding)
            .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.15), value: self.drag?.session.destination)
        }
        .scrollPosition(self.$scrollPosition)
        .onScrollGeometryChange(for: CompactQueueScrollMetrics.self) { geometry in
            CompactQueueScrollMetrics(offset: geometry.contentOffset.y, maximum: max(0, geometry.contentSize.height - geometry.containerSize.height))
        } action: { _, metrics in
            self.scrollMetrics = metrics
            self.updateDestination()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { self.viewport = $0 }
        .coordinateSpace(name: "compactQueue")
        .onPreferenceChange(CompactQueueDragRegions.self) { self.dragRegions = $0 }
        // Recognize on the stable scroll container, not a lazy row that may be
        // recycled during edge scrolling or moved by the presentation preview.
        .simultaneousGesture(self.reorderGesture)
        .overlay(alignment: .topLeading) {
            if let drag = self.drag,
               let entry = self.playerService.queueEntries.first(where: { $0.id == drag.session.sourceID })
            {
                self.queueRow(entry, index: drag.session.destination, isPreview: true)
                    .frame(width: self.viewport.width, height: Self.rowHeight)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                    .offset(x: drag.location.x - drag.grabOffset.x, y: drag.location.y - drag.grabOffset.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
        .task(id: self.drag?.session.sourceID) { await self.trackDrag() }
        .task(id: self.isDragging) {
            guard !self.isDragging else { return }
            // GestureState also resets on system cancellation. Defer cleanup
            // until onEnded and any Button mouse-up action have been delivered.
            await Task.yield()
            guard !Task.isCancelled, !self.isDragging else { return }
            self.cancelDrag()
            self.rejectedGesture = false
            self.suppressRowTap = false
        }
        .onChange(of: self.playerService.queueEntryIDs) { self.cancelDrag() }
        .onChange(of: self.playerService.queueEntryIDOwningCurrentPlayback) { self.cancelDrag() }
        .onChange(of: self.playerService.playbackRequestGeneration) { self.cancelDrag() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in self.cancelDrag() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in self.cancelDrag() }
        .onDisappear { self.cancelDrag() }
        .accessibilityIdentifier(AccessibilityID.Queue.scrollView)
    }

    private func queueRow(_ entry: QueueEntry, index: Int, isPreview: Bool = false) -> some View {
        QueueRowView(
            song: entry.song,
            isCurrentTrack: entry.id == self.playerService.queueEntryIDOwningCurrentPlayback,
            index: index,
            isSuggested: entry.source == .suggested,
            allowsLikeActions: self.authService.hasPersonalAccount,
            favoritesManager: self.favoritesManager,
            playerService: self.playerService,
            dragRegionID: isPreview ? nil : entry.id,
            onRemove: { self.playerService.removeFromQueue(entryIDs: [entry.id]) },
            onTap: {
                guard !self.suppressRowTap else { return }
                let reservation = self.playerService.reserveMusicPlaybackIntent()
                Task { @MainActor in
                    guard let intent = self.playerService.claimMusicPlaybackIntent(reservation, queueEntryID: entry.id) else { return }
                    await self.playerService.playFromQueue(entryID: entry.id, intent: intent)
                }
            }
        )
    }

    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("compactQueue"))
            .updating(self.$isDragging) { _, state, _ in state = true }
            .onChanged { value in
                guard !self.rejectedGesture else { return }
                if self.drag == nil {
                    guard let region = self.dragRegions.first(where: { $0.value.contains(value.startLocation) }),
                          let session = CompactQueueReorderSession(
                              entryIDs: self.playerService.queueEntryIDs,
                              sourceID: region.key,
                              playbackOwnerID: self.playerService.queueEntryIDOwningCurrentPlayback
                          )
                    else {
                        self.rejectedGesture = true
                        return
                    }
                    self.suppressRowTap = true
                    self.drag = CompactQueueDrag(
                        session: session,
                        location: value.location,
                        grabOffset: CGPoint(x: value.startLocation.x, y: value.startLocation.y - region.value.minY + 8),
                        playbackGeneration: self.playerService.playbackRequestGeneration
                    )
                }
                self.drag?.location = value.location
                self.updateDestination()
            }
            .onEnded { value in
                self.drag?.location = value.location
                self.updateDestination()
                if let drag = self.drag,
                   self.isValid(drag),
                   CGRect(origin: .zero, size: self.viewport).contains(value.location),
                   drag.session.hasMoved
                {
                    self.playerService.reorderQueue(entryID: drag.session.sourceID, before: drag.session.beforeEntryID)
                }
                self.cancelDrag()
            }
    }

    private func isValid(_ drag: CompactQueueDrag) -> Bool {
        drag.session.isValid(entryIDs: self.playerService.queueEntryIDs, playbackOwnerID: self.playerService.queueEntryIDOwningCurrentPlayback)
            && drag.playbackGeneration == self.playerService.playbackRequestGeneration
    }

    private func updateDestination() {
        guard var drag = self.drag else { return }
        guard self.isValid(drag) else {
            self.cancelDrag()
            return
        }
        drag.session.update(contentY: drag.location.y + self.scrollMetrics.offset - Self.contentPadding, rowHeight: Self.rowHeight)
        if self.drag?.session.destination != drag.session.destination {
            self.drag = drag
        }
    }

    private func cancelDrag() {
        self.drag = nil
        if self.isDragging {
            self.rejectedGesture = true
        }
    }

    private func trackDrag() async {
        guard self.drag != nil else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated { self.cancelDrag() }
                return nil
            }
            return event
        }
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        while !Task.isCancelled, let drag = self.drag {
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard !Task.isCancelled, self.drag != nil else { return }
            let step = CompactQueueReorderSession.scrollStep(location: drag.location, viewport: self.viewport)
            let next = min(self.scrollMetrics.maximum, max(0, self.scrollMetrics.offset + step))
            if step != 0, abs(next - self.scrollMetrics.offset) > 0.1 {
                self.scrollPosition.scrollTo(y: next)
            }
        }
    }

    private func moveAccessibly(_ entry: QueueEntry, direction: AccessibilityAdjustmentDirection) {
        guard self.drag == nil,
              entry.id != self.playerService.queueEntryIDOwningCurrentPlayback,
              let index = self.playerService.queueEntryIDs.firstIndex(of: entry.id)
        else { return }
        let destination: Int
        switch direction {
        case .increment: destination = index + 1
        case .decrement: destination = index - 1
        @unknown default: return
        }
        let remaining = self.playerService.queueEntryIDs.filter { $0 != entry.id }
        guard destination >= 0, destination <= remaining.count else { return }
        self.playerService.reorderQueue(entryID: entry.id, before: remaining[safe: destination])
    }
}

// MARK: - QueueRowView

private struct QueueRowView: View {
    let song: Song
    let isCurrentTrack: Bool
    let index: Int
    let isSuggested: Bool
    let allowsLikeActions: Bool
    let favoritesManager: FavoritesManager
    let playerService: PlayerService
    let dragRegionID: UUID?
    let onRemove: () -> Void
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.onTap) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    // Now Playing indicator or track number
                    self.leadingIndicator
                        .frame(width: 24)

                    // Thumbnail
                    SongThumbnailView(song: self.song, size: 40, cornerRadius: 4)

                    // Track info
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(self.song.title)
                                .font(.system(size: 13, weight: self.isCurrentTrack ? .semibold : .regular))
                                .lineLimit(1)
                                .foregroundStyle(self.isCurrentTrack ? .red : .primary)
                            if self.song.isExplicit == true {
                                ExplicitBadge()
                            }
                        }

                        Text(self.song.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : self.song.artistsDisplay)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .background {
                    if let dragRegionID = self.dragRegionID {
                        GeometryReader { geometry in
                            Color.clear.preference(key: CompactQueueDragRegions.self, value: [dragRegionID: geometry.frame(in: .named("compactQueue"))])
                        }
                    }
                }

                // Favorite toggle
                LikeButton(song: self.song, isRowHovered: self.isHovering, allowsActions: self.allowsLikeActions)

                // Duration
                if let duration = song.duration {
                    Text(self.formatDuration(duration))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(self.backgroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.isHovering = hovering
        }
        .contextMenu {
            FavoritesContextMenu.menuItem(for: self.song, manager: self.favoritesManager)

            Divider()

            StartRadioContextMenu.menuItem(for: self.song, playerService: self.playerService)

            Divider()

            ShareContextMenu.menuItem(for: self.song)

            if !self.isCurrentTrack {
                Button(role: .destructive) {
                    self.onRemove()
                } label: {
                    Label(String(localized: "Remove from Queue"), systemImage: "minus.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if self.isCurrentTrack {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(self.playerService.isPlaying ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeating,
                    isActive: self.playerService.isPlaying
                )
        } else if self.isHovering {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else if self.isSuggested {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PackageResourceLookup.brandAccent)
                .accessibilityLabel(Text(String(localized: "Suggested")))
        } else {
            Text("\(self.index + 1)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private var backgroundColor: Color {
        if self.isCurrentTrack {
            return Color.red.opacity(0.1)
        } else if self.isHovering {
            return Color.primary.opacity(0.05)
        }
        return .clear
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - CompactQueueDrag

private struct CompactQueueDrag {
    var session: CompactQueueReorderSession
    var location: CGPoint
    let grabOffset: CGPoint
    let playbackGeneration: UInt64
}

// MARK: - CompactQueueScrollMetrics

private struct CompactQueueScrollMetrics: Equatable {
    let offset: CGFloat
    let maximum: CGFloat
}

// MARK: - CompactQueueDragRegions

private struct CompactQueueDragRegions: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

#Preview("Queue View") {
    let playerService = PlayerService()
    QueueView()
        .environment(playerService)
        .environment(FavoritesManager.shared)
        .frame(height: 600)
}

#Preview("Queue View with Items") {
    let playerService = PlayerService()
    // Note: In real use, queue would be populated via playQueue()
    QueueView()
        .environment(playerService)
        .environment(FavoritesManager.shared)
        .frame(height: 600)
}
