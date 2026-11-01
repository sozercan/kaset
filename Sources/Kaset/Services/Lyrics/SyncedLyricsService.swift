import Foundation
import Observation

@MainActor
@Observable
final class SyncedLyricsService {
    private struct ResolvedLyrics {
        let result: LyricResult
        let activeProvider: String?
    }

    private struct ProviderResult {
        let provider: String
        let providerIndex: Int
        let result: LyricResult
    }

    /// Current lyrics result.
    var currentLyrics: LyricResult = .unavailable

    /// Which provider supplied the current lyrics.
    var activeProvider: String?

    /// Loading state.
    var isLoading = false

    /// All registered providers, ordered by priority.
    private let providers: [LyricsProvider]

    /// Romanization service for transliterating non-Latin lyrics.
    private let romanizationService = RomanizationService()

    /// The user's pinned lyrics provider, if any; preferred when ranking results.
    /// Set through `setPinnedProvider(_:)` so the cache stays consistent.
    private var pinnedProvider: String?

    private struct CacheKey: Hashable {
        let videoId: String
        var duration: TimeInterval?
        var requiresCloseDurationMatch = false
    }

    /// Recording-specific cache entries prevent studio and MV timings from being interchanged.
    private var cache: [CacheKey: CacheEntry] = [:]

    /// Base synced lyrics before romanization is applied for display.
    private var currentBaseSyncedLyrics: SyncedLyrics?

    /// Monotonic identifier used to ignore stale in-flight searches.
    private var fetchGeneration = 0

    /// How long a successful lyrics result stays valid in the cache.
    private static let cacheTTL: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    /// How long an unavailable result stays cached before a re-search.
    private static let negativeCacheTTL: TimeInterval = 30 * 60 // 30 minutes

    /// Registers providers and observes pronunciation changes for accepted synced lyrics.
    init(providers: [LyricsProvider] = [LRCLibProvider()], pinnedProvider: String? = nil) {
        self.providers = providers
        self.pinnedProvider = pinnedProvider
        self.observeRomanizationSetting()
    }

    /// Changes the pinned provider. Resolved cache entries are dropped so the
    /// next fetch re-ranks providers under the new pin instead of serving the
    /// result the old pin produced.
    func setPinnedProvider(_ provider: String?) {
        guard provider != self.pinnedProvider else { return }
        self.pinnedProvider = provider
        self.cache.removeAll()
    }

    /// A cached lyrics result with the time it was stored.
    private struct CacheEntry {
        let result: LyricResult
        let timestamp: Date
    }

    /// Returns recording-specific timings, or recording-independent plain lyrics, within their TTL.
    private func cachedEntry(for key: CacheKey) -> CacheEntry? {
        let plainKey = CacheKey(videoId: key.videoId)
        let entry: CacheEntry
        let storedKey: CacheKey
        if let exact = self.cache[key] {
            entry = exact
            storedKey = key
        } else if let plain = self.cache[plainKey], case .plain = plain.result {
            entry = plain
            storedKey = plainKey
        } else {
            return nil
        }
        let ttl: TimeInterval = switch entry.result {
        case .unavailable: Self.negativeCacheTTL
        default: Self.cacheTTL
        }
        guard Date().timeIntervalSince(entry.timestamp) < ttl else {
            self.cache.removeValue(forKey: storedKey)
            return nil
        }
        return entry
    }

    /// Resolves lyrics for one recording, ignoring searches superseded by a newer request.
    func fetchLyrics(for info: LyricsSearchInfo) async {
        self.fetchGeneration += 1
        let requestID = self.fetchGeneration
        let key = CacheKey(videoId: info.videoId, duration: info.duration, requiresCloseDurationMatch: info.requiresCloseDurationMatch)
        let cached = self.cachedEntry(for: key)?.result

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
            self.currentBaseSyncedLyrics = nil
            self.currentLyrics = cached
            self.activeProvider = Self.cachedProviderName(for: cached)
        }

        self.isLoading = true

        // Don't clear currentLyrics immediately to prevent flicker, but reset state when done
        var allResults: [ProviderResult] = []

        // Fetch concurrently
        await withTaskGroup(of: ProviderResult?.self) { group in
            for (providerIndex, provider) in self.providers.enumerated() {
                group.addTask {
                    let result = await provider.search(info: info)
                    return ProviderResult(
                        provider: provider.name,
                        providerIndex: providerIndex,
                        result: result
                    )
                }
            }

            for await res in group {
                if let res {
                    allResults.append(res)
                }
            }
        }

        var best: ProviderResult?
        for candidate in allResults {
            guard let currentBest = best else {
                best = candidate
                continue
            }

            if self.isBetter(candidate, than: currentBest) {
                best = candidate
            }
        }

        guard requestID == self.fetchGeneration else { return }
        let resolved = self.resolveLyrics(best: best, cached: cached, key: key)
        self.applyResolvedLyrics(resolved, requestID: requestID)
    }

    /// Drops the cached result for `videoId` so the next fetch re-searches the
    /// providers. The MV-recording mismatch refetch needs this: the cached
    /// studio-recording match must not short-circuit the recording-keyed search.
    func invalidateCachedLyrics(for videoId: String) {
        self.cache = self.cache.filter { $0.key.videoId != videoId }
    }

    /// Rejects a mismatched synced result and clears its romanization base atomically.
    func rejectSyncedLyrics(replacingWith plain: Lyrics, videoId: String) {
        self.fetchGeneration += 1
        self.invalidateCachedLyrics(for: videoId)
        self.currentBaseSyncedLyrics = nil
        self.currentLyrics = .plain(plain)
        self.activeProvider = plain.source ?? "Source: YouTube Music"
        self.isLoading = false
    }

    /// Supplies plain YouTube Music lyrics without overwriting an accepted synced result.
    func fallbackToPlainLyrics(_ lyrics: Lyrics, videoId: String) {
        if case .synced = self.currentLyrics {
            // Already synced, don't overwrite with plain
            return
        }

        self.currentBaseSyncedLyrics = nil

        if lyrics.isAvailable {
            self.currentLyrics = .plain(lyrics)
            self.activeProvider = lyrics.source
            self.cache[CacheKey(videoId: videoId)] = CacheEntry(result: .plain(lyrics), timestamp: Date())
        } else {
            self.currentLyrics = .unavailable
            self.activeProvider = nil
            self.cache[CacheKey(videoId: videoId)] = CacheEntry(result: .unavailable, timestamp: Date())
        }
    }

    /// Re-registers observation after every pronunciation setting change.
    private func observeRomanizationSetting() {
        withObservationTracking {
            _ = SettingsManager.shared.romanizationEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshCurrentRomanization()
                self?.observeRomanizationSetting()
            }
        }
    }

    /// Refreshes display pronunciation only when an accepted synced base remains.
    private func refreshCurrentRomanization() {
        guard let baseLyrics = self.currentBaseSyncedLyrics else { return }
        self.currentLyrics = .synced(self.displayLyrics(from: baseLyrics))
    }

    /// Adds pronunciation to the accepted source without mutating its cached base.
    private func displayLyrics(from synced: SyncedLyrics) -> SyncedLyrics {
        guard self.romanizationService.isEnabled else {
            return synced
        }

        let romanized = self.romanizationService.romanizeAll(synced)
        guard !romanized.isEmpty else {
            return synced
        }

        var updatedLines = synced.lines
        for index in updatedLines.indices {
            updatedLines[index].romanizedText = romanized[updatedLines[index].id]
        }

        return SyncedLyrics(lines: updatedLines, source: synced.source)
    }

    /// Prefers usable timed results to plain lyrics and unavailable results.
    private func resultRank(_ result: LyricResult) -> Int {
        switch result {
        case .synced:
            2
        case .plain:
            1
        case .unavailable:
            0
        }
    }

    /// Synced-lyrics pick-the-best ranking (checked in order):
    ///   1. User's pinned provider within the same result kind.
    ///   2. Granularity: word/syllable timings beat line-level timing.
    ///   3. Completeness, then registered provider order.
    private func isBetter(_ candidate: ProviderResult, than currentBest: ProviderResult) -> Bool {
        let candidateRank = self.resultRank(candidate.result)
        let currentRank = self.resultRank(currentBest.result)
        if candidateRank != currentRank {
            return candidateRank > currentRank
        }

        // A selected source wins within the same result kind, before quality tie-breaks.
        let candidateIsPinned = candidate.provider == self.pinnedProvider
        let currentIsPinned = currentBest.provider == self.pinnedProvider
        if candidateIsPinned != currentIsPinned {
            return candidateIsPinned
        }

        if case let .synced(candidateLyrics) = candidate.result,
           case let .synced(bestLyrics) = currentBest.result
        {
            let candidateWords = candidateLyrics.lines.contains { $0.words?.isEmpty == false }
            let bestWords = bestLyrics.lines.contains { $0.words?.isEmpty == false }
            if candidateWords != bestWords {
                return candidateWords
            }

            let candidateScore = candidateLyrics.lines.filter { !$0.text.isEmpty }.count
            let bestScore = bestLyrics.lines.filter { !$0.text.isEmpty }.count
            if candidateScore != bestScore {
                return candidateScore > bestScore
            }
        }

        if case .plain = candidate.result,
           case .plain = currentBest.result
        {
            let candidateIsYTMusic = candidate.provider == "YTMusic"
            let currentIsYTMusic = currentBest.provider == "YTMusic"
            if candidateIsYTMusic != currentIsYTMusic {
                return candidateIsYTMusic
            }
        }

        return candidate.providerIndex < currentBest.providerIndex
    }

    /// Caches the winner under its recording key while preserving a plain fallback.
    private func resolveLyrics(
        best: ProviderResult?,
        cached: LyricResult?,
        key: CacheKey
    ) -> ResolvedLyrics {
        if let best {
            switch best.result {
            case .synced:
                self.cache[key] = CacheEntry(result: best.result, timestamp: Date())
                return .init(result: best.result, activeProvider: best.provider)
            case .plain:
                if case let .plain(cachedPlain)? = cached {
                    return .init(result: .plain(cachedPlain), activeProvider: cachedPlain.source)
                }

                self.cache[key] = CacheEntry(result: best.result, timestamp: Date())
                return .init(result: best.result, activeProvider: best.provider)
            case .unavailable:
                break
            }
        }

        if case let .plain(cachedPlain)? = cached {
            return .init(result: .plain(cachedPlain), activeProvider: cachedPlain.source)
        }

        self.cache[key] = CacheEntry(result: .unavailable, timestamp: Date())
        return .init(result: .unavailable, activeProvider: nil)
    }

    /// Publishes a result only if it still belongs to the latest search.
    private func applyResolvedLyrics(_ resolved: ResolvedLyrics, requestID: Int) {
        guard requestID == self.fetchGeneration else { return }

        if case let .synced(synced) = resolved.result {
            self.currentBaseSyncedLyrics = synced
            self.currentLyrics = .synced(self.displayLyrics(from: synced))
        } else {
            self.currentBaseSyncedLyrics = nil
            self.currentLyrics = resolved.result
        }

        self.activeProvider = resolved.activeProvider
        self.isLoading = false
    }

    /// Restores source attribution when serving a cached result.
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
