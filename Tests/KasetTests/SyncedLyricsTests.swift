import Foundation
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

    @Test("Karaoke sweep front interpolates between word-timing keyframes")
    func karaokeSweepFront() {
        // "hello world" with "hello" at 0ms, "world" at 1000ms, line ends at 2000ms.
        let keyframes = [
            LyricsKaraokeSweep.Keyframe(timeMs: 0, offset: 0),
            LyricsKaraokeSweep.Keyframe(timeMs: 1000, offset: 5),
            LyricsKaraokeSweep.Keyframe(timeMs: 2000, offset: 11),
        ]
        // Before the first word: line starts unhighlighted.
        #expect(LyricsKaraokeSweep.front(at: -100, totalCharacters: 11, keyframes: keyframes) == 0)
        // Halfway to "world" the front is halfway across "hello".
        #expect(abs(LyricsKaraokeSweep.front(at: 500, totalCharacters: 11, keyframes: keyframes) - 2.5) < 0.001)
        // At "world"'s start the front reaches "world"'s first character.
        #expect(LyricsKaraokeSweep.front(at: 1000, totalCharacters: 11, keyframes: keyframes) == 5)
        // The front keeps moving after the last word starts (variable speed).
        #expect(abs(LyricsKaraokeSweep.front(at: 1500, totalCharacters: 11, keyframes: keyframes) - 8) < 0.001)
        // Past the line end the whole line is bright.
        #expect(LyricsKaraokeSweep.front(at: 3000, totalCharacters: 11, keyframes: keyframes) == 11)
    }

    @Test("Karaoke sweep alpha eases across a feathered window, color only")
    func karaokeSweepAlpha() {
        // Well ahead of the front: fully dim.
        #expect(LyricsKaraokeSweep.sungAlpha(front: 3, index: 10, dim: 0.33, bright: 1.0) == 0.33)
        // Well behind the front: fully bright.
        #expect(LyricsKaraokeSweep.sungAlpha(front: 10, index: 3, dim: 0.33, bright: 1.0) == 1.0)
        // The transition window is bounded and monotonic: later characters dim first.
        let alphas = (0 ..< 12).map { LyricsKaraokeSweep.sungAlpha(front: 6, index: $0, dim: 0.33, bright: 1.0) }
        #expect(zip(alphas, alphas.dropFirst()).allSatisfy { $1 <= $0 + 0.0001 })
        #expect(alphas[0] == 1.0 && alphas[11] == 0.33)
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

    @Test("setPinnedProvider re-ranks results and drops the cached winner")
    func setPinnedProviderReranksCachedResults() async {
        let first = Self.makeSyncedLyrics(source: "First Source", lineText: "First line")
        let second = Self.makeSyncedLyrics(source: "Second Source", lineText: "Second line")
        let secondProvider = MockLyricsProvider(name: "Second", result: .synced(second))
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "First", result: .synced(first)),
            secondProvider,
        ])
        let info = Self.makeSearchInfo(videoId: "video-pin-change")

        await service.fetchLyrics(for: info)

        #expect(service.activeProvider == "First")
        #expect(await secondProvider.callCount() == 1)

        service.setPinnedProvider("Second")
        await service.fetchLyrics(for: info)

        // The pin wins within the same quality tier, and the cleared cache
        // re-queries instead of re-serving the result the old pin produced.
        #expect(service.activeProvider == "Second")
        #expect(service.currentLyrics == .synced(second))
        #expect(await secondProvider.callCount() == 2)
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

    // MARK: - MV recording mismatch

    private static func lrcLibEntry(
        duration: TimeInterval?,
        plainLyrics: String? = nil,
        syncedLyrics: String? = nil
    ) -> LRCLibModel {
        LRCLibModel(
            id: 1,
            trackName: "Song",
            artistName: "Artist",
            albumName: nil,
            duration: duration,
            instrumental: false,
            plainLyrics: plainLyrics,
            syncedLyrics: syncedLyrics
        )
    }

    private static func info(
        duration: TimeInterval?,
        requiresCloseDurationMatch: Bool
    ) -> LyricsSearchInfo {
        LyricsSearchInfo(
            title: "Song",
            artist: "Artist",
            album: nil,
            duration: duration,
            videoId: "mv",
            requiresCloseDurationMatch: requiresCloseDurationMatch
        )
    }

    private static func plainText(from result: LyricResult) -> String? {
        guard case let .plain(lyrics) = result else { return nil }
        return lyrics.text
    }

    @Test("LRCLib keeps the closest-recording synced match within the duration tolerance")
    func lrcLibCloseDurationMatchStaysSynced() {
        let studio = Self.lrcLibEntry(duration: 180, plainLyrics: "Studio plain", syncedLyrics: "[00:00.20]Studio line")
        let live = Self.lrcLibEntry(duration: 254, plainLyrics: "Live plain", syncedLyrics: "[00:00.20]Live line")

        // The loaded MV recording runs ~254s; the live entry matches closely
        // and wins over the studio entry even though the search is keyed to
        // the studio title.
        let result = LRCLibProvider.matchResult(
            from: [studio, live],
            info: Self.info(duration: 254, requiresCloseDurationMatch: true)
        )

        guard case let .synced(lyrics) = result else {
            Issue.record("Expected a synced match for the close recording")
            return
        }
        #expect(lyrics.lines.first?.text == "Live line")
    }

    @Test("LRCLib degrades to plain lyrics when only a different recording matches")
    func lrcLibDegradesOnRecordingDurationMismatch() {
        let studio = Self.lrcLibEntry(duration: 180, plainLyrics: "Studio plain", syncedLyrics: "[00:00.20]Studio line")

        // The loaded MV recording runs ~254s; only the studio recording's
        // synced lyrics exist, and their timings would highlight the wrong
        // moments — degrade to the plain lyrics instead.
        let degraded = LRCLibProvider.matchResult(
            from: [studio],
            info: Self.info(duration: 254, requiresCloseDurationMatch: true)
        )
        #expect(Self.plainText(from: degraded) == "Studio plain")

        // Without the close-match requirement (normal audio playback), the
        // studio synced lyrics are still served.
        let normal = LRCLibProvider.matchResult(
            from: [studio],
            info: Self.info(duration: 254, requiresCloseDurationMatch: false)
        )
        guard case .synced = normal else {
            Issue.record("Expected the normal path to stay synced")
            return
        }
    }

    @Test("LRCLib keeps synced lyrics when the mismatch flag is set but durations are close")
    func lrcLibKeepsSyncedForCloseDurations() {
        let entry = Self.lrcLibEntry(duration: 256, plainLyrics: "Plain", syncedLyrics: "[00:01.00]Line")

        let result = LRCLibProvider.matchResult(
            from: [entry],
            info: Self.info(duration: 254, requiresCloseDurationMatch: true)
        )

        guard case .synced = result else {
            Issue.record("Expected a synced match within tolerance")
            return
        }
    }

    @Test("invalidateCachedLyrics forces the next fetch to re-search the providers")
    func invalidateCachedLyricsForcesRefetch() async {
        let synced = Self.makeSyncedLyrics(source: "Provider", lineText: "Cached line")
        let provider = MockLyricsProvider(name: "Provider", result: .synced(synced))
        let service = SyncedLyricsService(providers: [provider])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-invalidate"))
        #expect(await provider.callCount() == 1)

        // A repeat fetch is served from cache…
        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-invalidate"))
        #expect(await provider.callCount() == 1)

        // …but the recording-mismatch refetch must re-search.
        service.invalidateCachedLyrics(for: "video-invalidate")
        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-invalidate"))
        #expect(await provider.callCount() == 2)
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

    @Test("fetchLyrics prefers word-level synced lyrics over line-level regardless of provider order")
    func fetchLyricsPrefersWordLevelSyncedLyrics() async {
        let lineLevel = Self.makeSyncedLyrics(source: "LineProvider", lineText: "Line 1")
        let wordLevel = SyncedLyrics(
            lines: [
                SyncedLyricLine(
                    timeInMs: 0,
                    duration: 5000,
                    text: "Hello world",
                    words: [
                        TimedWord(timeInMs: 0, word: "Hello "),
                        TimedWord(timeInMs: 500, word: "world"),
                    ]
                ),
            ],
            source: "WordProvider"
        )
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "LineProvider", result: .synced(lineLevel)),
            MockLyricsProvider(name: "WordProvider", result: .synced(wordLevel)),
        ])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-word-level"))

        #expect(service.currentLyrics == .synced(wordLevel))
        #expect(service.activeProvider == "WordProvider")
    }

    @Test("fetchLyrics prefers the more complete line-level lyrics on granularity ties")
    func fetchLyricsPrefersMoreCompleteSyncedLyrics() async {
        let sparse = SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 5000, text: "One", words: nil),
            ],
            source: "Sparse"
        )
        let complete = SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 3000, text: "One", words: nil),
                SyncedLyricLine(timeInMs: 3000, duration: 3000, text: "Two", words: nil),
            ],
            source: "Complete"
        )
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "Sparse", result: .synced(sparse)),
            MockLyricsProvider(name: "Complete", result: .synced(complete)),
        ])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-completeness"))

        #expect(service.currentLyrics == .synced(complete))
        #expect(service.activeProvider == "Complete")
    }

    @Test("NetEase yrc parser builds word timings from the bracket format")
    func netEaseYRCParsing() throws {
        let raw = """
        {"t":-1000,"c":[{"tx":"作词: 某人"}]}
        [27410,5060](27410,260,0)也(27670,500,0)许(28170,600,0)已
        [33920,2100](33920,210,0)面(34130,120,0)对
        """

        let lines = try #require(NetEaseProvider.parseYRC(raw))
        #expect(lines.count == 2)
        #expect(lines[0].timeInMs == 27410)
        #expect(lines[0].text == "也许已")
        #expect(lines[0].words?.count == 3)
        #expect(lines[0].words?[0] == TimedWord(timeInMs: 27410, word: "也"))
        #expect(lines[0].words?[1] == TimedWord(timeInMs: 27670, word: "许"))
        #expect(lines[1].text == "面对")
    }

    @Test("NetEase JSON-shape lyrics parse into timed lines")
    func netEaseJSONLyricsParsing() throws {
        let raw = """
        {"t":0,"c":[{"tx":"作词: "},{"tx":"某人"}]}
        {"t":1500,"c":[{"tx":"第一行"}]}
        {"t":4000,"c":[{"tx":"第二行"}]}
        """

        let lines = try #require(NetEaseProvider.parseLyricBody(raw))
        #expect(lines.count == 3)
        #expect(lines[0].text == "作词: 某人")
        #expect(lines[1].timeInMs == 1500)
        #expect(lines[1].duration == 2500)
        #expect(lines[2].duration == 5000)
    }

    @Test("Google translate target codes map script suffixes")
    func googleTranslateTargetCodes() {
        #expect(GoogleTranslateService.targetCode(for: "zh-Hans") == "zh-CN")
        #expect(GoogleTranslateService.targetCode(for: "zh-Hant") == "zh-TW")
        #expect(GoogleTranslateService.targetCode(for: "ja") == "ja")
        #expect(GoogleTranslateService.targetCode(for: nil) == "en")
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
