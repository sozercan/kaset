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

    @Test("A failed account removal restores the entry and reports it")
    func removeEntryFailure() async {
        self.mockClient.accountSearchHistory = ["jazz"]
        await self.sut.loadAccountSearchHistory()
        self.mockClient.searchHistoryError = YTMusicError.networkError(underlying: URLError(.timedOut))

        await self.sut.removeSearchHistoryEntry("jazz")

        #expect(self.sut.accountSearchHistory == ["jazz"])
        #expect(self.sut.searchHistoryFailureCount == 1)
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
