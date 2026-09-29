import Foundation
import Testing
@testable import Kaset

struct CompactQueueReorderSessionTests {
    @Test("Reorder previews either direction and resolves the following entry")
    func destinations() throws {
        let ids = (0 ..< 5).map { _ in UUID() }
        var session = try #require(CompactQueueReorderSession(entryIDs: ids, sourceID: ids[2], playbackOwnerID: ids[0]))
        #expect(!session.hasMoved)
        session.update(contentY: 56, rowHeight: 56)
        #expect(session.previewIDs == [ids[0], ids[2], ids[1], ids[3], ids[4]])
        #expect(session.beforeEntryID == ids[1])
        session.update(contentY: 168, rowHeight: 56)
        #expect(session.previewIDs == [ids[0], ids[1], ids[3], ids[2], ids[4]])
        #expect(session.beforeEntryID == ids[4])
        #expect(session.entryIDs == ids)
    }

    @Test("First and last destinations clamp and returning to origin is a no-op")
    func boundaries() throws {
        let ids = (0 ..< 4).map { _ in UUID() }
        var session = try #require(CompactQueueReorderSession(entryIDs: ids, sourceID: ids[1], playbackOwnerID: ids[2]))
        session.update(contentY: -100, rowHeight: 56)
        #expect(session.previewIDs == [ids[1], ids[0], ids[2], ids[3]])
        session.update(contentY: 10000, rowHeight: 56)
        #expect(session.previewIDs == [ids[0], ids[2], ids[3], ids[1]])
        #expect(session.beforeEntryID == nil)
        session.update(contentY: 56, rowHeight: 56)
        #expect(!session.hasMoved)
        session.update(contentY: .infinity, rowHeight: 56)
        #expect(!session.hasMoved)
    }

    @Test("Playback ownership and queue changes invalidate a drag")
    func invalidation() throws {
        let ids = (0 ..< 3).map { _ in UUID() }
        #expect(CompactQueueReorderSession(entryIDs: ids, sourceID: ids[0], playbackOwnerID: ids[0]) == nil)
        #expect(CompactQueueReorderSession(entryIDs: ids, sourceID: UUID(), playbackOwnerID: nil) == nil)
        let session = try #require(CompactQueueReorderSession(entryIDs: ids, sourceID: ids[1], playbackOwnerID: ids[0]))
        #expect(session.isValid(entryIDs: ids, playbackOwnerID: ids[0]))
        #expect(!session.isValid(entryIDs: Array(ids.reversed()), playbackOwnerID: ids[0]))
        #expect(!session.isValid(entryIDs: Array(ids.dropLast()), playbackOwnerID: ids[0]))
        #expect(!session.isValid(entryIDs: ids + [UUID()], playbackOwnerID: ids[0]))
        #expect(!session.isValid(entryIDs: ids, playbackOwnerID: ids[1]))
        #expect(!session.isValid(entryIDs: ids, playbackOwnerID: nil))
    }

    @Test("Repeated songs are distinct by entry identity, not video ID")
    func duplicateSongs() throws {
        let song = TestFixtures.makeSong(id: "duplicate")
        let entries = (0 ..< 3).map { _ in QueueEntry(id: UUID(), song: song) }
        var session = try #require(CompactQueueReorderSession(entryIDs: entries.map(\.id), sourceID: entries[2].id, playbackOwnerID: entries[0].id))
        session.update(contentY: 56, rowHeight: 56)
        #expect(session.previewIDs == [entries[0].id, entries[2].id, entries[1].id])
    }

    @Test("Edge scrolling stops outside the viewport and accelerates toward its edges")
    func edgeScrolling() {
        let viewport = CGSize(width: 280, height: 400)
        #expect(CompactQueueReorderSession.scrollStep(location: CGPoint(x: 100, y: 200), viewport: viewport) == 0)
        #expect(CompactQueueReorderSession.scrollStep(location: CGPoint(x: -1, y: 5), viewport: viewport) == 0)
        #expect(CompactQueueReorderSession.scrollStep(location: CGPoint(x: 100, y: 401), viewport: viewport) == 0)
        #expect(CompactQueueReorderSession.scrollStep(location: CGPoint(x: 100, y: 20), viewport: viewport) == -4)
        #expect(CompactQueueReorderSession.scrollStep(location: CGPoint(x: 100, y: 380), viewport: viewport) == 4)
        #expect(CompactQueueReorderSession.scrollStep(location: CGPoint(x: 100, y: 390), viewport: viewport) == 6)
    }
}
