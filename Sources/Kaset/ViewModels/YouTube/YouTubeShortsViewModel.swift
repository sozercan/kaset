import Foundation
import Observation

/// View model for the dedicated Shorts surface.
///
/// Shorts ride along in the home feed response (Kaset strips them from the
/// regular grid); this surfaces them on their own page.
@MainActor
@Observable
final class YouTubeShortsViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Shorts to display.
    private(set) var shorts: [YouTubeVideo] = []

    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        do {
            let shorts = try await self.client.getShorts()
            guard generation == self.loadGeneration else { return }
            self.shorts = shorts
            self.loadingState = .loaded
        } catch {
            guard generation == self.loadGeneration else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load Shorts: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    func refresh() async {
        self.loadingState = .idle
        self.shorts = []
        await self.load()
    }
}
