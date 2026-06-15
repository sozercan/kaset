import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct PlaylistPlaybackActionsTests {
    var mockClient: MockYTMusicClient

    init() {
        self.mockClient = MockYTMusicClient()
    }

    @Test("Radio playlist tracks use browse playability when queue endpoint disagrees")
    func radioPlaylistTracksUseBrowsePlayability() {
        let browseTrack = Song(
            id: "track-1",
            title: "Track 1",
            artists: [],
            thumbnailURL: URL(string: "https://example.com/browse.jpg"),
            videoId: "video-1",
            isPlayable: false,
            isExplicit: true
        )
        let queueTrack = Song(
            id: "track-1",
            title: "Track 1",
            artists: [],
            thumbnailURL: URL(string: "https://example.com/queue.jpg"),
            videoId: "video-1",
            isPlayable: true,
            isExplicit: true
        )

        let tracks = PlaylistPlaybackActions.tracksForPlaylistPlayback(
            browseTracks: [browseTrack],
            queueTracks: [queueTrack]
        )

        #expect(tracks.count == 1)
        #expect(tracks.first?.isPlayable == false)
        #expect(tracks.first?.thumbnailURL == queueTrack.thumbnailURL)
        #expect(tracks.first?.isExplicit == true)
    }

    @Test("Playable playlist artwork filters unavailable songs and fills missing thumbnails")
    func playablePlaylistArtworkFiltersAndFillsThumbnails() {
        let playlist = TestFixtures.makePlaylist(id: "VL-playlist", title: "Playlist")
        let unavailable = Song(
            id: "unavailable",
            title: "Unavailable",
            artists: [],
            videoId: "unavailable",
            isPlayable: false
        )
        let playable = Song(
            id: "playable",
            title: "Playable",
            artists: [],
            thumbnailURL: nil,
            videoId: "playable",
            isPlayable: true,
            isExplicit: true
        )

        let songs = PlaylistPlaybackActions.playableSongsWithPlaylistArtwork(
            [unavailable, playable],
            playlist: playlist
        )

        #expect(songs.map(\.videoId) == ["playable"])
        #expect(songs.first?.thumbnailURL == playlist.thumbnailURL)
        #expect(songs.first?.isExplicit == true)
    }

    @Test("Playlist playback starts before continuation loading completes")
    func playlistPlaybackStartsBeforeContinuationLoadingCompletes() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        let initial = Song(
            id: "initial",
            title: "Initial",
            artists: [],
            videoId: "initial"
        )
        let continuation = Song(
            id: "continuation",
            title: "Continuation",
            artists: [],
            videoId: "continuation"
        )
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [initial],
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlist.id] = [[continuation]]
        self.mockClient.playlistContinuationDelay = .milliseconds(250)
        let playerService = PlayerService()

        PlaylistPlaybackActions.playPlaylist(
            playlist,
            client: self.mockClient,
            playerService: playerService
        )
        await self.awaitQueueCount(1, in: playerService)

        #expect(playerService.currentTrack?.videoId == "initial")
        #expect(playerService.queue.map(\.videoId) == ["initial"])

        await self.awaitQueueCount(2, in: playerService)
        #expect(playerService.queue.map(\.videoId) == ["initial", "continuation"])
    }

    private func awaitQueueCount(_ expectedCount: Int, in playerService: PlayerService) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while playerService.queue.count != expectedCount {
            guard clock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
