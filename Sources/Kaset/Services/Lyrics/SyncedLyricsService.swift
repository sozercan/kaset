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

    private typealias IndexedProvider = (index: Int, provider: LyricsProvider)

    /// Current lyrics result.
    var currentLyrics: LyricResult = .unavailable

    /// Which provider supplied the current lyrics.
    var activeProvider: String?

    /// Loading state.
    var isLoading = false

    /// All registered providers, ordered by priority.
    private let providers: [LyricsProvider]

    var providerNames: [String] {
        self.providers.map(\.name)
    }

    /// Romanization service for transliterating non-Latin lyrics.
    private let romanizationService = RomanizationService()

    /// In-memory cache keyed by videoId.
    private var cache: [String: LyricResult] = [:]

    /// Provider-specific cache keyed by videoId, then provider name.
    private var providerCache: [String: [String: LyricResult]] = [:]

    /// Base synced lyrics before romanization is applied for display.
    private var currentBaseSyncedLyrics: SyncedLyrics?

    /// Monotonic identifier used to ignore stale in-flight searches.
    private var fetchGeneration = 0

    init(providers: [LyricsProvider] = [LRCLibProvider()]) {
        self.providers = providers
        self.observeRomanizationSetting()
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
            self.currentBaseSyncedLyrics = nil
            self.currentLyrics = cached
            self.activeProvider = Self.cachedProviderName(for: cached)
        }

        self.isLoading = true

        let indexedProviders = self.providers.enumerated().map { (index: $0.offset, provider: $0.element) }
        let syncedCapableProviders = indexedProviders.filter { Self.isSyncedCapableProvider($0.provider) }
        let plainFallbackProviders = indexedProviders.filter { !Self.isSyncedCapableProvider($0.provider) }

        var allResults = await self.fetchProviderResults(for: info, from: syncedCapableProviders)
        if allResults.contains(where: { self.resultRank($0.result) == 2 }) {
            let resolved = self.resolveLyrics(best: self.bestResult(in: allResults), cached: cached, videoId: info.videoId)
            self.applyResolvedLyrics(resolved, requestID: requestID)
            return
        }

        if !plainFallbackProviders.isEmpty {
            allResults += await self.fetchProviderResults(for: info, from: plainFallbackProviders)
        }

        let resolved = self.resolveLyrics(best: self.bestResult(in: allResults), cached: cached, videoId: info.videoId)
        self.applyResolvedLyrics(resolved, requestID: requestID)
    }

    func fetchLyrics(for info: LyricsSearchInfo, providerName: String) async {
        self.fetchGeneration += 1
        let requestID = self.fetchGeneration

        self.isLoading = true
        let result: LyricResult
        if let cached = self.providerCache[info.videoId]?[providerName] {
            result = cached
        } else if let provider = self.providers.first(where: { $0.name == providerName }) {
            result = await provider.search(info: info)
            self.providerCache[info.videoId, default: [:]][providerName] = result
        } else {
            result = .unavailable
        }

        if case .synced = result {
            self.cache[info.videoId] = result
        }

        self.applyResolvedLyrics(
            .init(
                result: result,
                activeProvider: providerName
            ),
            requestID: requestID
        )
    }

    /// Fallback logic
    func fallbackToPlainLyrics(_ lyrics: Lyrics, videoId: String) {
        if case .synced = self.currentLyrics {
            // Already synced, don't overwrite with plain
            return
        }

        self.currentBaseSyncedLyrics = nil

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

    private func refreshCurrentRomanization() {
        guard let baseLyrics = self.currentBaseSyncedLyrics else { return }
        self.currentLyrics = .synced(self.displayLyrics(from: baseLyrics))
    }

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

    private func fetchProviderResults(
        for info: LyricsSearchInfo,
        from indexedProviders: [IndexedProvider]
    ) async -> [ProviderResult] {
        guard !indexedProviders.isEmpty else { return [] }

        var allResults: [ProviderResult] = []
        await withTaskGroup(of: ProviderResult?.self) { group in
            for indexedProvider in indexedProviders {
                group.addTask {
                    let result = await indexedProvider.provider.search(info: info)
                    return ProviderResult(
                        provider: indexedProvider.provider.name,
                        providerIndex: indexedProvider.index,
                        result: result
                    )
                }
            }

            for await res in group {
                if let res {
                    allResults.append(res)
                    self.providerCache[info.videoId, default: [:]][res.provider] = res.result
                }
            }
        }

        return allResults
    }

    private func bestResult(in results: [ProviderResult]) -> ProviderResult? {
        var best: ProviderResult?
        for candidate in results {
            guard let currentBest = best else {
                best = candidate
                continue
            }

            if self.isBetter(candidate, than: currentBest) {
                best = candidate
            }
        }

        return best
    }

    private func isBetter(_ candidate: ProviderResult, than currentBest: ProviderResult) -> Bool {
        let candidateRank = self.resultRank(candidate.result)
        let currentRank = self.resultRank(currentBest.result)
        if candidateRank != currentRank {
            // Per-track synced lyrics always win over plain lyrics, regardless
            // of the configured default provider.
            return candidateRank > currentRank
        }

        let preferredProvider = SettingsManager.shared.defaultLyricsProvider.rawValue
        let candidateIsPreferred = candidate.provider == preferredProvider
        let currentIsPreferred = currentBest.provider == preferredProvider
        if candidateIsPreferred != currentIsPreferred {
            return candidateIsPreferred
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

    private func resolveLyrics(
        best: ProviderResult?,
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

    private static func isSyncedCapableProvider(_ provider: LyricsProvider) -> Bool {
        provider.name == "YTMusic" || provider.name == "LRCLib"
    }
}
