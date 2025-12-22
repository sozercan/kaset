# Apple Intelligence Queue Integration Plan

Integrate Apple's on-device Foundation Models with the new queue system to enable natural language queue management, smart queue suggestions, and AI-powered queue refinement—following existing patterns from [ai-plan.md](ai-plan.md).

## Overview

The queue system (merged from `queue.md`) provides:
- `PlayerService.queue: [Song]` — Current playback queue
- `PlayerService.currentIndex: Int` — Current track position
- `PlayerService.playQueue(_:startingAt:)` — Play a queue of songs
- `PlayerService.playFromQueue(at:)` — Jump to specific queue position
- `PlayerService.clearQueue()` — Clear queue except current track
- `QueueView` — Right sidebar showing queue with "Up Next" header

This plan adds AI capabilities layered on top of this foundation.

---

## Phase 1: Define Queue-Specific Models

**Location:** `Core/Models/AI/QueueIntent.swift`

Create a `@Generable` struct for queue-related natural language commands:

```swift
@available(macOS 26.0, *)
@Generable
struct QueueIntent: Sendable {
    /// The type of queue action the user wants to perform.
    @Guide(description: """
        The queue action to perform:
        - add: Add song(s) to the end of the queue
        - addNext: Add song(s) immediately after current track
        - remove: Remove specific song(s) from queue
        - move: Reorder a song within the queue
        - clear: Clear the entire queue
        - shuffle: Shuffle the current queue order
        - filter: Remove songs that don't match criteria
        """)
    let action: QueueAction
    
    /// Search query for adding songs, or criteria for filtering.
    @Guide(description: "Song/artist name for add actions, or criteria for filter (e.g., 'upbeat songs only')")
    let query: String
    
    /// Number of songs to add (for "add 5 jazz songs" style requests).
    @Guide(description: "Number of songs to add. Default is 1. Use 0 for actions that don't add songs.")
    let count: Int
}

@available(macOS 26.0, *)
@Generable
enum QueueAction: String, Sendable, CaseIterable {
    case add
    case addNext
    case remove
    case move
    case clear
    case shuffle
    case filter
}
```

**Exit Criteria:**
- [ ] File compiles with no errors
- [ ] `@Generable` macro expands correctly

---

## Phase 2: Create QueueChanges Model

**Location:** `Core/Models/AI/QueueChanges.swift`

For AI-suggested queue refinements (similar to `PlaylistChanges`):

```swift
@available(macOS 26.0, *)
@Generable
struct QueueChanges: Sendable {
    /// Video IDs of tracks to remove from the queue.
    @Guide(description: "List of video IDs to remove from the queue. Empty if no removals.")
    let removals: [String]
    
    /// Video IDs of tracks to add to the queue.
    @Guide(description: "List of video IDs to add to the queue. Empty if no additions.")
    let additions: [String]
    
    /// Reordered list of video IDs representing the new queue order.
    @Guide(description: "Complete reordered list of all video IDs. Only include if reordering is needed.")
    let reorderedIds: [String]?
    
    /// Brief explanation of the suggested changes.
    @Guide(description: "A brief, friendly explanation of the suggested changes (1-2 sentences).")
    let reasoning: String
}
```

**Exit Criteria:**
- [ ] File compiles with no errors
- [ ] Model can be used with `LanguageModelSession.respond(to:generating:)`

---

## Phase 3: Build QueueTool for Grounded Responses

**Location:** `Core/Services/AI/Tools/QueueTool.swift`

Create a `Tool` that provides the current queue context to the AI model:

```swift
@available(macOS 26.0, *)
struct QueueTool: Tool {
    let playerService: PlayerService
    
    let name = "getCurrentQueue"
    let description = """
        Gets the current playback queue with track details.
        Use this to understand what's in the queue before making changes.
        Returns the current track, upcoming tracks, and queue length.
        """
    
    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Maximum number of tracks to return (default 20)")
        let limit: Int
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        let queue = playerService.queue
        let currentIndex = playerService.currentIndex
        let limit = arguments.limit > 0 ? arguments.limit : 20
        
        guard !queue.isEmpty else {
            return "Queue is empty. No tracks are queued."
        }
        
        var output = "Current Queue (\(queue.count) tracks):\n"
        
        for (index, song) in queue.prefix(limit).enumerated() {
            let marker = index == currentIndex ? "▶ NOW PLAYING" : "  "
            output += "\(marker) \(index + 1). \"\(song.title)\" by \(song.artistsDisplay) [videoId: \(song.videoId)]\n"
        }
        
        if queue.count > limit {
            output += "... and \(queue.count - limit) more tracks"
        }
        
        return output
    }
}
```

**Exit Criteria:**
- [ ] Tool compiles and conforms to `Tool` protocol
- [ ] Returns accurate queue state in tests

---

## Phase 4: Add Queue Commands to CommandBarView

**Location:** `Views/macOS/CommandBarView.swift` (extend existing or create if not present)

Extend the command bar to handle queue-specific intents:

1. Parse natural language → `QueueIntent` or `MusicIntent`
2. Route queue actions to `PlayerService`:
   - `add` → Search for songs, call `playQueue` with appended songs
   - `addNext` → Insert songs at `currentIndex + 1`
   - `remove` → Filter queue and update
   - `shuffle` → Shuffle queue array, update `currentIndex`
   - `clear` → Call `playerService.clearQueue()`

**Example Commands:**
- "Add some Taylor Swift to the queue"
- "Queue up 3 jazz songs"
- "Remove the last 2 songs from queue"
- "Shuffle my queue"
- "Play this next" (when song is selected)

**Exit Criteria:**
- [ ] Queue commands are parsed correctly
- [ ] Actions update `PlayerService.queue` as expected
- [ ] UI reflects changes immediately

---

## Phase 5: Add "Refine Queue" Feature to QueueView

**Location:** `Views/macOS/QueueView.swift`

Add an AI-powered "Refine" button in the queue header:

```swift
// In headerView, after the "Clear" button
if playerService.queue.count > 2 {
    Button {
        showRefineSheet = true
    } label: {
        Image(systemName: "wand.and.stars")
            .font(.subheadline)
    }
    .buttonStyle(.plain)
    .requiresIntelligence()
    .accessibilityIdentifier(AccessibilityID.Queue.refineButton)
}
```

**Refine Queue Sheet Flow:**
1. User taps wand icon → Sheet appears with text field
2. User enters prompt: "Remove duplicates", "Order by energy", "Keep only rock songs"
3. AI generates `QueueChanges` based on current queue + prompt
4. Display diff view: removals in red, additions in green, reorder preview
5. User confirms → Apply changes to `PlayerService.queue`

**Exit Criteria:**
- [ ] Refine button appears only when AI is available
- [ ] Sheet displays correctly with prompt input
- [ ] Changes preview shows accurate diff
- [ ] Confirmed changes apply to queue

---

## Phase 6: Smart Queue Suggestions

**Location:** `Views/macOS/QueueView.swift` (empty state enhancement)

When queue is empty or has few songs, offer AI suggestions:

```swift
private var emptyQueueView: some View {
    VStack(spacing: 12) {
        // ... existing empty state content ...
        
        if FoundationModelsService.shared.isAvailable {
            Divider()
                .padding(.vertical, 8)
            
            Text("Suggestions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            // AI-generated suggestions based on listening history
            Button("Build a queue based on my likes") {
                Task { await buildSmartQueue() }
            }
            .buttonStyle(.bordered)
            .requiresIntelligence()
        }
    }
}

private func buildSmartQueue() async {
    // Use MusicSearchTool to find songs similar to recently played
    // or based on liked songs
}
```

**Exit Criteria:**
- [ ] Suggestions appear only when AI available
- [ ] Tapping suggestion populates queue with relevant songs
- [ ] Loading state shown during generation

---

## Phase 7: "Add Similar" Context Menu

**Location:** `Views/macOS/QueueView.swift` (QueueRowView enhancement)

Add a context menu option to queue rows:

```swift
.contextMenu {
    Button("Add Similar Songs") {
        Task { await addSimilarSongs(to: song) }
    }
    .requiresIntelligence()
    
    Button("Remove from Queue") {
        removeFromQueue(at: index)
    }
}

private func addSimilarSongs(to song: Song) async {
    // Use AI + MusicSearchTool to find similar songs
    // Add them after the current song in queue
}
```

**Exit Criteria:**
- [ ] Context menu appears on right-click
- [ ] "Add Similar" option only enabled when AI available
- [ ] Similar songs are added to queue after the selected song

---

## Phase 8: Add PlayerService Queue Manipulation Methods

**Location:** `Core/Services/Player/PlayerService.swift`

Add methods needed by AI features:

```swift
/// Inserts songs immediately after the current track.
func insertNextInQueue(_ songs: [Song]) {
    guard !songs.isEmpty else { return }
    let insertIndex = min(currentIndex + 1, queue.count)
    queue.insert(contentsOf: songs, at: insertIndex)
    logger.info("Inserted \(songs.count) songs at position \(insertIndex)")
}

/// Removes songs from the queue by video ID.
func removeFromQueue(videoIds: Set<String>) {
    let previousCount = queue.count
    queue.removeAll { videoIds.contains($0.videoId) }
    
    // Adjust currentIndex if needed
    if let current = currentTrack,
       let newIndex = queue.firstIndex(where: { $0.videoId == current.videoId }) {
        currentIndex = newIndex
    }
    
    logger.info("Removed \(previousCount - queue.count) songs from queue")
}

/// Reorders the queue based on a new order of video IDs.
func reorderQueue(videoIds: [String]) {
    var reordered: [Song] = []
    var videoIdToSong: [String: Song] = [:]
    
    for song in queue {
        videoIdToSong[song.videoId] = song
    }
    
    for videoId in videoIds {
        if let song = videoIdToSong[videoId] {
            reordered.append(song)
        }
    }
    
    queue = reordered
    
    // Update currentIndex to match current track's new position
    if let current = currentTrack,
       let newIndex = queue.firstIndex(where: { $0.videoId == current.videoId }) {
        currentIndex = newIndex
    }
    
    logger.info("Queue reordered with \(reordered.count) songs")
}

/// Shuffles the queue, keeping the current track in place.
func shuffleQueue() {
    guard queue.count > 1 else { return }
    
    // Remove current track, shuffle the rest, put current track at front
    var shuffled = queue
    if let currentSong = queue[safe: currentIndex] {
        shuffled.remove(at: currentIndex)
        shuffled.shuffle()
        shuffled.insert(currentSong, at: 0)
        queue = shuffled
        currentIndex = 0
    } else {
        queue.shuffle()
        currentIndex = 0
    }
    
    logger.info("Queue shuffled")
}
```

**Exit Criteria:**
- [ ] All methods compile and work correctly
- [ ] Unit tests cover edge cases (empty queue, out-of-bounds index)
- [ ] `currentIndex` stays valid after operations

---

## Phase 9: Add Accessibility Identifiers

**Location:** `Core/Utilities/AccessibilityIdentifiers.swift`

Add queue AI-related identifiers:

```swift
enum Queue {
    // ... existing identifiers ...
    static let refineButton = "queue.refineButton"
    static let refineSheet = "queue.refineSheet"
    static let refinePromptField = "queue.refinePromptField"
    static let refineApplyButton = "queue.refineApplyButton"
    static let suggestionButton = "queue.suggestionButton"
}
```

**Exit Criteria:**
- [ ] All new UI elements have identifiers
- [ ] Identifiers follow existing naming conventions

---

## Phase 10: Unit Tests

**Location:** `Tests/KasetTests/QueueAITests.swift`

Test queue AI integration:

```swift
@MainActor
final class QueueAITests: XCTestCase {
    var playerService: PlayerService!
    
    override func setUp() async throws {
        playerService = PlayerService()
        // Populate with test queue
    }
    
    func testInsertNextInQueue() async {
        // Test inserting songs after current track
    }
    
    func testRemoveFromQueue() async {
        // Test removing songs by videoId
    }
    
    func testReorderQueue() async {
        // Test reordering preserves current track position
    }
    
    func testShuffleQueue() async {
        // Test shuffle keeps current track at front
    }
}
```

**Exit Criteria:**
- [ ] All tests pass
- [ ] Edge cases covered (empty queue, single song, current track removal)

---

## File Summary

| File | Status | Description |
|------|--------|-------------|
| `Core/Models/AI/QueueIntent.swift` | New | `@Generable` struct for queue NL commands |
| `Core/Models/AI/QueueChanges.swift` | New | `@Generable` struct for AI queue refinements |
| `Core/Services/AI/Tools/QueueTool.swift` | New | Tool providing queue context to AI |
| `Core/Services/Player/PlayerService.swift` | Modify | Add queue manipulation methods |
| `Views/macOS/QueueView.swift` | Modify | Add refine button, suggestions, context menu |
| `Core/Utilities/AccessibilityIdentifiers.swift` | Modify | Add queue AI identifiers |
| `Tests/KasetTests/QueueAITests.swift` | New | Unit tests for queue AI features |

---

## Dependencies

- Existing `FoundationModelsService` for AI session management
- Existing `MusicSearchTool` for grounded song discovery
- Existing `RequiresIntelligenceModifier` for graceful degradation
- Queue system from merged `queue.md` branch

---

## Future Considerations

### Voice Integration
Once Siri Intents are added, queue commands could work via voice:
- "Hey Siri, add this to my Kaset queue"
- "Hey Siri, shuffle my queue"

### Queue Persistence
Consider saving queue state to disk so it survives app restarts. AI could then offer "Resume yesterday's queue" suggestions.

### Collaborative Queue
For future social features, AI could mediate queue additions from multiple users, balancing tastes.
