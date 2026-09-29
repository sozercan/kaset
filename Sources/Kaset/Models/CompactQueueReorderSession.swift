import Foundation

/// A presentation-only reorder. Playback is mutated once, after a valid drop.
struct CompactQueueReorderSession: Equatable {
    let entryIDs: [UUID]
    private let sourceIndex: Int
    let playbackOwnerID: UUID?
    private(set) var destination: Int

    init?(entryIDs: [UUID], sourceID: UUID, playbackOwnerID: UUID?) {
        guard sourceID != playbackOwnerID,
              let index = entryIDs.firstIndex(of: sourceID)
        else { return nil }
        self.entryIDs = entryIDs
        self.sourceIndex = index
        self.playbackOwnerID = playbackOwnerID
        self.destination = index
    }

    var sourceID: UUID {
        self.entryIDs[self.sourceIndex]
    }

    var previewIDs: [UUID] {
        var ids = self.entryIDs
        ids.remove(at: self.sourceIndex)
        ids.insert(self.sourceID, at: self.destination)
        return ids
    }

    var beforeEntryID: UUID? {
        // The destination is indexed after removing the source entry.
        let index = self.destination < self.sourceIndex ? self.destination : self.destination + 1
        return self.entryIDs[safe: index]
    }

    var hasMoved: Bool {
        self.destination != self.sourceIndex
    }

    func isValid(entryIDs: [UUID], playbackOwnerID: UUID?) -> Bool {
        self.entryIDs == entryIDs && self.playbackOwnerID == playbackOwnerID
    }

    mutating func update(contentY: CGFloat, rowHeight: CGFloat) {
        guard contentY.isFinite, rowHeight.isFinite, rowHeight > 0 else { return }
        // Use logical slots, not animated row frames: moving a row under the
        // pointer must not move the target back and forth on subsequent events.
        let slot = floor(contentY / rowHeight)
        self.destination = Int(min(CGFloat(self.entryIDs.count - 1), max(0, slot)))
    }

    /// Points per 16 ms tick, increasing toward the edge of the viewport.
    static func scrollStep(location: CGPoint, viewport: CGSize) -> CGFloat {
        guard viewport.width > 0, viewport.height > 0,
              CGRect(origin: .zero, size: viewport).contains(location)
        else { return 0 }
        let edge = min(40, viewport.height / 2)
        if location.y < edge {
            return -8 * (edge - location.y) / edge
        }
        if location.y > viewport.height - edge {
            return 8 * (location.y - (viewport.height - edge)) / edge
        }
        return 0
    }
}
