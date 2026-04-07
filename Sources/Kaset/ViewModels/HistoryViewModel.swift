import Foundation
import Observation
import os

/// View model for the History view.
@MainActor
@Observable
final class HistoryViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// History sections to display (grouped by time: Today, Yesterday, etc.).
    private(set) var sections: [HomeSection] = []

    /// Whether more sections are available to load.
    private(set) var hasMoreSections: Bool = true

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.history
    // swiftformat:disable modifierOrder
    /// Task for background loading, cancelled in deinit.
    nonisolated(unsafe) private var backgroundLoadTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder

    /// Number of background continuations loaded.
    private var continuationsLoaded = 0

    /// Maximum continuations to load in background.
    private static let maxContinuations = 4

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    deinit {
        self.backgroundLoadTask?.cancel()
    }

    /// Loads history content with fast initial load.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        self.logger.info("Loading history content")

        do {
            let response = try await client.getHistory()
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreHistorySections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
            let sectionCount = self.sections.count
            self.logger.info("History content loaded: \(sectionCount) sections")

            self.startBackgroundLoading()
        } catch is CancellationError {
            self.logger.debug("History load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load history: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Loads more sections in the background progressively.
    private func startBackgroundLoading() {
        self.backgroundLoadTask?.cancel()
        self.backgroundLoadTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else { return }

            await self.loadMoreSections()
        }
    }

    /// Loads additional sections from continuations progressively.
    private func loadMoreSections() async {
        while self.hasMoreSections, self.continuationsLoaded < Self.maxContinuations {
            guard self.loadingState == .loaded else { break }

            do {
                if let additionalSections = try await client.getHistoryContinuation() {
                    self.sections.append(contentsOf: additionalSections)
                    self.continuationsLoaded += 1
                    self.hasMoreSections = self.client.hasMoreHistorySections
                    let continuationNum = self.continuationsLoaded
                    self.logger.info("Background loaded \(additionalSections.count) more history sections (continuation \(continuationNum))")
                } else {
                    self.hasMoreSections = false
                    break
                }
            } catch is CancellationError {
                self.logger.debug("Background history loading cancelled")
                break
            } catch {
                self.logger.warning("Background history section load failed: \(error.localizedDescription)")
                break
            }
        }

        let totalCount = self.sections.count
        self.logger.info("Background history section loading completed, total sections: \(totalCount)")
    }

    /// Refreshes history content while keeping existing data visible.
    /// Skips update if data hasn't changed to avoid scroll jitter.
    /// Returns true if data changed, false otherwise.
    @discardableResult
    func refresh() async -> Bool {
        self.backgroundLoadTask?.cancel()

        do {
            let response = try await client.getHistory()

            // Skip update if data is identical (prevents scroll jitter)
            if !self.sectionsChanged(response.sections) {
                self.logger.debug("History unchanged, skipping update")
                return false
            }

            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreHistorySections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
            self.logger.info("History refreshed: \(response.sections.count) sections")
            self.startBackgroundLoading()
            return true
        } catch is CancellationError {
            self.logger.debug("History refresh cancelled")
            return false
        } catch {
            self.logger.warning("History refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Compares new sections against current by checking section count and first item IDs.
    private func sectionsChanged(_ newSections: [HomeSection]) -> Bool {
        guard self.sections.count == newSections.count else { return true }
        for (old, new) in zip(self.sections, newSections) {
            if old.items.count != new.items.count { return true }
            if old.items.first?.videoId != new.items.first?.videoId { return true }
        }
        return false
    }
}
