import Foundation

// MARK: - QueueEntry

struct QueueEntry: Identifiable, Hashable {
    /// Where a queue entry came from. `suggested` marks Smart Shuffle recommendations.
    enum Source: String, Hashable, Codable {
        case queued
        case suggested
    }

    let id: UUID
    let song: Song
    /// Defaulted so existing `QueueEntry(id:song:)` call sites compile unchanged.
    var source: Source = .queued
}

// MARK: - QueueState

struct QueueState {
    enum PlaybackOwner: Equatable {
        case none
        case queueEntry(id: UUID, progress: TimeInterval, duration: TimeInterval)
        case detached(song: Song, episode: ArtistEpisode?, progress: TimeInterval, duration: TimeInterval)
    }

    let entries: [QueueEntry]
    let currentIndex: Int
    let shouldResumePlayback: Bool
    let wasPlaybackEnded: Bool
    let shuffleMode: PlayerService.ShuffleMode
    let mixContinuation: String?
    let mixContinuationRequiresAuth: Bool
    let queueOrderBeforeShuffle: [QueueEntry]?
    let playbackOwner: PlaybackOwner

    init(
        entries: [QueueEntry],
        currentIndex: Int,
        shouldResumePlayback: Bool = false,
        wasPlaybackEnded: Bool = false,
        shuffleMode: PlayerService.ShuffleMode = .off,
        mixContinuation: String? = nil,
        mixContinuationRequiresAuth: Bool = false,
        queueOrderBeforeShuffle: [QueueEntry]? = nil,
        playbackOwner: PlaybackOwner = .none
    ) {
        self.entries = entries
        self.currentIndex = currentIndex
        self.shouldResumePlayback = shouldResumePlayback
        self.wasPlaybackEnded = wasPlaybackEnded
        self.shuffleMode = shuffleMode
        self.mixContinuation = mixContinuation
        self.mixContinuationRequiresAuth = mixContinuationRequiresAuth
        self.queueOrderBeforeShuffle = queueOrderBeforeShuffle
        self.playbackOwner = playbackOwner
    }
}
