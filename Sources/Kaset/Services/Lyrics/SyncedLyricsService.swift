import Foundation

@MainActor
@Observable
final class SyncedLyricsService {
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

    init(providers: [LyricsProvider] = [LRCLibProvider()]) {
        self.providers = providers
    }

    func fetchLyrics(for info: LyricsSearchInfo) async {
        if let cached = cache[info.videoId] {
            self.currentLyrics = cached
            self.activeProvider = switch cached {
            case let .synced(s): s.source
            case let .plain(p): p.source
            case .unavailable: nil
            }
            return
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

        if let best, best.result.isAvailable {
            self.currentLyrics = best.result
            self.activeProvider = best.provider
            self.cache[info.videoId] = best.result
        } else {
            self.currentLyrics = .unavailable
            self.activeProvider = nil
            // Cache the unavailability
            self.cache[info.videoId] = .unavailable
        }

        self.isLoading = false
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
}
