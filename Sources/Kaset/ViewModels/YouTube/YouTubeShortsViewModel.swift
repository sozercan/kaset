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

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        do {
            self.shorts = try await self.client.getShorts()
            self.loadingState = .loaded
        } catch {
            // A cancelled load (view went away mid-flight) is not an
            // error; the next .task run reloads.
            if error is CancellationError { return }
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
