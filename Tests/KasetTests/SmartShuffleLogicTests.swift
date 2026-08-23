import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
@MainActor
struct SmartShuffleLogicTests {
    private func entry(_ id: String, source: QueueEntry.Source = .queued) -> QueueEntry {
        QueueEntry(id: UUID(), song: TestFixtures.makeSong(id: id), source: source)
    }

    @Test("dedupeSuggestions drops existing ids, in-list dupes, and unplayable songs")
    func dedupe() {
        let existing: Set = ["dup"]
        let candidates = [
            TestFixtures.makeSong(id: "a"),
            TestFixtures.makeSong(id: "dup"),
            TestFixtures.makeSong(id: "b"),
            TestFixtures.makeSong(id: "b"),
            Song(id: "u", title: "U", artists: [], videoId: "u", isPlayable: false),
        ]
        let result = PlayerService.dedupeSuggestions(candidates, against: existing)
        #expect(result.map(\.videoId) == ["a", "b"])
    }

    @Test("nextSuggestionSlot seeds from the everyN-th original counting from the current track")
    func slotBasicCadence() {
        let entries = ["A", "B", "C", "D", "E", "F"].map { self.entry($0) }
        // Counting A,B,C from index 0 reaches everyN=3 at C (index 2); the suggestion goes after C.
        #expect(PlayerService.nextSuggestionSlot(in: entries, afterIndex: 0, everyN: 3, exhaustedSeeds: []) == 2)
    }

    @Test("nextSuggestionSlot counts from the current track, not the queue start")
    func slotCountsFromCurrent() {
        let entries = ["A", "B", "C", "D", "E", "F"].map { self.entry($0) }
        // Current at index 2 (C); counting C,D with everyN=2 seeds from D (index 3).
        #expect(PlayerService.nextSuggestionSlot(in: entries, afterIndex: 2, everyN: 2, exhaustedSeeds: []) == 3)
    }

    @Test("nextSuggestionSlot returns nil when fewer than everyN originals are ahead")
    func slotNilWhenTooFew() {
        let entries = ["A", "B"].map { self.entry($0) }
        #expect(PlayerService.nextSuggestionSlot(in: entries, afterIndex: 0, everyN: 3, exhaustedSeeds: []) == nil)
    }

    @Test("nextSuggestionSlot skips a gap already filled with a suggestion (idempotent)")
    func slotSkipsFilledGap() {
        // A,B,C,[S],D,E,F — the gap after C is already filled, so the next slot is after F.
        let entries = [
            self.entry("A"), self.entry("B"), self.entry("C"),
            self.entry("S", source: .suggested),
            self.entry("D"), self.entry("E"), self.entry("F"),
        ]
        #expect(PlayerService.nextSuggestionSlot(in: entries, afterIndex: 0, everyN: 3, exhaustedSeeds: []) == 6)
    }

    @Test("nextSuggestionSlot skips a slot whose seed is exhausted")
    func slotSkipsExhaustedSeed() {
        let entries = ["A", "B", "C", "D", "E", "F"].map { self.entry($0) }
        // C is the natural everyN=3 seed but is exhausted, so the scan advances to the next slot (F).
        #expect(PlayerService.nextSuggestionSlot(in: entries, afterIndex: 0, everyN: 3, exhaustedSeeds: ["C"]) == 5)
    }

    @Test("stripSuggested removes suggestions but keeps the current track even if suggested")
    func strip() {
        let a = self.entry("A")
        let s1 = self.entry("S1", source: .suggested)
        let b = self.entry("B")
        #expect(PlayerService.stripSuggested(from: [a, s1, b], keepingCurrentID: nil).map(\.song.videoId) == ["A", "B"])
        #expect(PlayerService.stripSuggested(from: [a, s1, b], keepingCurrentID: s1.id).map(\.song.videoId) == ["A", "S1", "B"])
    }
}
