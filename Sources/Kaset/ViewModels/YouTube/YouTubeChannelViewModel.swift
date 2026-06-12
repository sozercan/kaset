import Foundation
import Observation

/// View model for a YouTube channel page.
@MainActor
@Observable
final class YouTubeChannelViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Loaded channel detail.
    private(set) var detail: YouTubeChannelDetail?

    let channelId: String
    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(channelId: String, client: any YouTubeClientProtocol) {
        self.channelId = channelId
        self.client = client
    }

    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        do {
            self.detail = try await self.client.getChannel(channelId: self.channelId)
            self.loadingState = .loaded
        } catch {
            self.logger.error("Failed to load YouTube channel: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }
}
