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
    var showMiniPlayer = false
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

    func play(videoId: String) async {
        self.playedVideoIds.append(videoId)
        self.state = .playing
    }

    func play(song: Song) async {
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
        self.pauseCallCount += 1
        self.state = .paused
    }

    func resume() async {
        self.resumeCallCount += 1
        self.state = .playing
    }

    func next() async {
        self.nextCallCount += 1
    }

    func previous() async {
        self.previousCallCount += 1
    }

    func seek(to time: TimeInterval) async {
        self.progress = time
    }

    func setVolume(_ value: Double) async {
        self.volume = value
    }

    func toggleMute() async {
        self.volume = self.isMuted ? 1 : 0
    }

    func toggleShuffle() {
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

    func stop() async {
        self.state = .idle
        self.currentTrack = nil
    }

    func playQueue(_ songs: [Song], startingAt index: Int) async {
        self.playQueueCallCount += 1
        self.queue = songs
        let safeIndex = min(max(index, 0), max(0, songs.count - 1))
        self.currentIndex = safeIndex
        self.currentTrack = songs[safe: safeIndex]
        self.state = .playing
    }

    func playWithRadio(song: Song) async {
        self.currentTrack = song
        self.state = .playing
    }

    func playWithMix(playlistId _: String, startVideoId _: String?) async {}

    func clearQueue() {
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
