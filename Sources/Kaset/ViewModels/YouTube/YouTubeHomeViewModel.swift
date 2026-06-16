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

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    /// Loads the home feed if not already loaded.
    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        do {
            // Continue Watching reads history (a different endpoint), so start
            // it concurrently with the home feed. Chips and shelves come from
            // the SAME `FEwhat_to_watch` response, so await the home feed first
            // to warm the cache, then read them as cache hits rather than
            // racing three identical network requests.
            async let continueWatching = self.continueWatchingSection()
            let feed = try await client.getHomeFeed()

            // Shelves and topics both read the now-cached home response for
            // their chip/shelf data; their topic browses (slow) fan out from
            // there. Shelves are a cache hit, so awaiting them before first
            // paint is cheap and lets us de-duplicate the grid (below).
            async let shelvesTask = self.shelfSections()
            async let topics = self.topicSections()
            let shelves = await shelvesTask

            try Task.checkCancellation()
            guard generation == self.loadGeneration else { return }

            // `YouTubeFeedParser.parse` collects shelf videos into `feed.videos`
            // too, and the shelf rail surfaces them again — exclude shelf video
            // IDs from the grid so a shelf video is not rendered twice (once in
            // its rail, once under "For you"). Stored so continuation pages
            // apply the same filter.
            self.shelfVideoIDs = Set(shelves.flatMap { section in section.videos.map(\.videoId) })
            let gridVideos = feed.videos.filter { !self.shelfVideoIDs.contains($0.videoId) }

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
                // Publish the new grid with a cleared rail set so a reload (a
                // `.task` restart after a prior load) never renders the previous
                // load's Continue Watching/topic rails above the fresh grid
                // while the new rail fetches are still in flight. The new rails
                // populate below once they resolve.
                self.sections = []
                self.loadingState = .loaded
            }

            var sections: [YouTubeHomeSection] = []
            if let continueWatching = await continueWatching {
                sections.append(continueWatching)
            }
            sections.append(contentsOf: shelves)
            await sections.append(contentsOf: topics)

            // The section helpers isolate per-rail failures by resolving to
            // empty rather than throwing — including when a cancelled `.task`
            // makes their requests fail. Surface that cancellation here so a
            // cancelled load aborts instead of publishing empty rails (or
            // marking an empty grid `.loaded`) as if it had succeeded.
            try Task.checkCancellation()
            guard generation == self.loadGeneration else { return }
            self.sections = sections
            // Only flip the state here when the grid did not already publish it,
            // so a concurrent loadMore()'s `.loadingMore` is not clobbered.
            if !gridReady {
                self.loadingState = .loaded
            }
        } catch {
            guard generation == self.loadGeneration else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube home feed: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Forces a fresh reload (e.g. after account switches).
    func refresh() async {
        self.loadingState = .idle
        self.videos = []
        self.sections = []
        self.shelfVideoIDs = []
        await self.load()
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

    /// The home response's own titled shelves (e.g. "Breaking news").
    private func shelfSections() async -> [YouTubeHomeSection] {
        do {
            return try await self.client.getHomeShelves()
        } catch {
            if !(error is CancellationError) {
                self.logger.error("Home shelves unavailable: \(error.localizedDescription)")
            }
            return []
        }
    }

    /// One rail per personalized filter-chip topic, fetched concurrently and
    /// returned in chip order. Empty topic feeds are dropped.
    private func topicSections() async -> [YouTubeHomeSection] {
        let chips: [YouTubeHomeChip]
        do {
            chips = try await Array(self.client.getHomeChips().prefix(Self.topicRailCap))
        } catch {
            if !(error is CancellationError) {
                self.logger.error("Home chips unavailable: \(error.localizedDescription)")
            }
            return []
        }
        guard !chips.isEmpty else { return [] }

        // Fetch all topic feeds concurrently, preserving chip order via index.
        let indexed = await withTaskGroup(of: (Int, YouTubeHomeSection?).self) { group in
            for (index, chip) in chips.enumerated() {
                group.addTask {
                    await (index, self.topicSection(for: chip))
                }
            }
            var collected: [(Int, YouTubeHomeSection?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        return indexed
            .sorted { $0.0 < $1.0 }
            .compactMap(\.1)
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
