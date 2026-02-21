# Queue Enhancement Feature Proposal

## Overview

This document details the proposed enhancements to the Queue (Up Next) feature in Kaset. The current implementation provides basic queue functionality but lacks advanced playlist management features that power users expect from a dedicated music client.

## Critique and Implementation Notes

### Strengths

- **Clear gap analysis** — Priorities (side panel, drag/drop, Play Next / Add to Bottom, Save as Playlist) match power-user expectations.
- **Phased delivery** — Side panel → drag/drop → context menus → Save as Playlist → polish is a good order; each phase has testable exit criteria.
- **Alignment with codebase** — Uses existing `PlayerService` queue APIs (`insertNextInQueue`, `appendToQueue`, `reorderQueue(videoIds:)`); proposes an index-based `reorderQueue(from:to:)` overload that fits List reordering.

### Issues and Corrections

1. **API Explorer (mandatory)**  
   Per AGENTS.md, before implementing **Save as Playlist** or **Add to Playlist**, the following must be explored with `Tools/api-explorer.swift` and documented in `docs/api-discovery.md`:
   - `playlist/create` — request/response shape, error codes (quota, auth).
   - `playlist/get_add_to_playlist` — structure of playlists returned for "Add to" menu.
   - `browse/edit_playlist` — how to add videos to an existing playlist.  
   Do not implement parsers or client methods from guesswork.

2. **`removeFromQueue` signature**  
   Existing API is `removeFromQueue(videoIds: Set<String>)`. Use `Set([song.videoId])` (or `[song.videoId] as Set`), not `[song.videoId]`, when calling from context menus.

3. **`insertNextInQueue` / `appendToQueue` are synchronous**  
   They are not `async`. Use `playerService.insertNextInQueue([song])` (and same for `appendToQueue`) directly; no `Task { await ... }` and no `await`. If UI must not block, wrap in `Task { @MainActor in ... }` without `await` on the call.

4. **`isCurrentTrack(song:)`**  
   Not present on `PlayerService`. Either add a helper (e.g. `currentTrack?.videoId == song.videoId` or `currentTrack?.id == song.id`) or use that expression inline in the context menu.

5. **YTMusicClient in sheets/menus**  
   `SaveQueueAsPlaylistSheet` and `AddToPlaylistMenu` need access to `YTMusicClient`. Prefer `@Environment(PlayerService.self)` and use `playerService.ytMusicClient` if exposed, or inject `YTMusicClient` via environment and document the requirement. Do not assume a global client.

6. **QueueRowView drag/drop and `PlayerService`**  
   The proposed `QueueRowView` uses `findSong(by:)` and `handleDrop`; it must have access to the current queue and reorder (e.g. `@Environment(PlayerService.self)`). Ensure the row does not capture a stale queue snapshot; read from `playerService.queue` at use time.

7. **Save as Playlist — task and cancellation**  
   The save button starts a `Task` and sets `isSaving = false` only in the `catch` block. On success, `dismiss()` is called without resetting `isSaving`. Prefer: store the task, set `isSaving = false` in both success and failure paths, and cancel the task on dismiss (or use a task that checks cancellation). Avoid fire-and-forget without error handling (AGENTS.md).

8. **ForEach identity**  
   Existing `QueueView` uses `ForEach(Array(queue.enumerated()), id: \.element.videoId)`. Prefer `id: \.element.id` if `Song.id` is the canonical stable identifier; otherwise document that `videoId` is unique in the queue.

9. **Toast feedback**  
   Phase 3 exit criteria mention "Toast feedback on action completion". The codebase may not have a shared toast system. Either add a short spec (e.g. transient message in player bar or a dedicated overlay) or mark toast as optional and drop it from exit criteria until a pattern exists.

10. **Reorder semantics**  
    The proposed `reorderQueue(from: IndexSet, to: Int)` should: (1) forbid moving the **current** track (source must not contain `currentIndex`); (2) forbid dropping onto the current track’s index if that would change which song is "now playing". The snippet’s `guard destination != currentIndex` is a start; also guard that `source` does not contain `currentIndex`.

### Additions

- **Accessibility** — Phase 2 exit criteria should explicitly require VoiceOver labels for the drag handle (e.g. "Reorder, song title") and for drop targets. Phase 5 already mentions VoiceOver; ensure drag/drop is covered.
- **Clear confirmation** — Phase 5 says "Clear shows confirmation for >10 items". Align with existing `QueueView` behavior (destructive "Clear" without confirmation); if adding confirmation, specify copy (e.g. "Clear 12 songs from queue?") and destructive action.
- **Queue persistence** — Recommend as a **follow-up** (see [Queue persistence and undo](#queue-persistence-and-undo-follow-up) below). Use file-based JSON in Application Support (same pattern as `FavoritesManager`); no SQLite needed for a small history.

### Removals / Simplifications

- **`QueueContextMenu(song: nil)` on header** — The header context menu with "Shuffle Queue" / "Clear Queue" is redundant if the footer already has those actions; consider removing the header context menu or keeping it for power users. Not a removal from the doc, but an optional simplification.
- **`lastQueueAction` / `queueActionTimestamp`** — The "Queue intent tracking for UI feedback" state is unused in the spec. Either remove from the proposal or add one sentence on how it will drive UI (e.g. toast or inline message). Removed from the proposed state below to avoid dead code.

### Optional: Side panel vs overlay

- The plan uses "popup" vs "side panel". Today the queue is already shown in the **right sidebar overlay** in `MainWindow`. Clarify whether "side panel" is (a) a different **view** in the same overlay (e.g. wider, with drag/drop), or (b) a separate **NavigationSplitView** column. If (a), the toggle simply swaps `QueueView` (compact) vs `QueueSidePanelView` (full) in the same overlay; if (b), layout and navigation changes are required.

---

## Current State Analysis

### Existing Functionality

| Feature | Status | Implementation |
|---------|--------|----------------|
| Play queue from index | ✅ Working | `PlayerService+Queue.swift:197-205` |
| Play with Radio/Mix | ✅ Working | `PlayerService+Queue.swift:22-79` |
| Append to queue | ✅ Working | `PlayerService+Queue.swift:284-288` |
| Insert after current | ✅ Working | `PlayerService+Queue.swift:209-214` |
| Remove from queue | ✅ Working | `PlayerService+Queue.swift:218-232` |
| Reorder queue | ✅ Working | `PlayerService+Queue.swift:236-260` |
| Shuffle queue | ✅ Working | `PlayerService+Queue.swift:263-280` |
| Clear queue | ✅ Working | `PlayerService+Queue.swift:181-194` |
| Queue popup UI | ✅ Working | `QueueView.swift` |

### Gaps Identified

| Gap | Impact | Priority |
|-----|--------|----------|
| No side panel mode | Limited visibility for queue management | High |
| No drag/drop reordering | Manual reorder tedious for large queues | High |
| No "Play next" context menu | Users can't easily queue songs for immediate play | High |
| No "Add to bottom" context menu | Can't build queue while browsing | High |
| No "Save as Playlist" | Can't persist queue for later | Medium |
| Queue opens as popup only | Limits discoverability of features | Medium |

### Current Queue Data Model

**PlayerService State** (`Core/Services/Player/PlayerService.swift:79-84`):
```swift
@MainActor
@Observable
class PlayerService {
    var queue: [Song] = []
    var currentIndex: Int = 0
    var showQueue: Bool = false  // Controls popup visibility
}
```

**Song Model** (`Core/Models/Song.swift:6-71`):
```swift
struct Song: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let artists: [Artist]
    let album: Album?
    let duration: TimeInterval?
    let thumbnailURL: URL?
    let videoId: String
}
```

---

## Proposed Architecture

### New Queue Mode System

Introduce a `QueueDisplayMode` enum to support both popup and side panel modes:

```swift
enum QueueDisplayMode: String, Codable, CaseIterable, Sendable {
    case popup
    case sidepanel

    var displayName: String {
        switch self {
        case .popup: return "Popup"
        case .sidepanel: return "Side Panel"
        }
    }

    var description: String {
        switch self {
        case .popup: return "Compact overlay view"
        case .sidepanel: return "Full-width panel with reordering"
        }
    }
}
```

### Extended PlayerService State

```swift
@MainActor
@Observable
class PlayerService {
    // ... existing state ...
    var queueDisplayMode: QueueDisplayMode = .popup
    var isSidePanelPresented: Bool = false

    /// Returns true if the given song is the current track.
    func isCurrentTrack(_ song: Song) -> Bool {
        currentTrack?.videoId == song.videoId
    }

    func toggleQueueDisplayMode() {
        if queueDisplayMode == .popup {
            queueDisplayMode = .sidepanel
            isSidePanelPresented = true
        } else {
            queueDisplayMode = .popup
            isSidePanelPresented = false
        }
    }
}
```

---

## Feature Specifications

### 1. Side Panel Mode

#### UI Implementation

**New `QueueSidePanelView.swift`**:

```swift
struct QueueSidePanelView: View {
    @Environment(PlayerService.self) var playerService
    @State private var draggedSong: Song?
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            QueueSidePanelHeader(isPresented: $isPresented)

            Divider()

            // Queue list with drag/drop
            QueueListView(
                songs: playerService.queue,
                currentIndex: playerService.currentIndex,
                draggedSong: $draggedSong,
                onReorder: handleReorder,
                onPlayAt: playerService.playFromQueue(at:)
            )

            Divider()

            // Footer actions
            QueueFooterActions()
        }
        .frame(width: 350)
        .glassEffect(.regular, in: .rect)
    }

    private func handleReorder(from source: IndexSet, to destination: Int) {
        playerService.reorderQueue(from: source, to: destination)
    }
}
```

#### Header Component

```swift
struct QueueSidePanelHeader: View {
    @Environment(PlayerService.self) var playerService
    @Binding var isPresented: Bool
    @State private var showingClearConfirmation = false

    var body: some View {
        HStack {
            Text("Up Next")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            // Song count
            Text("\(playerService.queue.count) songs")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Collapse button
            Button {
                isPresented = false
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .contextMenu {
            QueueContextMenu(song: nil)
        }
    }
}
```

#### Footer Actions Component

```swift
struct QueueFooterActions: View {
    @Environment(PlayerService.self) var playerService
    @State private var showingSaveDialog = false

    var body: some View {
        HStack(spacing: 12) {
            // Shuffle
            Button {
                playerService.shuffleQueue()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(playerService.queue.isEmpty)

            // Clear
            Button(role: .destructive) {
                playerService.clearQueue()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(playerService.currentIndex >= playerService.queue.count - 1)

            // Save as Playlist
            Button {
                showingSaveDialog = true
            } label: {
                Label("Save as Playlist", systemImage: "plus.square.on.square")
            }
            .disabled(playerService.queue.isEmpty)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingSaveDialog) {
            SaveQueueAsPlaylistSheet()
        }
    }
}
```

---

### 2. Drag and Drop Reordering

#### QueueRowView Enhancement

Extend existing `QueueRowView` (`QueueView.swift:124-242`) with draggable capability:

```swift
struct QueueRowView: View {
    let song: Song
    let index: Int
    let isCurrentTrack: Bool
    @Binding var draggedSong: Song?

    var body: some View {
        HStack(spacing: 12) {
            // Drag handle (only visible in side panel mode)
            if !isCurrentTrack {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .draggable(song.id) {
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                            songRowContent
                        }
                        .padding(8)
                        .background(.quaternary)
                        .clipShape(.rect(cornerRadius: 8))
                    }
            } else {
                Spacer()
                    .frame(width: 20)
            }

            songRowContent

            Spacer()

            // Context menu trigger
            contextMenuButton
        }
        .contentShape(.rect)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .hoverEffect(.highlight)
        .background(isCurrentTrack ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(.rect(cornerRadius: 8))
        .dropDestination(for: String.self) { droppedIds, _ in
            guard let droppedId = droppedIds.first,
                  let droppedSong = findSong(by: droppedId) else {
                return false
            }
            handleDrop(droppedSong, onto: song)
            return true
        }
    }

    @ViewBuilder
    private var songRowContent: some View {
        // Thumbnail
        AsyncImage(url: song.thumbnailURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.tertiary)
        }
        .frame(width: 44, height: 44)
        .clipShape(.rect(cornerRadius: 6))

        // Title and artist
        VStack(alignment: .leading, spacing: 2) {
            Text(song.title)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(isCurrentTrack ? .primary : .primary)

            Text(song.artists.map(\.name).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        Spacer()

        // Duration
        if let duration = song.duration {
            Text(formatDuration(duration))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }

        // Now playing indicator
        if isCurrentTrack {
            WaveformView()
                .frame(width: 20, height: 20)
        }
    }

    @ViewBuilder
    private var contextMenuButton: some View {
        Button {
            // Show context menu via NSMenu
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .popover(isPresented: .constant(false)) {
            EmptyView()
        }
        .contextMenu {
            QueueContextMenu(song: song)
        }
    }

    private func handleDrop(droppedSong: Song, onto targetSong: Song) {
        // Calculate new index and trigger reorder
        guard let droppedIndex = playerService.queue.firstIndex(where: { $0.id == droppedSong.id }),
              let targetIndex = playerService.queue.firstIndex(where: { $0.id == targetSong.id }) else {
            return
        }

        let adjustedTarget = targetIndex > droppedIndex ? targetIndex - 1 : targetIndex
        playerService.reorderQueue(from: IndexSet(integer: droppedIndex), to: adjustedTarget)
    }
}
```

#### Reorder Service Integration

```swift
extension PlayerService {
    func reorderQueue(from source: IndexSet, to destination: Int) {
        guard !source.contains(currentIndex) else {
            DiagnosticsLogger.logWarning("Cannot reorder: cannot move current track")
            return
        }
        guard destination != currentIndex else {
            DiagnosticsLogger.logWarning("Cannot reorder: destination is current track")
            return
        }

        var newQueue = queue
        newQueue.move(fromOffsets: source, toOffset: destination)

        // Adjust currentIndex if needed
        let oldCurrent = queue[currentIndex]
        if let newCurrentIndex = newQueue.firstIndex(where: { $0.id == oldCurrent.id }) {
            currentIndex = newCurrentIndex
        }

        queue = newQueue
        DiagnosticsLogger.logInfo("Queue reordered: moved from \(source) to \(destination)")
    }
}
```

---

### 3. Context Menu Actions

#### New "Play Next" Action

Add to `SongActionsHelper.swift` or create new `QueueActionsHelper.swift`:

```swift
@MainActor
func playNext(song: Song, playerService: PlayerService) {
    playerService.insertNextInQueue([song])
    DiagnosticsLogger.logInfo("Play next: \(song.title)")
}

@MainActor
func addToBottom(song: Song, playerService: PlayerService) {
    playerService.appendToQueue([song])
    DiagnosticsLogger.logInfo("Added to bottom: \(song.title)")
}
```

#### Extended SongContextMenu

```swift
struct QueueContextMenu: View {
    let song: Song?
    @Environment(PlayerService.self) var playerService

    var body: some View {
        if let song = song {
            // Play Next
            Button {
                playerService.insertNextInQueue([song])
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }

            // Add to Bottom
            Button {
                playerService.appendToQueue([song])
            } label: {
                Label("Add to Bottom of Queue", systemImage: "plus")
            }

            Divider()

            // Play Radio from here
            StartRadioContextMenu(song: song)

            Divider()

            // Save to Playlist
            AddToPlaylistMenu(song: song)

            Divider()

            // Existing: Favorites
            FavoritesContextMenu(song: song)

            // Existing: Like/Dislike
            LikeDislikeContextMenu(song: song)

            Divider()

            // Remove from Queue (only if not current)
            if !playerService.isCurrentTrack(song) {
                Button(role: .destructive) {
                    playerService.removeFromQueue(videoIds: Set([song.videoId]))
                } label: {
                    Label("Remove from Queue", systemImage: "trash")
                }
            }

            Divider()

            // Share
            ShareContextMenu(song: song)
        } else {
            // Queue header context menu
            Button {
                playerService.shuffleQueue()
            } label: {
                Label("Shuffle Queue", systemImage: "shuffle")
            }

            Button(role: .destructive) {
                playerService.clearQueue()
            } label: {
                Label("Clear Queue", systemImage: "trash")
            }
        }
    }
}
```

#### Add to Playlist Menu

```swift
struct AddToPlaylistMenu: View {
    let song: Song
    @Environment(PlayerService.self) var playerService
    @State private var playlists: [Playlist] = []
    @State private var showingCreateDialog = false

    var body: some View {
        Menu("Add to Playlist") {
            ForEach(playlists) { playlist in
                Button {
                    Task { await addToPlaylist(playlist) }
                } label: {
                    Label(playlist.title, systemImage: "music.note.list")
                }
            }

            Divider()

            Button {
                showingCreateDialog = true
            } label: {
                Label("New Playlist...", systemImage: "plus")
            }
        }
        .task {
            await loadPlaylists()
        }
        .sheet(isPresented: $showingCreateDialog) {
            CreatePlaylistSheet(songToAdd: song)
        }
    }

    private func loadPlaylists() async {
        guard let client = playerService.ytMusicClient else { return }
        do {
            playlists = try await client.fetchUserPlaylists()
        } catch {
            DiagnosticsLogger.logError("Failed to load playlists: \(error)")
        }
    }

    private func addToPlaylist(_ playlist: Playlist) async {
        guard let client = playerService.ytMusicClient else { return }
        do {
            try await client.addToPlaylist(playlistId: playlist.id, videoIds: [song.videoId])
            DiagnosticsLogger.logInfo("Added \(song.title) to \(playlist.title)")
        } catch {
            DiagnosticsLogger.logError("Failed to add to playlist: \(error)")
        }
    }
}
```

---

### 4. Save Queue as Playlist

#### API Integration

```swift
extension YTMusicClient {
    func createPlaylist(title: String, videoIds: [String], description: String = "", privacyStatus: String = "PRIVATE") async throws {
        let body: [String: Any] = [
            "title": title,
            "description": description,
            "privacyStatus": privacyStatus,
            "videoIds": videoIds
        ]
        let response = try await Self.request("playlist/create", body: body)
        DiagnosticsLogger.logInfo("Created playlist: \(title) with \(videoIds.count) songs")
        return response
    }
}
```

#### Save Dialog

```swift
struct SaveQueueAsPlaylistSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(PlayerService.self) var playerService
    @State private var playlistName = ""
    @State private var privacyStatus = "PRIVATE"
    @State private var isSaving = false
    @State private var error: Error?

    var body: some View {
        VStack(spacing: 20) {
            Text("Save Queue as Playlist")
                .font(.headline)

            TextField("Playlist Name", text: $playlistName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            Picker("Privacy", selection: $privacyStatus) {
                Text("Private").tag("PRIVATE")
                Text("Unlisted").tag("UNLISTED")
                Text("Public").tag("PUBLIC")
            }
            .pickerStyle(.segmented)

            if let error = error {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Save") {
                    savePlaylist()
                }
                .keyboardShortcut(.return)
                .disabled(playlistName.isEmpty || isSaving)
            }
        }
        .padding()
        .frame(width: 400)
        .task {
            // Pre-fill with timestamp
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            playlistName = "Queue \(formatter.string(from: Date()))"
        }
    }

    private func savePlaylist() {
        isSaving = true
        Task { @MainActor in
            do {
                let videoIds = playerService.queue.map(\.videoId)
                guard let client = self.playerService.ytMusicClient else {
                    self.error = YTMusicError.authExpired
                    self.isSaving = false
                    return
                }
                try await client.createPlaylist(
                    title: playlistName,
                    videoIds: videoIds,
                    privacyStatus: privacyStatus
                )
                self.isSaving = false
                dismiss()
            } catch {
                self.error = error
                self.isSaving = false
            }
        }
    }
}
```

---

### 5. Queue Persistence

Add persistence for queue display mode and expanded state:

```swift
extension UserDefaults {
    private enum Keys {
        static let queueDisplayMode = "kaset.queue.displayMode"
        static let queueExpanded = "kaset.queue.expanded"
    }

    var queueDisplayMode: QueueDisplayMode {
        get {
            guard let raw = string(forKey: Keys.queueDisplayMode),
                  let mode = QueueDisplayMode(rawValue: raw) else {
                return .popup
            }
            return mode
        }
        set {
            set(newValue.rawValue, forKey: Keys.queueDisplayMode)
        }
    }

    var queueExpanded: Bool {
        get { bool(forKey: Keys.queueExpanded) }
        set { set(newValue, forKey: Keys.queueExpanded) }
    }
}
```

---

## Implementation Phases

### Phase 1: Side Panel Foundation

**Deliverables:**
- `QueueDisplayMode` enum and state management
- `QueueSidePanelView` scaffold with header/footer
- Toggle button to switch between popup and side panel
- State persistence

**Exit Criteria:**
- [ ] Toggle button appears in QueueView header
- [ ] Side panel opens with correct width (350pt) and glass effect
- [ ] Switching modes persists across app restarts
- [ ] Build succeeds with `xcodebuild -scheme Kaset -destination 'platform=macOS' build`

---

### Phase 2: Drag and Drop Reordering

**Deliverables:**
- `draggable()` modifier on QueueRowView
- `dropDestination()` for reordering
- Visual feedback during drag (opacity change, scale)
- Current track exclusion from drag (can't move playing song)

**Exit Criteria:**
- [ ] Drag handle visible on non-current songs in side panel
- [ ] Songs can be reordered via drag
- [ ] Current track cannot be dragged; reorder cannot drop onto current index
- [ ] Animation smooth on drop
- [ ] VoiceOver: drag handle has accessibility label (e.g. "Reorder, [song title]")
- [ ] Unit tests pass for `reorderQueue(from:to:)` logic

---

### Phase 3: Context Menu Actions

**Deliverables:**
- "Play Next" action in all song context menus
- "Add to Bottom of Queue" action in all song context menus
- Integration with existing context menu infrastructure
- Toast feedback on action completion

**Exit Criteria:**
- [ ] "Play Next" appears in LibraryView, SearchView, HomeView song lists
- [ ] "Add to Bottom" appears in same locations
- [ ] Both actions work from QueueView (side panel) context menu
- [ ] Optional: toast/notification feedback (if a shared toast pattern exists; otherwise omit)
- [ ] `swiftlint --strict && swiftformat .` passes

---

### Phase 4: Save as Playlist

**Prerequisite:** API Explorer run for `playlist/create`; response and error handling documented in `docs/api-discovery.md`.

**Deliverables:**
- "Save as Playlist" button in side panel footer
- SaveQueueAsPlaylistSheet dialog
- `createPlaylist` API integration (after endpoint verified)
- Error handling for quota exceeded, network failure, auth expired

**Exit Criteria:**
- [ ] Button disabled when queue empty
- [ ] Dialog allows naming and privacy selection
- [ ] Playlist created successfully in YouTube Music
- [ ] Error shown if playlist creation fails

---

### Phase 5: Queue Footer Actions Polish

**Deliverables:**
- Shuffle queue (already exists, wire to footer)
- Clear queue confirmation if non-destructive
- Animation polish for queue operations
- Accessibility labels for VoiceOver

**Exit Criteria:**
- [ ] Footer actions accessible via keyboard
- [ ] Shuffle maintains current track position
- [ ] Clear shows confirmation for >10 items
- [ ] VoiceOver announces queue changes

---

## File Changes Summary

### New Files

| File | Purpose |
|------|---------|
| `Views/macOS/QueueSidePanelView.swift` | Side panel container |
| `Views/macOS/QueueRowView+Drag.swift` | Drag/drop modifiers for rows |
| `Views/macOS/QueueFooterActions.swift` | Footer with Shuffle/Save/Clear |
| `Views/macOS/QueueContextMenu+Actions.swift` | Extended context menu |
| `Views/macOS/AddToPlaylistMenu.swift` | Add to playlist submenu |
| `Views/macOS/SaveQueueAsPlaylistSheet.swift` | Save dialog |
| `Views/macOS/QueueSidePanelHeader.swift` | Side panel header |

### Modified Files

| File | Changes |
|------|---------|
| `Core/Services/Player/PlayerService.swift` | Add `queueDisplayMode`, `isSidePanelPresented` |
| `Core/Services/Player/PlayerService+Queue.swift` | Add `reorderQueue(from:to:)` overload |
| `Views/macOS/QueueView.swift` | Add toggle button, header improvements |
| `Views/macOS/SharedViews/QueueRowView.swift` | Add draggable, new layout options |
| `Views/macOS/SharedViews/SongActionsHelper.swift` | Add `playNext`, `addToBottom` |

---

## Testing Strategy

### Unit Tests (Swift Testing)

```swift
@Suite
struct QueueReorderTests {
    @Test func reorderQueue_maintainsCurrentTrack() {
        let service = PlayerService()
        service.queue = [song1, song2, song3]
        service.currentIndex = 1  // song2

        service.reorderQueue(from: IndexSet(integer: 0), to: 2)

        #expect(service.currentIndex == 1)  // Unchanged
        #expect(service.queue == [song2, song3, song1])
    }

    @Test func reorderQueue_fromCurrentIndex_failsGracefully() {
        let service = PlayerService()
        service.queue = [song1, song2, song3]
        service.currentIndex = 0

        service.reorderQueue(from: IndexSet(integer: 0), to: 1)

        #expect(service.queue == [song1, song2, song3])  // Unchanged
    }
}
```

### Integration Tests

- [ ] Queue persists when app relaunches
- [ ] Side panel mode persists
- [ ] Context menu actions work from all song lists
- [ ] Drag reordering works with 50+ songs
- [ ] Save as playlist creates correctly named playlist

---

## API Dependencies

| Feature | Endpoint | Auth Required |
|---------|----------|---------------|
| Save as Playlist | `playlist/create` | ✅ Yes |
| Add to Playlist | `browse/edit_playlist` | ✅ Yes |
| Fetch Playlists | `playlist/get_add_to_playlist` | ✅ Yes |

No new API endpoints required—all features use existing YouTube Music API.

**Before implementing Phase 4 (Save as Playlist) or Add to Playlist menu:** Run `./Tools/api-explorer.swift` to exercise `playlist/create`, `playlist/get_add_to_playlist`, and `browse/edit_playlist`; document request/response shapes and errors in `docs/api-discovery.md`. Do not implement client methods or parsers from guesswork (see AGENTS.md).

---

## Performance Considerations

1. **Queue Rendering**: Use `LazyVStack` for queue list (already in place)
2. **Drag Performance**: Debounce rapid reorder operations
3. **Context Menu**: Load playlists asynchronously to not block menu opening
4. **Memory**: Queue is typically <100 songs; no pagination needed

---

## Accessibility

- All actions keyboard accessible (shortcuts in menu)
- VoiceOver labels on drag handles
- Dynamic type support for text sizes
- Focus ring on keyboard navigation

---

## Open Questions and Recommendations

1. **Queue persist across app restarts?** **Recommendation: Implement as follow-up.** See [Queue persistence and undo](#queue-persistence-and-undo-follow-up) for a file-based design (no SQLite). Restore on launch + "Restore previous queue" (undo) with a history of 3 queues is feasible and matches common macOS patterns.

2. **"Play Next" auto-expand the queue panel?** Optional UX polish: when the user chooses "Play Next" from a list, consider briefly opening or highlighting the queue (e.g. set `showQueue = true`) so they see the result. Not required for Phase 3.

3. **Shuffle affect current track?** Current implementation keeps the current track at the front (index 0). **Recommendation: keep as-is** — matches common expectations (now playing stays, rest shuffle).

4. **"Save as Playlist" — full queue or pending only?** **Recommendation: save full queue** (all `playerService.queue` by default). Optionally in a later iteration, add a control to "Save only upcoming" (songs after `currentIndex`). Document the chosen behavior in the Save sheet (e.g. "Saves all X songs in the queue").

---

## Queue persistence and undo (follow-up)

Persisting the queue across app restarts and offering **"Restore previous queue"** (undo) when the user accidentally replaces the queue is feasible without a database. The recommended approach is **file-based storage** in Application Support, matching the existing `FavoritesManager` pattern. SQLite is unnecessary for a single current queue plus a small history of 3 snapshots.

### Why file-based (JSON) instead of SQLite?

| Approach | Typical use on macOS | For queue + 3 history |
|--------|-----------------------|------------------------|
| **JSON/PropertyList in Application Support** | App state, last-used data, small lists | ✅ Ideal: one file for "last queue", one for "history" (or combined). No schema, Codable, same pattern as `FavoritesManager`. |
| **UserDefaults** | Preferences, small key-value | Possible but better to keep prefs separate from "documents"; Application Support is clearer. |
| **SQLite** | Large datasets, search, relations | Overkill for 3 queue snapshots; adds dependency or C API usage. Common in Mail, Safari, etc., not for tiny state. |
| **SwiftData / Core Data** | Rich object graphs, many entities | Heavier than needed for a few arrays of songs. |

**Conclusion:** Use **Application Support + JSON** (Codable). It’s the most common simple storage for this kind of state in macOS apps and keeps the implementation minimal.

### Two features

1. **Persistence** — Save the current queue (and `currentIndex`) when the app goes to background or terminates; restore on next launch so the user resumes with the same queue.
2. **Undo ("Restore previous queue")** — Keep a **history of the last 3 queues**. Whenever something *replaces* the queue (e.g. Play Album, Play Radio, Play Mix, or Clear), push the current queue into history (if it’s worth keeping) before replacing. Expose a "Restore previous queue" action (toolbar, queue header, or menu) that restores the most recent history entry and removes it from history. No need for a separate "redo" unless you want "restore next" in a stack; "last 3" usually means restore #1, then #2, then #3.

### When to push current queue to history

Push the current queue to history **only when it is about to be replaced** (and is non-empty and not already identical to the new queue). Hook into:

- `playQueue(_:startingAt:)` — before `self.queue = songs`
- `playWithRadio(song:)` — before `self.queue = [song]`
- `playWithMix(playlistId:startVideoId:)` — before setting the new queue
- `clearQueue()` — when the queue has more than one item (so "clear" replaces a real queue)

Do **not** push to history on: `appendToQueue`, `insertNextInQueue`, `reorderQueue`, `shuffleQueue`, or when only fetching more mix songs (queue is extended, not replaced).

### Data model (minimal snapshot)

Store enough to restore the list and, if desired, re-fetch metadata later. For example:

```swift
struct PersistedQueueSnapshot: Codable {
    var songs: [PersistedSong]
    var currentIndex: Int
    var savedAt: Date

    struct PersistedSong: Codable {
        var id: String
        var videoId: String
        var title: String
        var artistsDisplay: String  // or [String]; minimal for display
        var duration: TimeInterval?
        var thumbnailURL: URL?
    }
}
```

Build `PersistedSong` from `Song` (or a subset of fields). On restore, either use these as the in-memory queue (if `Song` can be created from them) or use `videoId` to re-fetch metadata from the API when needed.

### File layout (Application Support)

- **Current queue (persist across restarts):**  
  `~/Library/Application Support/Kaset/queue_current.json`  
  Single `PersistedQueueSnapshot` (or equivalent) for the current queue + `currentIndex`. Save on resign active / terminate; load on launch.

- **Undo history (last 3 queues):**  
  `~/Library/Application Support/Kaset/queue_history.json`  
  Array of up to 3 `PersistedQueueSnapshot` values (newest first). Before any "replace queue" action, push current snapshot to this array (trim to 3); on "Restore previous queue", pop the first and apply it, then save.

Reuse the same `Application Support/Kaset` directory and `FileManager` patterns as `FavoritesManager` and `WebKitManager` (create directory if needed, write atomically if desired).

### Undo UI

- **Placement:** Queue side-panel header, or PlayerBar/queue popup: a "Restore previous queue" button (e.g. arrow.uturn.backward) and/or menu item.
- **State:** Enable only when `queueHistory.count > 0`. Optional: show "Restore previous queue (3 available)" in a tooltip.
- **Keyboard:** Optional shortcut (e.g. ⌘Z in queue context or a dedicated shortcut).

### Edge cases

- **Empty or single-song queue:** Optionally do not push to history when the current queue is empty or has one item, to avoid cluttering history with trivial states.
- **Stale tracks:** Restored songs might be deleted or private later. Restore by `videoId`; if playback or metadata fetch fails, show "Unavailable" or skip that item and keep the rest.
- **Launch with no file:** If `queue_current.json` is missing, keep default empty queue (current behavior).

### Implementation outline (follow-up phase)

1. Add `PersistedQueueSnapshot` (and `PersistedSong`) to Core/Models or a dedicated QueuePersistence module.
2. Add a `QueuePersistenceService` (or extend `PlayerService`) that:
   - Reads/writes `queue_current.json` and `queue_history.json` under Application Support.
   - Exposes `loadCurrentQueue()`, `saveCurrentQueue()`, `pushCurrentToHistory()`, `restorePreviousQueue()` (and optionally `canRestorePreviousQueue`).
3. In `PlayerService`, before each queue-replacing call, invoke `pushCurrentToHistory()` (if queue is non-empty and not already matching). After replacing, call `saveCurrentQueue()`. On app init, call `loadCurrentQueue()` and apply if valid.
4. Subscribe to `NSApplication.willTerminate` / `scenePhase` (or equivalent) to save current queue when app backgrounds or quits.
5. Add "Restore previous queue" to the queue UI and wire to `restorePreviousQueue()`.

This keeps persistence and undo simple, consistent with the rest of the app, and avoids any database dependency.

---

## Timeline Estimate

| Phase | Estimated Time |
|-------|----------------|
| Phase 1: Side Panel Foundation | 2-3 days |
| Phase 2: Drag and Drop | 2-3 days |
| Phase 3: Context Menu Actions | 1-2 days |
| Phase 4: Save as Playlist | 1-2 days |
| Phase 5: Polish | 1 day |
| **Total** | **7-11 days** |
