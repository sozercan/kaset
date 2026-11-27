import Foundation
import Observation

@MainActor
@Observable
final class YouTubeHomeViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var sections: [YouTubeHomeSection] = []

    private(set) var videos: [YouTubeVideo] = []

    private(set) var hasMoreVideos = true

    private(set) var paginationCursorGeneration = 0

    private(set) var hasMoreTopicRails = false

    private(set) var isLoadingTopicRails = false

    private var shelfVideoIDs: Set<String> = []

    private var pendingTopicChips: [YouTubeHomeChip] = []

    private var pendingTopicChipsForceRefresh = false

    private static let continueWatchingRange = 1 ... 95

    private static let continueWatchingCap = 20
    private static let guestFallbackRailCap = 20
    private static let topicRailCap = 8
    private static let initialTopicRailBatchSize = 2

    private static let guestFallbackDestinations: [YouTubeDestination] = [
        .news,
        .sports,
        .gaming,
        .learning,
    ]

    private static let maxEmptyContinuationPages = 5

    static var continueWatchingRefreshDelay: Duration = .seconds(3)

    static var continueWatchingRefreshRetryDelay: Duration = .seconds(2)

    var continueWatchingRefreshDelayOverride: Duration?
    var continueWatchingRefreshRetryDelayOverride: Duration?

    private var loadGeneration = 0

    private var loadTask: Task<Void, Never>?

    private var lastReflectedGeneration = 0

    private var pendingGeneration: Int?

    private var isStreamingInitialRails = false

    private var continueWatchingRefreshTask: Task<Void, Never>?

    private var inFlightRefreshGeneration: Int?

    private var seenContinuationTokens: Set<String> = []

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(
        client: any YouTubeClientProtocol,
        continueWatchingRefreshDelay: Duration? = nil,
        continueWatchingRefreshRetryDelay: Duration? = nil
    ) {
        self.client = client
        self.continueWatchingRefreshDelayOverride = continueWatchingRefreshDelay
        self.continueWatchingRefreshRetryDelayOverride = continueWatchingRefreshRetryDelay
    }

    func load() async {
        await self.load(forceRefresh: false)
    }

    private func load(forceRefresh: Bool) async {
        if case .loaded = self.loadingState {
            return
        }
        if let existing = self.loadTask {
            await existing.value
            return
        }
        self.loadGeneration += 1
        let token = self.loadGeneration
        let task = Task { await self.performLoad(token: token, forceRefresh: forceRefresh) }
        self.loadTask = task
        await task.value
    }

    private func performLoad(token: Int, forceRefresh: Bool) async {
        defer {
            if self.loadGeneration == token {
                self.loadTask = nil
                self.isStreamingInitialRails = false
            }
        }
        let generation = token
        self.loadingState = .loading
        do {
            let bundle = try await client.getHomeBundle(forceRefresh: forceRefresh)

            let shelves = bundle.shelves

            try Task.checkCancellation()
            guard generation == self.loadGeneration else { return }
            self.pendingTopicChips = []
            self.pendingTopicChipsForceRefresh = false
            self.hasMoreTopicRails = false
            self.isLoadingTopicRails = false

            self.shelfVideoIDs = Set(shelves.flatMap { section in section.videos.map(\.videoId) })
            let gridVideos = bundle.feed.videos.filter { !self.shelfVideoIDs.contains($0.videoId) }

            self.videos = gridVideos
            self.seenContinuationTokens = []
            if let initialContinuation = bundle.feed.continuation {
                self.seenContinuationTokens.insert(initialContinuation)
            }
            self.hasMoreVideos = self.client.hasMoreHomeFeed
            let gridReady = !gridVideos.isEmpty
            if gridReady {
                self.loadingState = .loaded
            }

            if !shelves.isEmpty {
                self.sections = shelves
                if !gridReady {
                    self.loadingState = .loaded
                }
            }

            let cappedChips = Array(bundle.chips.prefix(Self.topicRailCap))
            let initialChips = Array(cappedChips.prefix(Self.initialTopicRailBatchSize))
            self.pendingTopicChips = Array(cappedChips.dropFirst(initialChips.count))
            self.pendingTopicChipsForceRefresh = forceRefresh && !self.pendingTopicChips.isEmpty

            let mayNeedGuestFallback = gridVideos.isEmpty && shelves.isEmpty

            guard generation == self.loadGeneration else { return }
            self.isStreamingInitialRails = true
            await self.streamTopicRails(
                chips: initialChips,
                shelves: shelves,
                gridReady: gridReady,
                generation: generation,
                forceRefresh: forceRefresh
            )
            if generation == self.loadGeneration {
                self.isStreamingInitialRails = false
            }

            if try await self.settleInitialEmptyHomeIfNeeded(
                mayNeedGuestFallback: mayNeedGuestFallback,
                gridReady: gridReady,
                generation: generation
            ) {
                return
            }

            if let pending = self.pendingGeneration {
                self.pendingGeneration = nil
                self.refreshContinueWatching(forGeneration: pending)
            }
        } catch {
            guard generation == self.loadGeneration else { return }
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube home feed: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func settleInitialEmptyHomeIfNeeded(
        mayNeedGuestFallback: Bool,
        gridReady: Bool,
        generation: Int
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard generation == self.loadGeneration else { return true }

        self.hasMoreTopicRails = !self.pendingTopicChips.isEmpty
        while mayNeedGuestFallback, self.sections.isEmpty, !self.pendingTopicChips.isEmpty {
            await self.loadNextTopicRailBatch(
                generation: generation,
                gridReady: gridReady,
                batchSize: Self.initialTopicRailBatchSize,
                preserveOnFailure: false
            )
            try Task.checkCancellation()
            guard generation == self.loadGeneration else { return true }
        }

        self.hasMoreTopicRails = !self.pendingTopicChips.isEmpty
        if mayNeedGuestFallback, self.sections.isEmpty, self.pendingTopicChips.isEmpty {
            await self.loadGuestFallbackRails(generation: generation)
            return true
        }

        if !gridReady, self.loadingState == .loading {
            self.loadingState = .loaded
        }
        return false
    }

    private func loadGuestFallbackRails(generation: Int) async {
        self.logger.info("YouTube home returned empty recommendations; loading public guest fallback rails")

        let guestFallbackRailCap = Self.guestFallbackRailCap
        var slots = [YouTubeHomeSection?](repeating: nil, count: Self.guestFallbackDestinations.count)
        await withTaskGroup(of: (Int, YouTubeHomeSection?).self) { group in
            for (index, destination) in Self.guestFallbackDestinations.enumerated() {
                group.addTask { [client] in
                    do {
                        let feed = try await client.getDestinationFeed(destination)
                        let videos = Array(feed.videos.prefix(guestFallbackRailCap))
                        guard !videos.isEmpty else { return (index, nil) }
                        return (
                            index,
                            YouTubeHomeSection(
                                id: "guest-\(destination.rawValue)",
                                title: destination.displayName,
                                videos: videos,
                                kind: .shelf
                            )
                        )
                    } catch {
                        return (index, nil)
                    }
                }
            }

            for await (index, section) in group {
                guard generation == self.loadGeneration else { return }
                slots[index] = section
                let resolved = slots.compactMap(\.self)
                if !resolved.isEmpty {
                    self.sections = resolved
                    self.loadingState = .loaded
                }
            }
        }

        guard generation == self.loadGeneration else { return }
        self.hasMoreVideos = false
        if self.loadingState == .loading {
            self.loadingState = .loaded
        }
    }

    private func streamTopicRails(
        chips: [YouTubeHomeChip],
        shelves: [YouTubeHomeSection],
        gridReady: Bool,
        generation: Int,
        forceRefresh: Bool
    ) async {
        var topicSlot = [YouTubeHomeSection?](repeating: nil, count: chips.count)
        var continueWatchingRail: YouTubeHomeSection?

        func publish() {
            guard generation == self.loadGeneration else { return }
            var next: [YouTubeHomeSection] = []
            if let continueWatchingRail {
                next.append(continueWatchingRail)
            }
            next.append(contentsOf: shelves)
            next.append(contentsOf: topicSlot.compactMap(\.self))
            self.sections = next
            if !gridReady, !next.isEmpty, self.loadingState == .loading {
                self.loadingState = .loaded
            }
        }

        await withTaskGroup(of: (Int, YouTubeHomeSection?).self) { group in
            group.addTask {
                await (-1, self.continueWatchingSection(forceRefresh: forceRefresh))
            }
            for (index, chip) in chips.enumerated() {
                group.addTask {
                    await (index, self.topicSection(for: chip, forceRefresh: forceRefresh))
                }
            }
            for await (index, section) in group {
                if index == -1 {
                    continueWatchingRail = section
                } else {
                    topicSlot[index] = section
                }
                publish()
            }
        }
    }

    @discardableResult
    private func loadNextTopicRailBatch(
        generation: Int,
        gridReady: Bool,
        batchSize: Int,
        preserveOnFailure: Bool
    ) async -> TopicBatchLoadOutcome {
        guard generation == self.loadGeneration, !self.pendingTopicChips.isEmpty else { return .stale }

        let batch = Array(self.pendingTopicChips.prefix(batchSize))
        self.pendingTopicChips.removeFirst(batch.count)
        self.hasMoreTopicRails = !self.pendingTopicChips.isEmpty

        let forceRefresh = self.pendingTopicChipsForceRefresh
        let result = await self.topicSections(for: batch, forceRefresh: forceRefresh)
        guard generation == self.loadGeneration else { return .stale }

        if preserveOnFailure, !result.failedChips.isEmpty {
            self.pendingTopicChips.append(contentsOf: result.failedChips)
        }
        self.hasMoreTopicRails = !self.pendingTopicChips.isEmpty
        if self.pendingTopicChips.isEmpty {
            self.pendingTopicChipsForceRefresh = false
        }

        guard !result.sections.isEmpty else {
            return preserveOnFailure && !result.failedChips.isEmpty ? .failed : .empty
        }

        self.sections.append(contentsOf: result.sections)
        if !gridReady, self.loadingState == .loading {
            self.loadingState = .loaded
        }
        return .appended
    }

    private func topicSections(
        for chips: [YouTubeHomeChip],
        forceRefresh: Bool
    ) async -> TopicBatchFetchResult {
        var slots = [TopicFetchOutcome?](repeating: nil, count: chips.count)
        await withTaskGroup(of: (Int, TopicFetchOutcome).self) { group in
            for (index, chip) in chips.enumerated() {
                group.addTask {
                    await (index, self.topicFetchOutcome(for: chip, forceRefresh: forceRefresh))
                }
            }
            for await (index, outcome) in group {
                slots[index] = outcome
            }
        }

        var sections: [YouTubeHomeSection] = []
        var failedChips: [YouTubeHomeChip] = []
        for (index, outcome) in slots.enumerated() {
            guard let outcome else { continue }
            switch outcome {
            case let .section(section):
                sections.append(section)
            case .empty:
                break
            case .failed:
                failedChips.append(chips[index])
            }
        }
        return TopicBatchFetchResult(sections: sections, failedChips: failedChips)
    }

    func refresh() async {
        self.loadTask?.cancel()
        self.loadTask = nil
        if let inFlight = self.inFlightRefreshGeneration {
            self.pendingGeneration = max(self.pendingGeneration ?? 0, inFlight)
            self.inFlightRefreshGeneration = nil
        }
        self.continueWatchingRefreshTask?.cancel()
        self.continueWatchingRefreshTask = nil
        self.loadingState = .idle
        self.videos = []
        self.sections = []
        self.shelfVideoIDs = []
        self.pendingTopicChips = []
        self.pendingTopicChipsForceRefresh = false
        self.hasMoreTopicRails = false
        self.isLoadingTopicRails = false
        await self.load(forceRefresh: true)
    }

    func cancelLoad() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.continueWatchingRefreshTask?.cancel()
        self.continueWatchingRefreshTask = nil
        self.pendingGeneration = nil
        self.inFlightRefreshGeneration = nil
        self.pendingTopicChips = []
        self.pendingTopicChipsForceRefresh = false
        self.hasMoreTopicRails = false
        self.isLoadingTopicRails = false
    }

    func loadMoreTopicRails() async {
        guard self.hasMoreTopicRails, !self.isLoadingTopicRails, !self.isStreamingInitialRails else { return }

        let generation = self.loadGeneration
        self.isLoadingTopicRails = true
        defer {
            if generation == self.loadGeneration {
                self.isLoadingTopicRails = false
            }
        }

        var outcome: TopicBatchLoadOutcome = .empty
        repeat {
            outcome = await self.loadNextTopicRailBatch(
                generation: generation,
                gridReady: !self.videos.isEmpty,
                batchSize: Self.initialTopicRailBatchSize,
                preserveOnFailure: true
            )
        } while generation == self.loadGeneration && outcome == .empty && self.hasMoreTopicRails
    }

    func loadMore() async {
        guard self.loadingState == .loaded, self.hasMoreVideos else { return }

        self.loadingState = .loadingMore
        do {
            var didAdvanceCursor = false
            for _ in 0 ..< Self.maxEmptyContinuationPages {
                guard let feed = try await client.getHomeFeedContinuation() else {
                    self.hasMoreVideos = false
                    break
                }
                var existing = Set(self.videos.map(\.videoId))
                let newVideos = feed.videos.filter { video in
                    !self.shelfVideoIDs.contains(video.videoId) && existing.insert(video.videoId).inserted
                }
                self.videos.append(contentsOf: newVideos)

                if let token = feed.continuation {
                    if !self.seenContinuationTokens.insert(token).inserted {
                        self.hasMoreVideos = false
                        break
                    }
                    didAdvanceCursor = true
                }

                self.hasMoreVideos = self.client.hasMoreHomeFeed
                if !newVideos.isEmpty || !self.hasMoreVideos {
                    break
                }
            }
            if didAdvanceCursor, self.hasMoreVideos {
                self.paginationCursorGeneration &+= 1
            }
            self.loadingState = .loaded
        } catch {
            if error is CancellationError {
                self.loadingState = .loaded
                return
            }
            self.logger.error("Failed to load more YouTube home feed: \(error.localizedDescription)")
            self.loadingState = .loaded
            self.hasMoreVideos = false
        }
    }

    private func continueWatchingSection(forceRefresh: Bool) async -> YouTubeHomeSection? {
        try? await self.fetchContinueWatchingSection(forceRefresh: forceRefresh)
    }

    private func fetchContinueWatchingSection(forceRefresh: Bool) async throws -> YouTubeHomeSection? {
        let history = try await self.client.getHistory(forceRefresh: forceRefresh)
        var seen = Set<String>()
        let resumable = history.videos.filter { video in
            guard let percent = video.watchedPercent,
                  Self.continueWatchingRange.contains(percent),
                  !video.isShort,
                  !video.isLive
            else {
                return false
            }
            return seen.insert(video.videoId).inserted
        }
        .prefix(Self.continueWatchingCap)

        guard !resumable.isEmpty else { return nil }
        return YouTubeHomeSection(
            id: "continue-watching",
            title: String(localized: "Continue Watching", comment: "YouTube home rail of partially-watched videos"),
            videos: Array(resumable),
            kind: .continueWatching
        )
    }

    private enum RailRefreshOutcome {
        case updated
        case unchanged
        case failed
    }

    func refreshContinueWatching(forGeneration generation: Int) {
        guard generation > self.lastReflectedGeneration else { return }

        let canRebuildInPlace: Bool = switch self.loadingState {
        case .loaded, .loadingMore:
            !self.isStreamingInitialRails
        case .idle, .loading, .error:
            false
        }
        guard canRebuildInPlace else {
            self.pendingGeneration = max(self.pendingGeneration ?? 0, generation)
            return
        }

        self.continueWatchingRefreshTask?.cancel()
        self.inFlightRefreshGeneration = generation
        self.continueWatchingRefreshTask = Task { [weak self] in
            await self?.performContinueWatchingRefresh(targetGeneration: generation)
        }
    }

    private func performContinueWatchingRefresh(targetGeneration: Int) async {
        defer {
            if self.inFlightRefreshGeneration == targetGeneration {
                self.inFlightRefreshGeneration = nil
            }
        }
        do {
            try await Task.sleep(for: self.continueWatchingRefreshDelayOverride ?? Self.continueWatchingRefreshDelay)
        } catch {
            return
        }

        var outcome = await self.rebuildContinueWatchingRail()
        if !Task.isCancelled, outcome != .updated {
            do {
                try await Task.sleep(for: self.continueWatchingRefreshRetryDelayOverride ?? Self.continueWatchingRefreshRetryDelay)
                if !Task.isCancelled {
                    outcome = await self.rebuildContinueWatchingRail()
                }
            } catch {}
        }

        guard !Task.isCancelled, outcome == .updated || outcome == .unchanged else { return }
        self.lastReflectedGeneration = max(self.lastReflectedGeneration, targetGeneration)
    }

    @discardableResult
    private func rebuildContinueWatchingRail() async -> RailRefreshOutcome {
        switch self.loadingState {
        case .loaded, .loadingMore:
            break
        case .idle, .loading, .error:
            return .unchanged
        }

        let fresh: YouTubeHomeSection?
        do {
            fresh = try await self.fetchContinueWatchingSection(forceRefresh: true)
        } catch {
            if !(error is CancellationError) {
                self.logger.error("Continue Watching refresh failed: \(error.localizedDescription)")
            }
            return .failed
        }
        guard !Task.isCancelled else { return .unchanged }

        let existing = self.sections.first { $0.kind == .continueWatching }
        if existing.map(Self.railIdentity) == fresh.map(Self.railIdentity) {
            return .unchanged
        }

        var rebuilt = self.sections.filter { $0.kind != .continueWatching }
        if let fresh {
            rebuilt.insert(fresh, at: 0)
        }
        self.sections = rebuilt
        return .updated
    }

    private static func railIdentity(_ section: YouTubeHomeSection) -> [String] {
        section.videos.map { video in "\(video.videoId):\(video.watchedPercent ?? 0)" }
    }

    private enum TopicFetchOutcome {
        case section(YouTubeHomeSection)
        case empty
        case failed
    }

    private struct TopicBatchFetchResult {
        let sections: [YouTubeHomeSection]
        let failedChips: [YouTubeHomeChip]
    }

    private enum TopicBatchLoadOutcome {
        case appended
        case empty
        case failed
        case stale
    }

    private func topicFetchOutcome(
        for chip: YouTubeHomeChip,
        forceRefresh: Bool = false
    ) async -> TopicFetchOutcome {
        do {
            let feed = try await self.client.getHomeTopicFeed(
                continuation: chip.continuation,
                forceRefresh: forceRefresh
            )
            guard !feed.videos.isEmpty else { return .empty }
            return .section(
                YouTubeHomeSection(
                    id: "topic-\(chip.title)",
                    title: chip.title,
                    videos: feed.videos,
                    kind: .topic
                )
            )
        } catch {
            if !(error is CancellationError) {
                self.logger.error("Topic rail '\(chip.title)' unavailable: \(error.localizedDescription)")
            }
            return .failed
        }
    }

    private func topicSection(for chip: YouTubeHomeChip, forceRefresh: Bool) async -> YouTubeHomeSection? {
        switch await self.topicFetchOutcome(for: chip, forceRefresh: forceRefresh) {
        case let .section(section):
            section
        case .empty, .failed:
            nil
        }
    }
}
