import Foundation
import Testing
@testable import Kaset

/// Tests for standalone artist-page episode playback.
@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceEpisodeTests {
    var playerService: PlayerService
    var mockClient: MockYTMusicClient

    init() {
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queue")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queueIndex")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.playbackSession")
        SingletonPlayerWebView.shared.currentVideoId = nil

        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
        self.playerService.setYTMusicClient(self.mockClient)
    }

    @Test("Artist episode marker is set before metadata fetch and cleared by later song playback")
    func artistEpisodeMarkerDoesNotOutliveLaterSongPlayback() async {
        let episode = ArtistEpisode(
            videoId: "episode-video",
            title: "24/7 Live Radio",
            thumbnailURL: URL(string: "https://example.com/episode.jpg"),
            isLive: true
        )
        let normalSong = Song(
            id: "normal-song",
            title: "Normal Song",
            artists: [Artist(id: "normal-artist", name: "Normal Artist")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "normal-video"
        )

        self.mockClient.getSongDelay = .milliseconds(150)
        self.mockClient.songResponses[episode.videoId] = Song(
            id: episode.videoId,
            title: "Episode Metadata",
            artists: [Artist(id: "episode-artist", name: "Episode Artist")],
            album: nil,
            duration: nil,
            thumbnailURL: episode.thumbnailURL,
            videoId: episode.videoId
        )
        self.mockClient.songResponses[normalSong.videoId] = normalSong

        let playerService = self.playerService
        let episodeTask = Task {
            await playerService.playEpisode(episode)
        }

        for _ in 0 ..< 20 where !self.mockClient.getSongVideoIds.contains(episode.videoId) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(self.mockClient.getSongVideoIds.contains(episode.videoId))
        #expect(self.playerService.currentEpisode == episode)

        await self.playerService.play(song: normalSong)
        await episodeTask.value

        #expect(self.playerService.currentEpisode == nil)
        #expect(self.playerService.currentTrack?.videoId == normalSong.videoId)
        #expect(self.playerService.currentTrack?.title == normalSong.title)
    }

    @Test("Previous is ignored for standalone artist episode playback")
    func previousIsIgnoredForStandaloneArtistEpisodePlayback() async {
        let episode = ArtistEpisode(videoId: "live-video", title: "Live Stream", isLive: true)

        self.playerService.currentEpisode = episode
        self.playerService.currentTrack = Song(
            id: episode.videoId,
            title: episode.title,
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: episode.videoId
        )
        self.playerService.pendingPlayVideoId = episode.videoId
        self.playerService.progress = 10

        await self.playerService.previous()

        #expect(self.playerService.progress == 10)
        #expect(self.playerService.currentEpisode == episode)
    }
}
