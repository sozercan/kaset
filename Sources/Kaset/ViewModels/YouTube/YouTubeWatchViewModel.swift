import Foundation
import Observation

/// View model for the YouTube watch page (metadata + related videos).
@MainActor
@Observable
final class YouTubeWatchViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Watch-page companion data.
    private(set) var data: WatchNextData = .empty

    let video: YouTubeVideo
    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self.client = client
    }

    // MARK: - Action State (optimistic)

    // Like/dislike and Watch Later live on YouTubePlayerService so the
    // player bar (inline and pop-out) owns them.

    /// Whether the user is subscribed to the channel (seeded from watch-next).
    private(set) var isSubscribed = false

    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        do {
            self.data = try await self.client.getWatchNext(videoId: self.video.videoId)
            self.isSubscribed = self.data.isSubscribed ?? false
            self.loadingState = .loaded
        } catch {
            // A cancelled load (view went away mid-flight) is not an
            // error; the next .task run reloads.
            if error is CancellationError { return }
            self.logger.error("Failed to load watch-next data: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    // MARK: - Actions

    /// Subscribes/unsubscribes the channel (optimistic with rollback).
    func toggleSubscribed() async {
        guard let channel = self.data.channel else { return }
        let wasSubscribed = self.isSubscribed
        self.isSubscribed = !wasSubscribed
        do {
            try await self.client.setSubscribed(self.isSubscribed, channelId: channel.channelId)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to change subscription: \(error.localizedDescription)")
            self.isSubscribed = wasSubscribed
        }
    }
}
