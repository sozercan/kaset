import Foundation
import Observation

@MainActor
@Observable
final class YouTubeChannelViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var detail: YouTubeChannelDetail?

    let channelId: String
    private var loadGeneration = 0

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(channelId: String, client: any YouTubeClientProtocol) {
        self.channelId = channelId
        self.client = client
    }

    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        do {
            let detail = try await self.client.getChannel(channelId: self.channelId)
            guard generation == self.loadGeneration else { return }
            self.detail = detail
            self.loadingState = .loaded
        } catch {
            guard generation == self.loadGeneration else { return }
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube channel: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }
}
