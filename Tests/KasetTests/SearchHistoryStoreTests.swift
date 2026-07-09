import Foundation
import Testing
@testable import Kaset

/// Tests for SearchHistoryStore (in-memory, persistence skipped).
@Suite(.serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct SearchHistoryStoreTests {
    private func makeStore() -> SearchHistoryStore {
        SearchHistoryStore(source: .music, skipPersistence: true)
    }

    @Test("Initial state is empty")
    func initialStateEmpty() {
        #expect(self.makeStore().items.isEmpty)
    }

    @Test("Record inserts most-recent first")
    func recordInsertsMostRecentFirst() {
        let store = self.makeStore()
        store.record("daft punk")
        store.record("radiohead")

        #expect(store.items == ["radiohead", "daft punk"])
    }

    @Test("Record trims whitespace and ignores blank queries")
    func recordTrimsAndIgnoresBlank() {
        let store = self.makeStore()
        store.record("  weezer  ")
        store.record("   ")
        store.record("")

        #expect(store.items == ["weezer"])
    }

    @Test("Record de-duplicates case-insensitively and moves match to front")
    func recordDeduplicatesCaseInsensitively() {
        let store = self.makeStore()
        store.record("Radiohead")
        store.record("Daft Punk")
        store.record("radiohead")

        #expect(store.items == ["radiohead", "Daft Punk"])
    }

    @Test("Record caps the list at maxItems, dropping the oldest")
    func recordCapsAtMaxItems() {
        let store = self.makeStore()
        for index in 0 ..< (SearchHistoryStore.maxItems + 5) {
            store.record("query-\(index)")
        }

        #expect(store.items.count == SearchHistoryStore.maxItems)
        // Newest first; the very first queries fell off the end.
        #expect(store.items.first == "query-\(SearchHistoryStore.maxItems + 4)")
        #expect(!store.items.contains("query-0"))
    }

    @Test("Clear removes all items")
    func clearRemovesAll() {
        let store = self.makeStore()
        store.record("one")
        store.record("two")

        store.clear()

        #expect(store.items.isEmpty)
    }

    @Test("Remove deletes only the matching item, preserving order of the rest")
    func removeDeletesOnlyMatch() {
        let store = self.makeStore()
        store.record("one")
        store.record("two")
        store.record("three")

        store.remove("two")

        // Newest-first order preserved for the survivors.
        #expect(store.items == ["three", "one"])
    }

    @Test("Remove matches case-insensitively")
    func removeIsCaseInsensitive() {
        let store = self.makeStore()
        store.record("Radiohead")
        store.record("Daft Punk")

        store.remove("radiohead")

        #expect(store.items == ["Daft Punk"])
    }

    @Test("Remove trims input before matching")
    func removeTrimsInput() {
        let store = self.makeStore()
        store.record("weezer")

        store.remove("  weezer  ")

        #expect(store.items.isEmpty)
    }

    @Test("Remove is a no-op for blank or absent queries")
    func removeNoOpForBlankOrAbsent() {
        let store = self.makeStore()
        store.record("one")
        store.record("two")

        store.remove("")
        store.remove("   ")
        store.remove("does-not-exist")

        #expect(store.items == ["two", "one"])
    }

    @Test("Music and YouTube stores use distinct source files")
    func distinctSourceFiles() {
        #expect(SearchHistoryStore.Source.music.fileName == "search-history-music.json")
        #expect(SearchHistoryStore.Source.youtube.fileName == "search-history-youtube.json")
    }
}
