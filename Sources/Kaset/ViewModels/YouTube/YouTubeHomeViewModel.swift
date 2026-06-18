import Foundation
import Observation

/// View model for the YouTube home (recommended) feed.
@MainActor
@Observable
final class YouTubeHomeViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Personalized side-scrolling sections shown above the recommendation
    /// grid: Continue Watching, the home response's own titled shelves, then a
    /// rail per personalized filter-chip topic. Empty until loaded.
    private(set) var sections: [YouTubeHomeSection] = []

    /// Videos to display in the feed grid.
    private(set) var videos: [YouTubeVideo] = []

    /// Whether more feed pages are available.
    private(set) var hasMoreVideos = true

    /// Video IDs already surfaced in titled shelf rails, excluded from the flat
    /// "For you" grid (including continuation pages) so a shelf video is never
    /// rendered twice.
    private var shelfVideoIDs: Set<String> = []

    /// Resume-progress band for the Continue Watching rail: started but not
    /// effectively finished. `nil`/0 = not started; ≥96 = finished.
    private static let continueWatchingRange = 1 ... 95

    /// Cap on Continue Watching items and on topic rails shown at first paint.
    private static let continueWatchingCap = 20
    private static let topicRailCap = 8

    /// Backstop on how many fully-filtered continuation pages `loadMore()` will
    /// walk in one call before giving up, so a pathological feed (every page's
    /// videos already shown) can't spin indefinitely.
    private static let maxEmptyContinuationPages = 5

    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    /// The single in-flight load, shared by concurrent `load()` callers so
    /// SwiftUI `.task` restarts coalesce onto one run instead of cancelling it.
    private var loadTask: Task<Void, Never>?

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    /// Loads the home feed once and keeps it. Safe to call repeatedly: SwiftUI
    /// restarts `.task` during launch/layout churn (the trace showed two fires
    /// ~18 ms apart on first paint), and a structured load would be cancelled by
    /// the restart while the next call bailed — leaving the model stuck at
    /// `.idle` with nothing running. Running the work in a stored UNSTRUCTURED
    /// `Task` decouples it from `.task` cancellation: the first call starts it,
    /// concurrent calls await the same task, and it runs to completion once.
    func load() async {
        if case .loaded = self.loadingState {
            return // Already loaded — a repeat is a no-op (don't refetch/wipe rails).
        }
        // Coalesce concurrent callers (rapid `.task` restarts) onto one run.
        if let existing = self.loadTask {
            await existing.value
            return
        }
        // Tag this run so only it clears the shared handle. Without the tag, a
        // cancelled earlier run resuming after refresh() started a new one would
        // null out the new run's handle (breaking single-flight: a concurrent
        // load() would see nil and start a duplicate fetch).
        self.loadGeneration += 1
        let token = self.loadGeneration
        let task = Task { await self.performLoad(token: token) }
        self.loadTask = task
        await task.value
    }

    private func performLoad(token: Int) async {
        defer {
            // Only clear the handle if it still points at THIS run. A stale run
            // resuming late must not wipe a newer run's task.
            if self.loadGeneration == token {
                self.loadTask = nil
            }
        }
        let generation = token
        self.loadingState = .loading
        do {
            // One request + one off-main parse yields the grid, the filter
            // chips, and the titled shelves together (they all live in the same
            // ~2 MB `FEwhat_to_watch` response). Replaces three separate
            // getHomeFeed/getHomeShelves/getHomeChips calls that each re-fetched
            // and re-walked the same blob on the main thread.
            let bundle = try await client.getHomeBundle()

            let shelves = bundle.shelves

            try Task.checkCancellation()
            guard generation == self.loadGeneration else { return }

            // `YouTubeFeedParser.parse` collects shelf videos into `feed.videos`
            // too, and the shelf rail surfaces them again — exclude shelf video
            // IDs from the grid so a shelf video is not rendered twice (once in
            // its rail, once under "For you"). Stored so continuation pages
            // apply the same filter.
            self.shelfVideoIDs = Set(shelves.flatMap { section in section.videos.map(\.videoId) })
            let gridVideos = bundle.feed.videos.filter { !self.shelfVideoIDs.contains($0.videoId) }

            // Publish the recommendation grid immediately so first paint does
            // not wait on the optional topic rails (chips fan out to several
            // browse requests; a slow one must not block the grid). When the
            // grid is empty, the rails are the only content worth showing, so
            // keep the loading state until they resolve to avoid flashing the
            // empty placeholder.
            self.videos = gridVideos
            self.hasMoreVideos = self.client.hasMoreHomeFeed
            let gridReady = !gridVideos.isEmpty
            if gridReady {
                self.loadingState = .loaded
            }

            // Publish the shelves immediately and start the topic rails now —
            // do NOT block on the watch-history request (it can be slow/retrying
            // and would otherwise delay the rails and keep an empty grid stuck on
            // the skeleton). The Continue Watching rail is inserted at the front
            // once history resolves.
            if !shelves.isEmpty {
                self.sections = shelves
                if !gridReady {
                    self.loadingState = .loaded // any content clears the skeleton
                }
            }

            // Stream the rails in as each resolves; the streamer is the single
            // writer of `sections` and prepends Continue Watching when its
            // (concurrent) history fetch lands. See streamTopicRails.
            let chips = Array(bundle.chips.prefix(Self.topicRailCap))
            await self.streamTopicRails(
                chips: chips,
                shelves: shelves,
                continueWatching: { [weak self] in
                    guard let self else { return nil }
                    return await self.continueWatchingSection()
                },
                gridReady: gridReady,
                generation: generation
            )

            // Empty grid: flip the initial-load skeleton to `.loaded` so the
            // "No recommendations" placeholder can show. Only from `.loading` —
            // if `loadMore()` started a continuation (empty first page with
            // `hasMoreVideos`), don't clobber its `.loadingMore`.
            try Task.checkCancellation()
            guard generation == self.loadGeneration else { return }
            if !gridReady, self.loadingState == .loading {
                self.loadingState = .loaded
            }
        } catch {
            guard generation == self.loadGeneration else { return }
            // A cancelled load (e.g. refresh() cancelled the in-flight task) is
            // not an error; reset so a subsequent load runs cleanly.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube home feed: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Streams the rails into `sections` as each resolves, as the single writer.
    ///
    /// Continue Watching (watch history, a separate and sometimes slow request)
    /// and the topic-chip browses all run concurrently here. Shelves are already
    /// known; each rail is revealed at its ordered slot the moment it lands, so
    /// rows appear as soon as ANY rail resolves rather than gating on the slowest
    /// (or on history). Final order is always: Continue Watching, shelves, then
    /// topic rails in chip order — a later rail may slot in above an
    /// already-shown one (a small upward settle), never an ~800 ms blank wait.
    private func streamTopicRails(
        chips: [YouTubeHomeChip],
        shelves: [YouTubeHomeSection],
        continueWatching: @escaping @Sendable () async -> YouTubeHomeSection?,
        gridReady: Bool,
        generation: Int
    ) async {
        // One result channel for both rail kinds: the history rail (index -1,
        // pinned to the front) and the topic rails (chip index >= 0).
        var topicSlot = [YouTubeHomeSection?](repeating: nil, count: chips.count)
        var continueWatchingRail: YouTubeHomeSection?

        func publish() {
            guard generation == self.loadGeneration else { return }
            var next: [YouTubeHomeSection] = []
            if let continueWatchingRail { next.append(continueWatchingRail) }
            next.append(contentsOf: shelves)
            next.append(contentsOf: topicSlot.compactMap(\.self))
            self.sections = next
            // Only clear the skeleton once there is actual content. The first
            // group result is often history returning nil (no resumable watch
            // history); flipping `.loaded` then — with topics still pending and
            // `next` empty — would flash the "No recommendations" state. The
            // genuinely-empty case is handled by the terminal `.loaded` in
            // performLoad after all rail work finishes. Only flip from the
            // initial-load `.loading` skeleton; never clobber a concurrent
            // `loadMore()`'s `.loadingMore` (that would let a second continuation
            // start before the first finishes).
            if !gridReady, !next.isEmpty, self.loadingState == .loading {
                self.loadingState = .loaded
            }
        }

        await withTaskGroup(of: (Int, YouTubeHomeSection?).self) { group in
            group.addTask { await (-1, continueWatching()) }
            for (index, chip) in chips.enumerated() {
                group.addTask {
                    await (index, self.topicSection(for: chip))
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

    /// Forces a fresh reload (e.g. after account switches).
    func refresh() async {
        // Cancel and drop any in-flight load so `load()` starts a fresh one
        // rather than awaiting the stale task.
        self.loadTask?.cancel()
        self.loadTask = nil
        self.loadingState = .idle
        self.videos = []
        self.sections = []
        self.shelfVideoIDs = []
        await self.load()
    }

    /// Cancels any in-flight load when this view model is being discarded (e.g.
    /// an account switch replaces it). The load runs in an unstructured `Task`
    /// that survives `.task` teardown, so without this the discarded model would
    /// keep using the shared `YouTubeClient` after the cache scope and providers
    /// moved to the new account — repopulating caches or clobbering
    /// `homeContinuation` with stale, wrong-account responses.
    func cancelLoad() {
        self.loadTask?.cancel()
        self.loadTask = nil
    }

    /// Loads the next feed page when the user nears the end of the grid.
    func loadMore() async {
        guard self.loadingState == .loaded, self.hasMoreVideos else { return }

        self.loadingState = .loadingMore
        do {
            // A continuation page can filter to nothing (all its videos already
            // appear in the grid or in a shelf rail) while more pages remain.
            // The only pagination trigger is the grid's `ProgressView` sentinel,
            // which won't re-fire if nothing was appended — so keep fetching
            // until at least one new video lands or the feed is exhausted. The
            // bound is a defensive backstop against a pathological feed.
            for _ in 0 ..< Self.maxEmptyContinuationPages {
                guard let feed = try await client.getHomeFeedContinuation() else {
                    self.hasMoreVideos = false
                    break
                }
                var existing = Set(self.videos.map(\.videoId))
                // Skip videos already in the grid and any that belong to a
                // titled shelf rail (consistent with the first page).
                let newVideos = feed.videos.filter { video in
                    !self.shelfVideoIDs.contains(video.videoId) && existing.insert(video.videoId).inserted
                }
                self.videos.append(contentsOf: newVideos)
                self.hasMoreVideos = self.client.hasMoreHomeFeed
                // Stop once this page added something, or there is nothing left
                // to try (a fully-filtered page with no further continuation).
                if !newVideos.isEmpty || !self.hasMoreVideos {
                    break
                }
            }
            self.loadingState = .loaded
        } catch {
            // A cancelled page load is not an error; allow retrying.
            if error is CancellationError {
                self.loadingState = .loaded
                return
            }
            self.logger.error("Failed to load more YouTube home feed: \(error.localizedDescription)")
            // Keep existing content; just stop paginating on error.
            self.loadingState = .loaded
            self.hasMoreVideos = false
        }
    }

    // MARK: - Sections

    /// Started-but-unfinished videos from watch history (deduped, capped).
    private func continueWatchingSection() async -> YouTubeHomeSection? {
        do {
            let history = try await self.client.getHistory()
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
        } catch {
            if !(error is CancellationError) {
                self.logger.error("Continue Watching unavailable: \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// Browses a single chip token into a topic section, or `nil` on
    /// failure / empty result.
    private func topicSection(for chip: YouTubeHomeChip) async -> YouTubeHomeSection? {
        do {
            let feed = try await self.client.getHomeTopicFeed(continuation: chip.continuation)
            guard !feed.videos.isEmpty else { return nil }
            return YouTubeHomeSection(
                id: "topic-\(chip.title)",
                title: chip.title,
                videos: feed.videos,
                kind: .topic
            )
        } catch {
            if !(error is CancellationError) {
                self.logger.error("Topic rail '\(chip.title)' unavailable: \(error.localizedDescription)")
            }
            return nil
        }
    }
}
