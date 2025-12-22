## Plan: Music Queue Sidebar System

Add a queue sidebar that displays the current playback queue on the right side of the window, toggled via a button in the PlayerBar. The queue and lyrics sidebars are mutually exclusive—opening one closes the other.

### Steps

1. **Add `showQueue` state to PlayerService** — Add a `showQueue: Bool` property in [PlayerService.swift](Core/Services/Player/PlayerService.swift) with mutual exclusivity logic so toggling queue hides lyrics and vice versa (modify `didSet` on both properties).

2. **Create `QueueView`** — Add new file `Views/macOS/QueueView.swift` with a 280pt-wide sidebar containing: header with "Up Next" title and "Clear" button, a "Now Playing" highlight row, and a `LazyVStack` listing songs from `playerService.queue` with current track indicator.

3. **Add queue button to PlayerBar** — In [PlayerBar.swift](Views/macOS/PlayerBar.swift) `actionButtons`, add a queue toggle button using `Image(systemName: "list.bullet")` next to the lyrics button, following the same styling pattern (red when active, `.pressable` style).

4. **Integrate QueueView in MainWindow** — Modify [MainWindow.swift](Views/macOS/MainWindow.swift) right sidebar section to conditionally render either `LyricsView` or `QueueView` based on `showLyrics`/`showQueue` state, using the existing animation and divider pattern.

5. **Add accessibility identifiers** — Update [AccessibilityIdentifiers.swift](Core/Utilities/AccessibilityIdentifiers.swift) with queue-related identifiers for UI testing.

6. **Add unit tests** — Create `QueueViewTests.swift` and extend `PlayerServiceTests.swift` to verify mutual exclusivity logic and queue display behavior.

### Queue Row Interactions

- Tapping a queue item starts playback from that position in the queue.

### Drag-to-Reorder

- Defer to a follow-up phase. Initial implementation will be read-only display.

### WebView Queue Sync

- Use app-managed queue for now (populated when playing from playlists/albums in the app).
- Consider extracting YouTube Music's "Up Next" queue from the WebView in a future iteration.