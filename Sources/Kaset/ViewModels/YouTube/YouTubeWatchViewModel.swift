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

    /// The user's rating of this video. YouTube doesn't expose the initial
    /// rating cheaply, so this starts at `.none` and tracks local actions.
    private(set) var rating: YouTubeRating = .none

    /// Whether this video has been added to Watch Later in this session.
    private(set) var isInWatchLater = false

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
            self.logger.error("Failed to load watch-next data: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    // MARK: - Actions

    /// Toggles a like on the video (optimistic with rollback).
    func toggleLike() async {
        let previous = self.rating
        self.rating = previous == .like ? YouTubeRating.none : .like
        do {
            try await self.client.rateVideo(videoId: self.video.videoId, rating: self.rating)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to rate video: \(error.localizedDescription)")
            self.rating = previous
        }
    }

    /// Adds or removes the video from Watch Later (optimistic with rollback).
    func toggleWatchLater() async {
        let wasInWatchLater = self.isInWatchLater
        self.isInWatchLater = !wasInWatchLater
        do {
            if wasInWatchLater {
                try await self.client.removeFromWatchLater(videoId: self.video.videoId)
            } else {
                try await self.client.addToWatchLater(videoId: self.video.videoId)
            }
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to edit Watch Later: \(error.localizedDescription)")
            self.isInWatchLater = wasInWatchLater
        }
    }

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
