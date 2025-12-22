import Foundation
import FoundationModels

// MARK: - QueueIntent

/// Represents a user's intent for queue-related natural language commands.
/// The model generates this from free-form text like "add jazz to queue" or "shuffle queue".
@available(macOS 26.0, *)
@Generable
struct QueueIntent: Sendable {
    /// The type of queue action the user wants to perform.
    @Guide(description: """
    The queue action to perform:
    - add: Add song(s) to the end of the queue
    - addNext: Add song(s) immediately after current track
    - remove: Remove specific song(s) from queue
    - clear: Clear the entire queue
    - shuffle: Shuffle the current queue order
    """)
    let action: QueueAction

    /// Search query for adding songs, or song title for removal.
    @Guide(description: "Song/artist name for add actions, or song title to remove. Empty for clear/shuffle actions.")
    let query: String

    /// Number of songs to add (for 'add 5 jazz songs' style requests).
    @Guide(description: "Number of songs to add. Default is 1. Use 0 for actions that don't add songs.")
    let count: Int
}

// MARK: - QueueAction

/// Actions that can be performed on the playback queue.
@available(macOS 26.0, *)
@Generable
enum QueueAction: String, Sendable, CaseIterable {
    case add
    case addNext
    case remove
    case clear
    case shuffle
}
