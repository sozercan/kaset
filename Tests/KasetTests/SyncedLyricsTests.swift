import Testing
@testable import Kaset

// MARK: - SyncedLyricsTests

@Suite(.tags(.model))
struct SyncedLyricsTests {
    @Test("Line statuses computation")
    func lineStatuses() {
        let lines = [
            SyncedLyricLine(timeInMs: 0, duration: 10000, text: "Wait for it...", words: nil),
            SyncedLyricLine(timeInMs: 10000, duration: 5000, text: "Line 1", words: nil),
            SyncedLyricLine(timeInMs: 15000, duration: 5000, text: "Line 2", words: nil),
        ]
        let lyrics = SyncedLyrics(lines: lines, source: "Test")

        let statuses1 = lyrics.lineStatuses(at: 5000)
        #expect(statuses1 == [.current, .upcoming, .upcoming])

        let statuses2 = lyrics.lineStatuses(at: 12000)
        #expect(statuses2 == [.previous, .current, .upcoming])

        let statuses3 = lyrics.lineStatuses(at: 16000)
        #expect(statuses3 == [.previous, .previous, .current])

        let currentIdx = lyrics.currentLineIndex(at: 12000)
        #expect(currentIdx == 1)
    }
}

// MARK: - SyncedLyricsServiceTests

@Suite(.serialized, .tags(.service))
@MainActor
struct SyncedLyricsServiceTests {
    @Test("fetchLyrics prefers synced results over plain results")
    func fetchLyricsPrefersSyncedResults() async {
        let plain = Lyrics(text: "Plain lyrics", source: "Plain Source")
        let synced = Self.makeSyncedLyrics(source: "Synced Source", lineText: "Synced line")
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "PlainProvider", result: .plain(plain)),
            MockLyricsProvider(name: "SyncedProvider", result: .synced(synced)),
        ])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-synced"))

        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "SyncedProvider")
        #expect(service.isLoading == false)
    }

    @Test("fetchLyrics prefers YTMusic plain lyrics over other plain lyrics")
    func fetchLyricsPrefersYTMusicPlainLyrics() async {
        let otherPlain = Lyrics(text: "Other lyrics", source: "Other Source")
        let ytMusicPlain = Lyrics(text: "YTMusic lyrics", source: "YTMusic Source")
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "Genius", result: .plain(otherPlain)),
            MockLyricsProvider(name: "YTMusic", result: .plain(ytMusicPlain)),
        ])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-ytmusic"))

        #expect(service.currentLyrics == .plain(ytMusicPlain))
        #expect(service.activeProvider == "YTMusic")
        #expect(service.isLoading == false)
    }

    @Test("fetchLyrics prefers synced lyrics over earlier YTMusic plain lyrics")
    func fetchLyricsPrefersDelayedSyncedLyrics() async {
        let ytMusicPlain = Lyrics(text: "YTMusic lyrics", source: "YTMusic Source")
        let synced = Self.makeSyncedLyrics(source: "LRCLib", lineText: "Synced line")
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "YTMusic", result: .plain(ytMusicPlain)),
            MockLyricsProvider(name: "LRCLib") { _ in
                try? await Task.sleep(for: .milliseconds(50))
                return .synced(synced)
            },
        ])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-delayed-synced"))

        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "LRCLib")
        #expect(service.isLoading == false)
    }

    @Test("fetchLyrics caches results and derives activeProvider from cached source")
    func fetchLyricsCachesResults() async {
        let synced = Self.makeSyncedLyrics(source: "Cached Source", lineText: "Cached line")
        let provider = MockLyricsProvider(name: "MockProvider", result: .synced(synced))
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-cache")

        await service.fetchLyrics(for: info)

        #expect(await provider.callCount() == 1)
        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "MockProvider")

        await service.fetchLyrics(for: info)

        #expect(await provider.callCount() == 1)
        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "Cached Source")
    }

    @Test("fetchLyrics retries after a cached unavailable result")
    func fetchLyricsRetriesAfterCachedUnavailableResult() async {
        let provider = MockLyricsProvider(name: "UnavailableProvider", result: .unavailable)
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-unavailable")

        await service.fetchLyrics(for: info)

        #expect(service.currentLyrics == .unavailable)
        #expect(service.activeProvider == nil)
        #expect(service.isLoading == false)
        #expect(await provider.callCount() == 1)

        await service.fetchLyrics(for: info)

        #expect(service.currentLyrics == .unavailable)
        #expect(service.activeProvider == nil)
        #expect(await provider.callCount() == 2)
    }

    @Test("fetchLyrics updates loading state while a search is in flight")
    func fetchLyricsUpdatesLoadingState() async {
        let gate = SearchGate()
        let synced = Self.makeSyncedLyrics(source: "Delayed Source", lineText: "Delayed line")
        let provider = MockLyricsProvider(name: "SlowProvider", result: .synced(synced), gate: gate)
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-loading")

        let task = Task { @MainActor in
            await service.fetchLyrics(for: info)
        }

        await gate.waitUntilStarted()

        #expect(service.isLoading)
        #expect(service.currentLyrics == .unavailable)

        await gate.release()
        await task.value

        #expect(service.isLoading == false)
        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "SlowProvider")
    }

    @Test("fetchLyrics can upgrade cached plain lyrics to synced results")
    func fetchLyricsUpgradesCachedPlainLyricsToSyncedResults() async {
        let plain = Lyrics(text: "Fallback lyrics", source: "Lyrics by LyricFind")
        let synced = Self.makeSyncedLyrics(source: "Synced Source", lineText: "Synced line")
        let provider = MockLyricsProvider(
            name: "SyncedProvider",
            result: .synced(synced)
        )
        let service = SyncedLyricsService(providers: [provider])
        let videoId = "video-fallback"

        service.fallbackToPlainLyrics(plain, videoId: videoId)

        #expect(service.currentLyrics == .plain(plain))
        #expect(service.activeProvider == "Lyrics by LyricFind")

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: videoId))

        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "SyncedProvider")
        #expect(await provider.callCount() == 1)
    }

    @Test("fetchLyrics keeps cached plain lyrics when no synced result is found")
    func fetchLyricsKeepsCachedPlainLyricsWhenProvidersStillFail() async {
        let plain = Lyrics(text: "Fallback lyrics", source: "Lyrics by LyricFind")
        let provider = MockLyricsProvider(name: "UnavailableProvider", result: .unavailable)
        let service = SyncedLyricsService(providers: [provider])
        let videoId = "video-fallback-plain"

        service.fallbackToPlainLyrics(plain, videoId: videoId)

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: videoId))

        #expect(service.currentLyrics == .plain(plain))
        #expect(service.activeProvider == "Lyrics by LyricFind")
        #expect(await provider.callCount() == 1)
    }

    @Test("stale in-flight fetches do not overwrite a newer result")
    func staleFetchesDoNotOverwriteNewerResults() async {
        let staleGate = SearchGate()
        let staleLyrics = Self.makeSyncedLyrics(source: "Stale Source", lineText: "Stale line")
        let freshLyrics = Self.makeSyncedLyrics(source: "Fresh Source", lineText: "Fresh line")
        let provider = MockLyricsProvider(name: "RacingProvider") { info in
            if info.videoId == "video-stale" {
                await staleGate.markStarted()
                await staleGate.waitUntilReleased()
                return .synced(staleLyrics)
            }

            return .synced(freshLyrics)
        }
        let service = SyncedLyricsService(providers: [provider])

        let staleTask = Task { @MainActor in
            await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-stale"))
        }

        await staleGate.waitUntilStarted()
        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-fresh"))

        #expect(service.currentLyrics == .synced(freshLyrics))
        #expect(service.activeProvider == "RacingProvider")

        await staleGate.release()
        await staleTask.value

        #expect(service.currentLyrics == .synced(freshLyrics))
        #expect(service.activeProvider == "RacingProvider")
        #expect(await provider.callCount() == 2)
    }

    @Test("fallbackToPlainLyrics does not overwrite synced lyrics")
    func fallbackToPlainLyricsDoesNotOverwriteSyncedLyrics() async {
        let synced = Self.makeSyncedLyrics(source: "Primary Synced Source", lineText: "Primary line")
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "SyncedProvider", result: .synced(synced)),
        ])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-keep-synced"))
        service.fallbackToPlainLyrics(
            Lyrics(text: "Fallback lyrics", source: "Lyrics by YouTube Music"),
            videoId: "video-keep-synced"
        )

        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "SyncedProvider")
    }

    @Test("toggling romanization updates current lyrics without refetching")
    func togglingRomanizationRefreshesCurrentLyrics() async throws {
        let originalRomanizationEnabled = SettingsManager.shared.romanizationEnabled
        defer { SettingsManager.shared.romanizationEnabled = originalRomanizationEnabled }

        SettingsManager.shared.romanizationEnabled = false

        let synced = Self.makeSyncedLyrics(source: "LRCLib", lineText: "안녕하세요")
        let provider = MockLyricsProvider(name: "LRCLib", result: .synced(synced))
        let service = SyncedLyricsService(providers: [provider])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-romanization-toggle"))

        let initialLyrics = try #require(Self.syncedLyrics(from: service.currentLyrics))
        #expect(initialLyrics.lines[0].romanizedText == nil)
        #expect(await provider.callCount() == 1)

        SettingsManager.shared.romanizationEnabled = true
        try? await Task.sleep(for: .milliseconds(100))

        let updatedLyrics = try #require(Self.syncedLyrics(from: service.currentLyrics))
        #expect(updatedLyrics.lines[0].id == synced.lines[0].id)
        #expect(updatedLyrics.lines[0].romanizedText != nil)
        #expect(await provider.callCount() == 1)
    }

    private static func makeSearchInfo(videoId: String) -> LyricsSearchInfo {
        LyricsSearchInfo(
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            duration: 180,
            videoId: videoId
        )
    }

    private static func makeSyncedLyrics(source: String, lineText: String) -> SyncedLyrics {
        SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 5000, text: lineText, words: nil),
            ],
            source: source
        )
    }

    private static func syncedLyrics(from result: LyricResult) -> SyncedLyrics? {
        guard case let .synced(lyrics) = result else { return nil }
        return lyrics
    }
}

// MARK: - MockLyricsProvider

private final class MockLyricsProvider: LyricsProvider, @unchecked Sendable {
    let name: String

    private let searchHandler: (LyricsSearchInfo) async -> LyricResult
    private let counter = SearchCounter()

    init(name: String, result: LyricResult, gate: SearchGate? = nil) {
        self.name = name
        self.searchHandler = { _ in
            if let gate {
                await gate.markStarted()
                await gate.waitUntilReleased()
            }

            return result
        }
    }

    init(name: String, searchHandler: @escaping (LyricsSearchInfo) async -> LyricResult) {
        self.name = name
        self.searchHandler = searchHandler
    }

    func search(info: LyricsSearchInfo) async -> LyricResult {
        await self.counter.increment()
        return await self.searchHandler(info)
    }

    func callCount() async -> Int {
        await self.counter.value()
    }
}

// MARK: - SearchCounter

private actor SearchCounter {
    private var count = 0

    func increment() {
        self.count += 1
    }

    func value() -> Int {
        self.count
    }
}

// MARK: - SearchGate

private actor SearchGate {
    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        guard !self.didStart else { return }

        self.didStart = true
        let waiters = self.startWaiters
        self.startWaiters.removeAll()

        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        if self.didStart {
            return
        }

        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        if self.isReleased {
            return
        }

        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func release() {
        guard !self.isReleased else { return }

        self.isReleased = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()

        for waiter in waiters {
            waiter.resume()
        }
    }
}
