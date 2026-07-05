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

// MARK: - QueueState

struct QueueState {
    let entries: [QueueEntry]
    let currentIndex: Int
}
