import Foundation
@testable import Kaset

@MainActor
final class MockPlayerService: PlayerServiceProtocol {
    var state: PlayerService.PlaybackState = .idle
    var currentTrack: Song?
    var progress: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Double = 1
    var shuffleEnabled = false
    var repeatMode: PlayerService.RepeatMode = .off
    var queue: [Song] = []
    var currentIndex = 0
    var activePlaybackQueueIndex: Int? {
        guard let currentTrack,
              queue[safe: currentIndex]?.videoId == currentTrack.videoId
        else { return nil }
        return self.currentIndex
    }

    var showMiniPlayer = false
    var isMiniPlayerVisible = false
    var miniPlayerMode: PlayerService.MiniPlayerMode = .auxiliary
    var miniPlayerPanel: PlayerService.MiniPlayerPanel = .compact
    var shouldRestoreMainWindowWhenMiniPlayerCloses = false
    var miniPlayerMainWindowRestoreRequest = false
    var currentTrackLikeStatus: LikeStatus = .indifferent
    var currentTrackInLibrary = false

    var isPlaying: Bool {
        self.state.isPlaying
    }

    var isMuted: Bool {
        self.volume == 0
    }

    private(set) var playedVideoIds: [String] = []
    private(set) var playedSongs: [Song] = []
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var nextCallCount = 0
    private(set) var previousCallCount = 0
    private(set) var clearQueueCallCount = 0
    private(set) var shuffleQueueCallCount = 0
    private(set) var appendToQueueCallCount = 0
    private(set) var playQueueCallCount = 0
    private(set) var likeCallCount = 0
    private(set) var dislikeCallCount = 0
    private var musicPlaybackIntentGeneration: UInt64 = 0
    private var musicPlaybackReservationGeneration: UInt64 = 0
    private var queueMutationGeneration = 0

    func play(videoId: String) async {
        self.advancePlaybackOwnership()
        self.playedVideoIds.append(videoId)
        self.state = .playing
    }

    func play(song: Song) async {
        self.advancePlaybackOwnership()
        self.playedSongs.append(song)
        self.currentTrack = song
        self.state = .playing
    }

    func playPause() async {
        if self.isPlaying {
            await self.pause()
        } else {
            await self.resume()
        }
    }

    func pause() async {
        self.advancePlaybackOwnership()
        self.pauseCallCount += 1
        self.state = .paused
    }

    func resume() async {
        self.advancePlaybackOwnership()
        self.resumeCallCount += 1
        self.state = .playing
    }

    func next() async {
        self.advancePlaybackOwnership()
        self.nextCallCount += 1
    }

    func previous() async {
        self.advancePlaybackOwnership()
        self.previousCallCount += 1
    }

    func seek(to time: TimeInterval) async {
        self.advancePlaybackOwnership()
        self.progress = time
    }

    func setVolume(_ value: Double) async {
        self.volume = value
    }

    func toggleMute() async {
        self.volume = self.isMuted ? 1 : 0
    }

    func toggleShuffle() {
        self.advancePlaybackOwnership()
        self.shuffleEnabled.toggle()
    }

    func cycleRepeatMode() {
        self.repeatMode = switch self.repeatMode {
        case .off:
            .all
        case .all:
            .one
        case .one:
            .off
        }
    }

    func openMiniPlayer(mode: PlayerService.MiniPlayerMode) {
        self.miniPlayerMode = mode
        self.isMiniPlayerVisible = true
        self.shouldRestoreMainWindowWhenMiniPlayerCloses = mode == .switchFromMainWindow
        self.miniPlayerMainWindowRestoreRequest = false
    }

    @discardableResult
    func toggleMiniPlayer(mode: PlayerService.MiniPlayerMode) -> Bool {
        if self.isMiniPlayerVisible, self.miniPlayerMode == mode {
            return self.closeMiniPlayer()
        }
        self.openMiniPlayer(mode: mode)
        return false
    }

    @discardableResult
    func closeMiniPlayer() -> Bool {
        let shouldRestore = self.shouldRestoreMainWindowWhenMiniPlayerCloses
        self.isMiniPlayerVisible = false
        self.miniPlayerMode = .auxiliary
        self.shouldRestoreMainWindowWhenMiniPlayerCloses = false
        self.miniPlayerMainWindowRestoreRequest = shouldRestore
        return shouldRestore
    }

    func consumeMiniPlayerMainWindowRestoreRequest() -> Bool {
        let shouldRestore = self.miniPlayerMainWindowRestoreRequest
        self.miniPlayerMainWindowRestoreRequest = false
        return shouldRestore
    }

    func toggleMiniPlayerPanel() {
        self.miniPlayerPanel = switch self.miniPlayerPanel {
        case .compact:
            .expanded
        case .expanded:
            .compact
        case .lyrics:
            .expanded
        }
    }

    func stop() async {
        self.musicPlaybackIntentGeneration &+= 1
        self.musicPlaybackReservationGeneration &+= 1
        self.queueMutationGeneration += 1
        self.state = .idle
        self.currentTrack = nil
    }

    func playQueue(_ songs: [Song], startingAt index: Int) async {
        guard !songs.isEmpty else { return }
        self.musicPlaybackIntentGeneration &+= 1
        self.musicPlaybackReservationGeneration &+= 1
        self.queueMutationGeneration += 1
        self.playQueueCallCount += 1
        self.queue = songs
        let safeIndex = min(max(index, 0), max(0, songs.count - 1))
        self.currentIndex = safeIndex
        self.currentTrack = songs[safe: safeIndex]
        self.state = .playing
    }

    private func advancePlaybackOwnership() {
        self.musicPlaybackIntentGeneration &+= 1
        self.musicPlaybackReservationGeneration &+= 1
    }

    func reserveMusicPlaybackIntent() -> MusicPlaybackReservation {
        self.musicPlaybackReservationGeneration &+= 1
        return MusicPlaybackReservation(
            playbackGeneration: self.musicPlaybackIntentGeneration,
            reservationGeneration: self.musicPlaybackReservationGeneration,
            queueMutationGeneration: self.queueMutationGeneration,
            queueEntryID: nil,
            videoID: self.currentTrack?.videoId
        )
    }

    func acceptsMusicPlaybackReservation(_ reservation: MusicPlaybackReservation) -> Bool {
        reservation.playbackGeneration == self.musicPlaybackIntentGeneration
            && reservation.reservationGeneration == self.musicPlaybackReservationGeneration
            && reservation.videoID == self.currentTrack?.videoId
    }

    func claimMusicPlaybackIntent(_ reservation: MusicPlaybackReservation) -> MusicPlaybackIntent? {
        guard reservation.playbackGeneration == self.musicPlaybackIntentGeneration,
              reservation.reservationGeneration == self.musicPlaybackReservationGeneration
        else { return nil }
        self.musicPlaybackIntentGeneration &+= 1
        self.musicPlaybackReservationGeneration &+= 1
        return MusicPlaybackIntent(generation: self.musicPlaybackIntentGeneration)
    }

    func acceptsMusicPlaybackIntent(_ intent: MusicPlaybackIntent) -> Bool {
        intent.generation == self.musicPlaybackIntentGeneration
    }

    func reserveQueueMutation() -> Int {
        self.queueMutationGeneration
    }

    func acceptsQueueMutation(_ generation: Int) -> Bool {
        generation == self.queueMutationGeneration
    }

    func playQueue(
        _ songs: [Song],
        startingAt index: Int,
        deferringSmartShuffleFill: Bool,
        intent: MusicPlaybackIntent
    ) async -> Int? {
        guard self.acceptsMusicPlaybackIntent(intent), !songs.isEmpty else { return nil }
        self.queueMutationGeneration += 1
        self.playQueueCallCount += 1
        self.queue = songs
        self.currentIndex = min(max(index, 0), max(0, songs.count - 1))
        self.currentTrack = songs[safe: self.currentIndex]
        self.state = songs.isEmpty ? .idle : .playing
        return deferringSmartShuffleFill ? self.queueMutationGeneration : nil
    }

    func playWithRadio(song: Song) async {
        self.advancePlaybackOwnership()
        self.queueMutationGeneration += 1
        self.currentTrack = song
        self.state = .playing
    }

    func playWithMix(
        playlistId _: String,
        startVideoId _: String?,
        intent suppliedIntent: MusicPlaybackIntent?
    ) async {
        if let suppliedIntent {
            guard self.acceptsMusicPlaybackIntent(suppliedIntent) else { return }
        } else {
            self.advancePlaybackOwnership()
        }
    }

    func clearQueue() {
        self.advancePlaybackOwnership()
        self.queueMutationGeneration += 1
        self.clearQueueCallCount += 1
        if let currentTrack = self.currentTrack {
            self.queue = [currentTrack]
            self.currentIndex = 0
        } else {
            self.queue = []
            self.currentIndex = 0
        }
    }

    func shuffleQueue() {
        self.advancePlaybackOwnership()
        self.shuffleQueueCallCount += 1
        self.queue = Array(self.queue.reversed())
    }

    func appendToQueue(_ songs: [Song]) {
        self.appendToQueueCallCount += 1
        self.queue.append(contentsOf: songs)
    }

    func likeCurrentTrack() {
        self.likeCallCount += 1
        self.currentTrackLikeStatus = .like
    }

    func dislikeCurrentTrack() {
        self.dislikeCallCount += 1
        self.currentTrackLikeStatus = .dislike
    }

    func toggleLibraryStatus() {
        self.currentTrackInLibrary.toggle()
    }

    func confirmPlaybackStarted() {}

    func miniPlayerDismissed() {}

    func updatePlaybackState(isPlaying: Bool, progress: Double, duration: Double) {
        self.state = isPlaying ? .playing : .paused
        self.progress = progress
        self.duration = duration
    }

    func updateTrackMetadata(title: String, artist: String, thumbnailUrl _: String, videoId: String?) {
        guard let videoId else { return }
        self.currentTrack = Song(
            id: videoId,
            title: title,
            artists: [Artist(id: artist, name: artist)],
            videoId: videoId
        )
    }

    func updateLikeStatus(_ status: LikeStatus) {
        self.currentTrackLikeStatus = status
    }
}
