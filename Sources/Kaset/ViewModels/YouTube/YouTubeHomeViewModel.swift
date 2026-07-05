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
    private static let guestFallbackRailCap = 20
    private static let topicRailCap = 8

    /// Public destination rails used when signed-out Home returns YouTube's empty
    /// recommendation shell. These are browseable without a user account and keep
    /// Home useful in guest mode instead of showing a dead "no recommendations" state.
    private static let guestFallbackDestinations: [YouTubeDestination] = [
        .news,
        .sports,
        .gaming,
        .learning,
    ]

    /// Backstop on how many fully-filtered continuation pages `loadMore()` will
    /// walk in one call before giving up, so a pathological feed (every page's
    /// videos already shown) can't spin indefinitely.
    private static let maxEmptyContinuationPages = 5

    /// Delay before rebuilding Continue Watching after a video is watched, so
    /// YouTube's server-side history (which the embedded player updates, not
    /// Kaset) has a moment to record the new resume percent. Injectable so tests
    /// don't wait. Mirrors `HistoryViewModel.playbackRefreshDelay`.
    static var continueWatchingRefreshDelay: Duration = .seconds(3)

    /// Retry delay when the first post-watch rebuild sees unchanged history
    /// (server lag); a single retry catches the common case.
    static var continueWatchingRefreshRetryDelay: Duration = .seconds(2)

    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    /// The single in-flight load, shared by concurrent `load()` callers so
    /// SwiftUI `.task` restarts coalesce onto one run instead of cancelling it.
    private var loadTask: Task<Void, Never>?

    /// The player's `watchActivityGeneration` the last time Continue Watching
    /// was successfully rebuilt. A return/observe with no newer generation is a
    /// no-op. This is a VM-LOCAL watermark — the player's generation is never
    /// "consumed"; this only advances after a confirmed rebuild, so a refresh
    /// firing for one event can't suppress a refresh for a genuinely later one.
    private var lastReflectedGeneration = 0

    /// A watch-activity generation that arrived before Home could rebuild the
    /// rail in place (still loading, or the initial rail streamer is mid-flight
    /// and would clobber a separate refresh). `performLoad` consumes it once the
    /// feed has settled, forcing a cache-bypassed Continue Watching rebuild —
    /// otherwise a cold Home opened right after watching (with a warm `FEhistory`
    /// cache, e.g. from the History screen) would build the rail from stale
    /// pre-watch progress. Decouples the fix from `.task`/`.onChange` ordering.
    private var pendingGeneration: Int?

    /// True while `performLoad` is streaming the initial rails (Continue Watching
    /// + topics) into `sections`. The streamer is the sole writer of `sections`
    /// during that window, so a concurrent post-watch refresh must defer (park as
    /// pending) rather than race it as a second writer and risk being overwritten
    /// by a late streamer publish.
    private var isStreamingInitialRails = false

    /// The in-flight post-watch Continue Watching rebuild, cancelled/replaced
    /// when a newer watch supersedes it. Stored (unstructured) so it survives
    /// the triggering view's teardown.
    private var continueWatchingRefreshTask: Task<Void, Never>?

    /// The target generation of `continueWatchingRefreshTask` while it is in
    /// flight (e.g. sitting in its propagation delay), else `nil`. `refresh()`
    /// folds this back into `pendingGeneration` before cancelling the task, so a
    /// pull-to-refresh/error-retry that interrupts a still-delayed post-watch
    /// rebuild doesn't lose it — the ensuing `performLoad` drains it and rebuilds
    /// from fresh history instead of leaving the rail on pre-watch progress.
    private var inFlightRefreshGeneration: Int?

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
            // Only clear shared handles if they still point at THIS run. A stale
            // run resuming late must not wipe a newer run's task OR clear the
            // newer run's streaming guard (which would drop the guard while the
            // newer streamer is still the sole writer of `sections`, reopening the
            // refresh-vs-streamer race).
            if self.loadGeneration == token {
                self.loadTask = nil
                self.isStreamingInitialRails = false
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

            let chips = Array(bundle.chips.prefix(Self.topicRailCap))

            let mayNeedGuestFallback = gridVideos.isEmpty && shelves.isEmpty && chips.isEmpty

            // Stream the rails in as each resolves; the streamer is the single
            // writer of `sections` and prepends Continue Watching when its
            // (concurrent) history fetch lands. See streamTopicRails. Mark the
            // window so a concurrent post-watch refresh defers instead of racing
            // the streamer (which would otherwise overwrite a refreshed rail).
            // Only the current generation may own the guard.
            guard generation == self.loadGeneration else { return }
            self.isStreamingInitialRails = true
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
            // Streaming is done — `sections` is now stable, so a deferred
            // post-watch refresh can safely rebuild the rail in place. Only clear
            // the guard if this run still owns it (a newer load may have taken
            // over while we were streaming); the defer is the backstop.
            if generation == self.loadGeneration {
                self.isStreamingInitialRails = false
            }

            // Empty grid: flip the initial-load skeleton to `.loaded` so the
            // "No recommendations" placeholder can show. Only from `.loading` —
            // if `loadMore()` started a continuation (empty first page with
            // `hasMoreVideos`), don't clobber its `.loadingMore`.
            try Task.checkCancellation()
            guard generation == self.loadGeneration else { return }
            if mayNeedGuestFallback, self.sections.isEmpty {
                // Signed-out YouTube Home can legally return an empty recommendation
                // shell. Only fall back after the Continue Watching attempt: an
                // authenticated user can have an empty Home response while history
                // is still the sole useful rail.
                await self.loadGuestFallbackRails(generation: generation)
                return
            }

            if !gridReady, self.loadingState == .loading {
                self.loadingState = .loaded
            }

            // A watch happened while Home was still loading or streaming its
            // rails (opened cold right after watching, or returned mid-stream).
            // The rail just built above may have come from a warm pre-watch
            // `FEhistory` cache, so run the scoped, cache-bypassed refresh now
            // that the feed has settled. Consuming the pending generation here
            // (rather than in the view) makes the fix independent of whether
            // `.task` or the selection/path `.onChange` fired first.
            if let pending = self.pendingGeneration {
                self.pendingGeneration = nil
                self.refreshContinueWatching(forGeneration: pending)
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
        // A still-delayed post-watch refresh is about to be cancelled; fold its
        // target generation into `pendingGeneration` so the ensuing `performLoad`
        // drains it and rebuilds from fresh history. Without this, a
        // pull-to-refresh/error-retry that interrupts the propagation delay would
        // lose the post-watch trigger and leave the rail on pre-watch progress.
        if let inFlight = self.inFlightRefreshGeneration {
            self.pendingGeneration = max(self.pendingGeneration ?? 0, inFlight)
            self.inFlightRefreshGeneration = nil
        }
        self.continueWatchingRefreshTask?.cancel()
        self.continueWatchingRefreshTask = nil
        // Deliberately preserve `pendingGeneration`: this is also the
        // error-retry path, and a post-watch trigger queued during a failed cold
        // load must survive the retry so the ensuing `performLoad` rebuilds
        // Continue Watching from fresh (not warm pre-watch) history. An account
        // switch clears it separately via `cancelLoad()`.
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
        self.continueWatchingRefreshTask?.cancel()
        self.continueWatchingRefreshTask = nil
        self.pendingGeneration = nil
        self.inFlightRefreshGeneration = nil
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

    /// Started-but-unfinished videos from watch history (deduped, capped), or
    /// `nil` on failure / when nothing is resumable. Used by the initial load,
    /// where a failed history fetch should simply omit the rail (the cached
    /// path). The post-watch rebuild calls `fetchContinueWatchingSection`
    /// directly so it can both force-refresh and distinguish failure from empty.
    private func continueWatchingSection() async -> YouTubeHomeSection? {
        try? await self.fetchContinueWatchingSection(forceRefresh: false)
    }

    /// Fetches watch history and builds the Continue Watching section, throwing
    /// on fetch failure and returning `nil` only when the (successful) response
    /// has nothing resumable. The post-watch rebuild needs this distinction: a
    /// transient failure must keep the existing rail, not clear it.
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

    // MARK: - Continue Watching Refresh

    /// Outcome of one cache-bypassed Continue Watching rebuild attempt, so the
    /// retry logic can tell "history changed" from "history was unchanged" from
    /// "the fetch failed" — three cases that need different handling.
    private enum RailRefreshOutcome {
        /// Fresh history differed; the rail was updated.
        case updated
        /// Fresh history fetched successfully but matched what was shown.
        case unchanged
        /// The history fetch failed (network/auth/API); the rail was left as-is.
        case failed
    }

    /// Rebuilds only the Continue Watching rail after watch activity occurs and
    /// the user is (or returns) on Home, so a finished video drops out and a
    /// partially-watched one appears — without the full `refresh()` that wipes
    /// the grid and flashes the skeleton.
    ///
    /// `generation` is the player's monotonic `watchActivityGeneration`; the
    /// rebuild is a no-op when it isn't ahead of the last reflected generation,
    /// so incidental returns to Home (opening then backing out of a channel, say)
    /// don't re-fetch history, while ANY new watch activity — re-watching the
    /// same video, a skip, a finish, a drift — still triggers one. The work runs
    /// after a short delay (YouTube records watch progress server-side via the
    /// embedded player, not Kaset) and bypasses the 2 min history cache, retrying
    /// once if the first fetch shows no change or fails.
    func refreshContinueWatching(forGeneration generation: Int) {
        // Only rebuild for activity strictly newer than what's already reflected.
        guard generation > self.lastReflectedGeneration else { return }

        // Defer (park as pending) when the rail can't be safely rebuilt in place
        // yet, so the trigger is never dropped:
        //   - the initial load hasn't produced a rail (`idle`/`loading`/`error`)
        //   - the initial rail streamer is mid-flight and is the sole writer of
        //     `sections` (a concurrent rebuild would race it)
        // `performLoad` drains the pending generation once the feed settles. A
        // populated `.loaded` or a `.loadingMore` (pagination over an existing
        // grid) is fine to rebuild in place — pagination only appends grid
        // videos and never writes the Continue Watching rail.
        let canRebuildInPlace: Bool = switch self.loadingState {
        case .loaded, .loadingMore:
            !self.isStreamingInitialRails
        case .idle, .loading, .error:
            false
        }
        guard canRebuildInPlace else {
            // Keep the highest pending generation if several arrive while loading.
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
            // Clear the in-flight marker only if it still points at THIS run, so a
            // newer scheduled refresh (which overwrote it) keeps its marker.
            if self.inFlightRefreshGeneration == targetGeneration {
                self.inFlightRefreshGeneration = nil
            }
        }
        do {
            try await Task.sleep(for: Self.continueWatchingRefreshDelay)
        } catch {
            return // cancelled before any work; leave the watermark so a later return retries
        }

        var outcome = await self.rebuildContinueWatchingRail()
        // An unchanged result may mean server-side history hasn't caught up yet,
        // and a failure may be a transient blip — both warrant the single retry.
        if !Task.isCancelled, outcome != .updated {
            do {
                try await Task.sleep(for: Self.continueWatchingRefreshRetryDelay)
                if !Task.isCancelled {
                    outcome = await self.rebuildContinueWatchingRail()
                }
            } catch {
                // cancelled during the retry delay; fall through with the first outcome
            }
        }

        // Advance the watermark ONLY when the refresh actually reached the server
        // (updated or unchanged) and was not cancelled. A cancellation (e.g.
        // refresh()/account switch during the delay) or a hard failure leaves it
        // unchanged, so the next return to Home retries. `max` guards against a
        // late-finishing earlier task lowering a watermark a newer task advanced.
        guard !Task.isCancelled, outcome == .updated || outcome == .unchanged else { return }
        self.lastReflectedGeneration = max(self.lastReflectedGeneration, targetGeneration)
    }

    /// Fetches fresh history (cache-bypassed) and splices the resulting Continue
    /// Watching section into `sections` in place, leaving the grid, shelves, and
    /// topic rails untouched. On a fetch failure the existing rail is preserved.
    @discardableResult
    private func rebuildContinueWatchingRail() async -> RailRefreshOutcome {
        // The grid/shelves must already be published (loaded, or paginating over
        // an existing grid). Anything earlier means there's no rail to splice.
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
            // A transient network/auth/API failure must NOT clear an existing
            // rail; leave it untouched and let the caller retry.
            if !(error is CancellationError) {
                self.logger.error("Continue Watching refresh failed: \(error.localizedDescription)")
            }
            return .failed
        }
        guard !Task.isCancelled else { return .unchanged }

        let existing = self.sections.first { $0.kind == .continueWatching }
        // No change: same videos AND the same resume progress, in the same
        // order (or still absent). Comparing the percent — not just the id — is
        // load-bearing: the common case is the just-watched video staying in the
        // rail with a higher `watchedPercent` (e.g. 30 → 55). An id-only check
        // would treat that as unchanged and keep showing the stale progress bar.
        if existing.map(Self.railIdentity) == fresh.map(Self.railIdentity) {
            return .unchanged
        }

        var rebuilt = self.sections.filter { $0.kind != .continueWatching }
        if let fresh {
            rebuilt.insert(fresh, at: 0) // Continue Watching always leads.
        }
        self.sections = rebuilt
        return .updated
    }

    /// Change-detection key for the Continue Watching rail: each video's id
    /// paired with its resume percent, so a progress-only update still registers
    /// as a change.
    private static func railIdentity(_ section: YouTubeHomeSection) -> [String] {
        section.videos.map { video in "\(video.videoId):\(video.watchedPercent ?? 0)" }
    }

    // MARK: - Topic Rails

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
