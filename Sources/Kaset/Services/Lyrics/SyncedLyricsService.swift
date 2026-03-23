import Foundation

@MainActor
@Observable
final class SyncedLyricsService {
    private struct ResolvedLyrics {
        let result: LyricResult
        let activeProvider: String?
    }

    /// Current lyrics result.
    var currentLyrics: LyricResult = .unavailable

    /// Which provider supplied the current lyrics.
    var activeProvider: String?

    /// Loading state.
    var isLoading = false

    /// All registered providers, ordered by priority.
    private let providers: [LyricsProvider]

    /// In-memory cache keyed by videoId.
    private var cache: [String: LyricResult] = [:]

    /// Monotonic identifier used to ignore stale in-flight searches.
    private var fetchGeneration = 0

    init(providers: [LyricsProvider] = [LRCLibProvider()]) {
        self.providers = providers
    }

    func fetchLyrics(for info: LyricsSearchInfo) async {
        self.fetchGeneration += 1
        let requestID = self.fetchGeneration
        let cached = self.cache[info.videoId]

        if let cached, case .synced = cached {
            self.applyResolvedLyrics(
                .init(
                    result: cached,
                    activeProvider: Self.cachedProviderName(for: cached)
                ),
                requestID: requestID
            )
            return
        }

        if let cached {
            self.currentLyrics = cached
            self.activeProvider = Self.cachedProviderName(for: cached)
        }

        self.isLoading = true

        // Don't clear currentLyrics immediately to prevent flicker, but reset state when done
        var allResults: [(provider: String, result: LyricResult)] = []

        // Fetch concurrently
        await withTaskGroup(of: (String, LyricResult)?.self) { group in
            for provider in self.providers {
                group.addTask {
                    let result = await provider.search(info: info)
                    return (provider.name, result)
                }
            }

            for await res in group {
                if let res {
                    allResults.append(res)
                }
            }
        }

        // Pick best result
        // Score: Synced = 2, Plain = 1, YTMusic = +1 bias
        let best = allResults.max { a, b in
            let scoreA = self.score(result: a.result, providerName: a.provider)
            let scoreB = self.score(result: b.result, providerName: b.provider)
            return scoreA < scoreB
        }

        let resolved = self.resolveLyrics(best: best, cached: cached, videoId: info.videoId)
        self.applyResolvedLyrics(resolved, requestID: requestID)
    }

    /// Fallback logic
    func fallbackToPlainLyrics(_ lyrics: Lyrics, videoId: String) {
        if case .synced = self.currentLyrics {
            // Already synced, don't overwrite with plain
            return
        }

        if lyrics.isAvailable {
            self.currentLyrics = .plain(lyrics)
            self.activeProvider = lyrics.source
            self.cache[videoId] = .plain(lyrics)
        } else {
            self.currentLyrics = .unavailable
            self.activeProvider = nil
            self.cache[videoId] = .unavailable
        }
    }

    private func score(result: LyricResult, providerName: String) -> Int {
        var s = 0
        switch result {
        case .synced: s += 2
        case .plain: s += 1
        case .unavailable: return -1 // Disqualified
        }

        if providerName == "YTMusic" {
            s += 1
        }
        return s
    }

    private func resolveLyrics(
        best: (provider: String, result: LyricResult)?,
        cached: LyricResult?,
        videoId: String
    ) -> ResolvedLyrics {
        if let best {
            switch best.result {
            case .synced:
                self.cache[videoId] = best.result
                return .init(result: best.result, activeProvider: best.provider)
            case .plain:
                if case let .plain(cachedPlain)? = cached {
                    return .init(result: .plain(cachedPlain), activeProvider: cachedPlain.source)
                }

                self.cache[videoId] = best.result
                return .init(result: best.result, activeProvider: best.provider)
            case .unavailable:
                break
            }
        }

        if case let .plain(cachedPlain)? = cached {
            return .init(result: .plain(cachedPlain), activeProvider: cachedPlain.source)
        }

        self.cache[videoId] = .unavailable
        return .init(result: .unavailable, activeProvider: nil)
    }

    private func applyResolvedLyrics(_ resolved: ResolvedLyrics, requestID: Int) {
        guard requestID == self.fetchGeneration else { return }

        self.currentLyrics = resolved.result
        self.activeProvider = resolved.activeProvider
        self.isLoading = false
    }

    private static func cachedProviderName(for result: LyricResult) -> String? {
        switch result {
        case let .synced(lyrics):
            lyrics.source
        case let .plain(lyrics):
            lyrics.source
        case .unavailable:
            nil
        }
    }
}
