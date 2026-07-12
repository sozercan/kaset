import Foundation

// MARK: - QueueEntry

struct QueueEntry: Identifiable, Hashable {
    /// Where a queue entry came from. `suggested` marks Smart Shuffle recommendations.
    enum Source: String, Hashable, Codable {
        case queued
        case suggested
    }

    let id: UUID
    let song: Song
    /// Defaulted so existing `QueueEntry(id:song:)` call sites compile unchanged.
    var source: Source = .queued
}

// MARK: - QueuePlaybackContext

/// Identifies the queue occurrence and explicit playback generation that owns async navigation work.
struct QueuePlaybackContext: Equatable {
    let entryID: UUID?
    let index: Int
    let requestGeneration: Int
    let navigationGeneration: Int
}

// MARK: - PlaybackNavigationContext

struct PlaybackNavigationContext: Equatable {
    let requestGeneration: Int
    let navigationGeneration: Int
}

// MARK: - RadioQueueFetchOutcome

enum RadioQueueFetchOutcome: Equatable {
    case applied
    case unavailable
    case queueMutated
    case superseded
}

// MARK: - PendingNativeQueueAdvance

struct PendingNativeQueueAdvance: Equatable {
    let sourceEntryID: UUID?
    let sourceVideoId: String
    let targetEntryID: UUID
    let targetVideoId: String
    let generation: Int
}

// MARK: - QueueState

struct QueueState {
    let entries: [QueueEntry]
    let currentIndex: Int
}
