import Foundation
import Testing
@testable import Kaset

// MARK: - YouTubeSearchHistoryParserTests

@Suite("YouTubeSearchHistoryParser", .tags(.parser))
struct YouTubeSearchHistoryParserTests {
    @Test("Keeps personal history entries and drops generic suggestions")
    func parsesPersonalHistory() {
        // Shape verified against www.youtube.com/complete/search (Nov 2026):
        // history items are type 35 with subtype 39; extras carry a thumbnail.
        let body = """
        window.google.ac.h(["",[["first query",35,[39,362]],\
        ["second query",35,[39,362],{"zai":"//i.ytimg.com/vi/mock/hq.jpg","zaj":320,"zak":180,"zal":"mock"}],\
        ["trending thing",0,[433,131,362]],\
        ["Second Query",35,[631,39,362]],\
        ["older query",35,[631,39,362]]],{"j":"0","k":1}])
        """

        let queries = YouTubeSearchHistoryParser.queries(fromSuggestResponse: Data(body.utf8))

        #expect(queries == ["first query", "second query", "older query"])
    }

    @Test("Unexpected bodies parse to an empty list")
    func handlesUnexpectedBodies() {
        #expect(YouTubeSearchHistoryParser.queries(fromSuggestResponse: Data()).isEmpty)
        #expect(YouTubeSearchHistoryParser.queries(fromSuggestResponse: Data("<html></html>".utf8)).isEmpty)
        let signedOut = #"window.google.ac.h(["",[],{"k":1}])"#
        #expect(YouTubeSearchHistoryParser.queries(fromSuggestResponse: Data(signedOut.utf8)).isEmpty)
    }

    @Test("Extracts the suggest token from the page's ytcfg")
    func extractsSuggestToken() {
        let html = #"<script>ytcfg.set({"SBOX_SETTINGS":{"HAS_ON_SCREEN_KEYBOARD":false,"PSUGGEST_TOKEN":"mock-Token_123","REQUEST_DOMAIN":"us"}});</script>"#
        #expect(YouTubeSearchHistoryParser.suggestToken(fromHTML: html) == "mock-Token_123")
    }

    @Test("Rejects missing or malformed suggest tokens")
    func rejectsBadTokens() {
        #expect(YouTubeSearchHistoryParser.suggestToken(fromHTML: "<html>consent</html>") == nil)
        #expect(YouTubeSearchHistoryParser.suggestToken(fromHTML: #""PSUGGEST_TOKEN":"""#) == nil)
        #expect(YouTubeSearchHistoryParser.suggestToken(fromHTML: #""PSUGGEST_TOKEN":"bad token&x""#) == nil)
    }
}

// MARK: - YouTubeSearchHistoryStoreTests

@Suite("YouTubeSearchHistoryStore", .tags(.service))
struct YouTubeSearchHistoryStoreTests {
    private func makeStore() throws -> YouTubeSearchHistoryStore {
        let suiteName = "YouTubeSearchHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return YouTubeSearchHistoryStore(defaults: defaults)
    }

    @Test("Records most recent first without case-insensitive duplicates")
    func recordsMostRecentFirst() throws {
        let store = try self.makeStore()

        store.record("swift")
        store.record("  lofi  ")
        store.record("Swift")
        store.record("   ")

        #expect(store.entries == ["Swift", "lofi"])
    }

    @Test("Caps the number of stored entries")
    func capsEntries() throws {
        let store = try self.makeStore()

        for index in 0 ..< YouTubeSearchHistoryStore.maxEntries + 5 {
            store.record("query \(index)")
        }

        #expect(store.entries.count == YouTubeSearchHistoryStore.maxEntries)
        #expect(store.entries.first == "query \(YouTubeSearchHistoryStore.maxEntries + 4)")
    }

    @Test("Removes and clears entries")
    func removesAndClears() throws {
        let store = try self.makeStore()
        store.record("a")
        store.record("b")

        store.remove("A")
        #expect(store.entries == ["b"])

        store.clear()
        #expect(store.entries.isEmpty)
    }
}

// MARK: - YouTubeSearchViewModelHistoryTests

@Suite("YouTubeSearchViewModel history", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeSearchViewModelHistoryTests {
    let mockClient: MockYouTubeClient
    let store: YouTubeSearchHistoryStore
    let sut: YouTubeSearchViewModel

    init() throws {
        let suiteName = "YouTubeSearchViewModelHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        self.mockClient = MockYouTubeClient()
        self.store = YouTubeSearchHistoryStore(defaults: defaults)
        self.sut = YouTubeSearchViewModel(client: self.mockClient, historyStore: self.store)
    }

    @Test("Submitting a search records it in recent searches")
    func searchRecordsHistory() async {
        self.sut.query = "  swift concurrency "

        await self.sut.search()

        #expect(self.sut.recentSearches == ["swift concurrency"])
        #expect(self.store.entries == ["swift concurrency"])
    }

    @Test("Account history skips entries already in recent searches")
    func accountHistoryExcludesRecent() async {
        self.store.record("lofi")
        let sut = YouTubeSearchViewModel(client: self.mockClient, historyStore: self.store)
        self.mockClient.accountSearchHistory = ["LoFi", "jazz", "news"]

        await sut.loadAccountSearchHistory()

        #expect(sut.visibleRecentSearches == ["lofi"])
        #expect(sut.visibleAccountSearchHistory == ["jazz", "news"])
    }

    @Test("Typing narrows both history lists")
    func typingFiltersHistory() async {
        self.store.record("swift ui")
        let sut = YouTubeSearchViewModel(client: self.mockClient, historyStore: self.store)
        self.mockClient.accountSearchHistory = ["swift testing", "jazz"]
        await sut.loadAccountSearchHistory()

        sut.query = "SWIFT"

        #expect(sut.visibleRecentSearches == ["swift ui"])
        #expect(sut.visibleAccountSearchHistory == ["swift testing"])
    }

    @Test("Account history is reused until stale or forced")
    func accountHistoryCaching() async {
        await self.sut.loadAccountSearchHistory()
        await self.sut.loadAccountSearchHistory()
        #expect(self.mockClient.searchHistoryCallCount == 1)

        await self.sut.loadAccountSearchHistory(force: true)
        #expect(self.mockClient.searchHistoryCallCount == 2)
    }

    @Test("Removing an entry clears it locally and from the account")
    func removeEntryEverywhere() async {
        self.store.record("jazz")
        let sut = YouTubeSearchViewModel(client: self.mockClient, historyStore: self.store)
        self.mockClient.accountSearchHistory = ["Jazz", "news"]
        await sut.loadAccountSearchHistory()

        await sut.removeSearchHistoryEntry("jazz")

        #expect(sut.recentSearches.isEmpty)
        #expect(self.mockClient.removedSearchHistoryEntries == ["Jazz"])
        #expect(sut.accountSearchHistory == ["news"])
        #expect(sut.searchHistoryFailureCount == 0)
    }

    @Test("A removal during an in-flight history load is not undone by the stale result")
    func removalDuringInFlightLoad() async {
        self.mockClient.accountSearchHistory = ["jazz", "news"]
        await self.sut.loadAccountSearchHistory()
        let loadEntered = AsyncGate()
        let releaseLoad = AsyncGate()
        self.mockClient.beforeSearchHistoryReturn = {
            await loadEntered.open()
            await releaseLoad.wait()
        }
        let staleLoad = Task { await self.sut.loadAccountSearchHistory(force: true) }
        await loadEntered.wait()
        self.mockClient.beforeSearchHistoryReturn = nil

        let removal = Task { await self.sut.removeSearchHistoryEntry("jazz") }
        // Let the removal send its request and start waiting on the stale load.
        while self.mockClient.removedSearchHistoryEntries.isEmpty {
            await Task.yield()
        }
        await releaseLoad.open()
        await staleLoad.value
        await removal.value

        #expect(self.sut.accountSearchHistory == ["news"])
        #expect(self.sut.searchHistoryFailureCount == 0)
    }

    @Test("A removal during the first history load still removes the account entry")
    func removalDuringFirstLoad() async {
        self.mockClient.accountSearchHistory = ["jazz", "news"]
        let loadEntered = AsyncGate()
        let releaseLoad = AsyncGate()
        self.mockClient.beforeSearchHistoryReturn = {
            await loadEntered.open()
            await releaseLoad.wait()
        }
        let firstLoad = Task { await self.sut.loadAccountSearchHistory() }
        await loadEntered.wait()
        self.mockClient.beforeSearchHistoryReturn = nil

        await self.sut.removeSearchHistoryEntry("jazz")
        await releaseLoad.open()
        await firstLoad.value
        // The load hands the removal to a task of its own.
        for _ in 0 ..< 200 where self.mockClient.accountSearchHistory != ["news"] {
            await Task.yield()
        }

        #expect(self.mockClient.removedSearchHistoryEntries == ["jazz"])
        #expect(self.sut.accountSearchHistory == ["news"])
    }

    @Test("A removal waiting on a load that gets dropped is carried out by the next one")
    func removalOutlivesDroppedLoad() async {
        self.mockClient.accountSearchHistory = ["a"]
        await self.sut.loadAccountSearchHistory()
        // A refresh starts while YouTube already lists a new search.
        self.mockClient.accountSearchHistory = ["a", "jazz"]
        let loadEntered = AsyncGate()
        let releaseLoad = AsyncGate()
        self.mockClient.beforeSearchHistoryReturn = {
            await loadEntered.open()
            await releaseLoad.wait()
        }
        let refresh = Task { await self.sut.loadAccountSearchHistory(force: true) }
        await loadEntered.wait()
        self.mockClient.beforeSearchHistoryReturn = nil

        // Removing "a" makes the refresh stale; "jazz" isn't shown yet.
        let removeA = Task { await self.sut.removeSearchHistoryEntry("a") }
        while self.mockClient.removedSearchHistoryEntries.isEmpty {
            await Task.yield()
        }
        await self.sut.removeSearchHistoryEntry("jazz")
        await releaseLoad.open()
        await refresh.value
        await removeA.value
        for _ in 0 ..< 200 where self.mockClient.removedSearchHistoryEntries.count < 2 {
            await Task.yield()
        }
        for _ in 0 ..< 200 where !self.sut.accountSearchHistory.isEmpty {
            await Task.yield()
        }

        #expect(self.mockClient.removedSearchHistoryEntries == ["a", "jazz"])
        #expect(self.sut.accountSearchHistory.isEmpty)
        #expect(self.sut.searchHistoryFailureCount == 0)
    }

    @Test("A query searched again after a deferred removal is left alone")
    func deferredRemovalAppliesOnce() async {
        self.mockClient.accountSearchHistory = ["news"]
        let releaseLoad = AsyncGate()
        let loadEntered = AsyncGate()
        self.mockClient.beforeSearchHistoryReturn = {
            await loadEntered.open()
            await releaseLoad.wait()
        }
        let firstLoad = Task { await self.sut.loadAccountSearchHistory() }
        await loadEntered.wait()
        self.mockClient.beforeSearchHistoryReturn = nil
        // "jazz" isn't in the account at all; the first load publishes without it.
        await self.sut.removeSearchHistoryEntry("jazz")
        await releaseLoad.open()
        await firstLoad.value

        // Searched again later, YouTube records it, and the next load keeps it.
        self.mockClient.accountSearchHistory = ["jazz", "news"]
        await self.sut.loadAccountSearchHistory(force: true)

        #expect(self.sut.accountSearchHistory == ["jazz", "news"])
        #expect(self.mockClient.removedSearchHistoryEntries.isEmpty)
    }

    @Test("A confirmation load leaves out an entry whose removal is still pending")
    func confirmationSkipsPendingRemoval() async {
        self.mockClient.accountSearchHistory = ["a", "b"]
        await self.sut.loadAccountSearchHistory()
        let releaseB = AsyncGate()
        self.mockClient.beforeSearchHistoryRemoval = { query in
            if query == "b" {
                await releaseB.wait()
            }
        }

        let removeB = Task { await self.sut.removeSearchHistoryEntry("b") }
        while self.sut.accountSearchHistory.contains("b") {
            await Task.yield()
        }
        // "a" is removed and confirmed while YouTube still lists "b".
        await self.sut.removeSearchHistoryEntry("a")
        #expect(self.sut.accountSearchHistory.isEmpty)

        await releaseB.open()
        await removeB.value

        #expect(self.sut.accountSearchHistory.isEmpty)
        #expect(self.mockClient.removedSearchHistoryEntries == ["a", "b"])
        #expect(self.sut.searchHistoryFailureCount == 0)
    }

    @Test("Searching a query again cancels its removal that waits for the history")
    func searchAgainCancelsAwaitingRemoval() async {
        self.mockClient.accountSearchHistory = ["news"]
        let loadEntered = AsyncGate()
        let releaseLoad = AsyncGate()
        self.mockClient.beforeSearchHistoryReturn = {
            await loadEntered.open()
            await releaseLoad.wait()
        }
        let firstLoad = Task { await self.sut.loadAccountSearchHistory() }
        await loadEntered.wait()
        self.mockClient.beforeSearchHistoryReturn = nil
        await self.sut.removeSearchHistoryEntry("jazz")

        // Searched again before the history shows; YouTube records it.
        self.sut.query = "jazz"
        await self.sut.search()
        self.mockClient.accountSearchHistory = ["jazz", "news"]
        await releaseLoad.open()
        await firstLoad.value
        await self.sut.loadAccountSearchHistory(force: true)

        #expect(self.sut.accountSearchHistory == ["jazz", "news"])
        #expect(self.mockClient.removedSearchHistoryEntries.isEmpty)
    }

    @Test("A search after the history publishes, before its deferred removal starts, keeps the search")
    func searchBeforeQueuedRemovalStarts() async {
        // YouTube still lists the old "jazz" when the first history loads.
        self.mockClient.accountSearchHistory = ["jazz", "news"]
        let loadEntered = AsyncGate()
        let releaseLoad = AsyncGate()
        self.mockClient.beforeSearchHistoryReturn = {
            await loadEntered.open()
            await releaseLoad.wait()
        }
        let firstLoad = Task { await self.sut.loadAccountSearchHistory() }
        await loadEntered.wait()
        self.mockClient.beforeSearchHistoryReturn = nil
        await self.sut.removeSearchHistoryEntry("jazz")

        // The history publishing queues the deferred removal. A search queued
        // at that moment runs before the removal starts.
        let sut = self.sut
        let searchQueued = AsyncGate()
        withObservationTracking {
            _ = sut.accountSearchHistory
        } onChange: {
            Task { @MainActor in
                sut.query = "jazz"
                // search() takes the removal off the queue before it suspends.
                await sut.search()
                await searchQueued.open()
            }
        }
        await releaseLoad.open()
        await firstLoad.value
        await searchQueued.wait()
        for _ in 0 ..< 200 where !sut.accountSearchHistory.contains("jazz") {
            await Task.yield()
        }

        #expect(self.mockClient.removedSearchHistoryEntries.isEmpty)
        #expect(sut.accountSearchHistory == ["jazz", "news"])
    }

    @Test("A failed account removal restores the entry and reports it")
    func removeEntryFailure() async {
        self.mockClient.accountSearchHistory = ["jazz"]
        await self.sut.loadAccountSearchHistory()
        self.mockClient.searchHistoryError = YTMusicError.networkError(underlying: URLError(.timedOut))

        await self.sut.removeSearchHistoryEntry("jazz")

        #expect(self.sut.accountSearchHistory == ["jazz"])
        #expect(self.sut.searchHistoryFailureCount == 1)
    }

    @Test("Overlapping failed removals each put back only their own entry")
    func overlappingFailedRemovals() async {
        self.mockClient.accountSearchHistory = ["a", "b"]
        await self.sut.loadAccountSearchHistory()
        self.mockClient.searchHistoryError = YTMusicError.networkError(underlying: URLError(.timedOut))
        let releaseA = AsyncGate()
        let releaseB = AsyncGate()
        self.mockClient.beforeSearchHistoryRemoval = { query in
            await (query == "a" ? releaseA : releaseB).wait()
        }

        let removeA = Task { await self.sut.removeSearchHistoryEntry("a") }
        while self.sut.accountSearchHistory.contains("a") {
            await Task.yield()
        }
        let removeB = Task { await self.sut.removeSearchHistoryEntry("b") }
        while self.sut.accountSearchHistory.contains("b") {
            await Task.yield()
        }

        // "a" fails while "b" is still pending, then "b" fails too.
        await releaseA.open()
        await removeA.value
        await releaseB.open()
        await removeB.value

        #expect(Set(self.sut.accountSearchHistory) == ["a", "b"])
        #expect(self.sut.searchHistoryFailureCount == 2)
    }

    @Test("A failed confirmation after a removal is not an error and refetches later")
    func failedConfirmationMarksHistoryStale() async {
        self.mockClient.accountSearchHistory = ["jazz", "news"]
        await self.sut.loadAccountSearchHistory()
        self.mockClient.searchHistoryLoadError = YTMusicError.networkError(underlying: URLError(.timedOut))

        await self.sut.removeSearchHistoryEntry("jazz")

        #expect(self.mockClient.removedSearchHistoryEntries == ["jazz"])
        #expect(self.sut.accountSearchHistory == ["news"])
        #expect(self.sut.searchHistoryFailureCount == 0)

        self.mockClient.searchHistoryLoadError = nil
        let calls = self.mockClient.searchHistoryCallCount
        await self.sut.loadAccountSearchHistory()
        #expect(self.mockClient.searchHistoryCallCount == calls + 1)
    }

    @Test("A load cancelled before or while it runs never leaves the spinner on")
    func cancelledLoadNeverSticksSpinner() async throws {
        // Where the cancel lands depends on main-actor scheduling, so repeat
        // with fresh models; whichever way it interleaves, nothing may stay
        // marked as loading.
        for _ in 0 ..< 20 {
            let suiteName = "YouTubeSearchViewModelHistoryTests.cancel.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let client = MockYouTubeClient()
            client.accountSearchHistory = ["jazz"]
            let sut = YouTubeSearchViewModel(client: client, historyStore: YouTubeSearchHistoryStore(defaults: defaults))

            let load = Task { await sut.loadAccountSearchHistory() }
            await Task.yield()
            sut.cancelSearch()
            await load.value

            #expect(sut.isLoadingAccountSearchHistory == false)
        }
    }

    @Test("Clearing recent searches leaves the account history alone")
    func clearRecentOnly() async {
        self.store.record("swift")
        let sut = YouTubeSearchViewModel(client: self.mockClient, historyStore: self.store)
        self.mockClient.accountSearchHistory = ["news"]
        await sut.loadAccountSearchHistory()

        sut.clearRecentSearches()

        #expect(sut.recentSearches.isEmpty)
        #expect(self.store.entries.isEmpty)
        #expect(sut.visibleAccountSearchHistory == ["news"])
    }
}
