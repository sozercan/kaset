import Foundation
import Observation
import os

/// View model for the Home view.
@MainActor
@Observable
final class HomeViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Home sections to display.
    private(set) var sections: [HomeSection] = []

    /// Whether more sections are available to load.
    private(set) var hasMoreSections: Bool = true

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    /// Task for background loading of additional sections.
    private var backgroundLoadTask: Task<Void, Never>?

    /// Number of background continuations loaded.
    private var continuationsLoaded = 0

    /// Maximum continuations to load in background.
    private static let maxContinuations = 4

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    /// Loads home content with fast initial load.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        self.logger.info("Loading home content")

        do {
            let response = try await client.getHome()
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreHomeSections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
            let sectionCount = self.sections.count
            self.logger.info("Home content loaded: \(sectionCount) sections")
            let sectionSummary = self.sections
                .map { "\($0.title) (\($0.items.count))" }
                .joined(separator: ", ")
            self.logger.debug("Home sections: [\(sectionSummary)]")

            // Start background loading of additional sections
            self.startBackgroundLoading()
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Home load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load home: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Loads more sections in the background progressively.
    private func startBackgroundLoading() {
        self.backgroundLoadTask?.cancel()
        self.backgroundLoadTask = Task { [weak self] in
            guard let self else { return }

            // Brief delay to let the UI settle
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
                if let additionalSections = try await client.getHomeContinuation() {
                    self.sections.append(contentsOf: additionalSections)
                    self.continuationsLoaded += 1
                    self.hasMoreSections = self.client.hasMoreHomeSections
                    let continuationNum = self.continuationsLoaded
                    self.logger.info("Background loaded \(additionalSections.count) more sections (continuation \(continuationNum))")
                } else {
                    self.hasMoreSections = false
                    break
                }
            } catch is CancellationError {
                self.logger.debug("Background loading cancelled")
                break
            } catch {
                self.logger.warning("Background section load failed: \(error.localizedDescription)")
                break
            }
        }

        let totalCount = self.sections.count
        self.logger.info("Background section loading completed, total sections: \(totalCount)")
    }

    /// Refreshes home content.
    func refresh() async {
        self.backgroundLoadTask?.cancel()
        self.sections = []
        self.hasMoreSections = true
        self.continuationsLoaded = 0
        await self.load()
    }
}
