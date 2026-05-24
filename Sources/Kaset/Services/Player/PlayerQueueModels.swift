import Foundation

// MARK: - QueueEntry

struct QueueEntry: Identifiable, Hashable {
    let id: UUID
    let song: Song
}

// MARK: - QueueState

struct QueueState {
    let entries: [QueueEntry]
    let currentIndex: Int
}
