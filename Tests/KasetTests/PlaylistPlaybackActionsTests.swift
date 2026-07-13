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

    @Test("Remaining playlist tracks tolerate removal from the initially queued prefix")
    func remainingTracksTolerateInitialRemoval() {
        let initial = [
            TestFixtures.makeSong(id: "a"),
            TestFixtures.makeSong(id: "b"),
        ]
        let full = [
            TestFixtures.makeSong(id: "b"),
            TestFixtures.makeSong(id: "c"),
            TestFixtures.makeSong(id: "d"),
        ]

        let remaining = PlaylistPlaybackActions.remainingTracks(after: initial, in: full)

        #expect(remaining.map(\.videoId) == ["c", "d"])
    }

    @Test("Remaining playlist tracks preserve authored duplicates")
    func remainingTracksPreserveDuplicates() {
        let initial = [TestFixtures.makeSong(id: "duplicate")]
        let full = [
            TestFixtures.makeSong(id: "duplicate"),
            TestFixtures.makeSong(id: "duplicate"),
            TestFixtures.makeSong(id: "tail"),
        ]

        let remaining = PlaylistPlaybackActions.remainingTracks(after: initial, in: full)

        #expect(remaining.map(\.videoId) == ["duplicate", "tail"])
    }

    @Test("Remaining playlist tracks distinguish duplicate occurrences")
    func remainingTracksUsePlaylistOccurrenceIdentity() {
        let initial = [
            Song(
                id: "duplicate",
                title: "Duplicate",
                artists: [],
                videoId: "duplicate",
                playlistSetVideoId: "set-1"
            ),
        ]
        let full = [
            Song(
                id: "duplicate",
                title: "Duplicate",
                artists: [],
                videoId: "duplicate",
                playlistSetVideoId: "set-2"
            ),
            TestFixtures.makeSong(id: "tail"),
        ]

        let remaining = PlaylistPlaybackActions.remainingTracks(after: initial, in: full)

        #expect(remaining.map(\.playlistSetVideoId) == ["set-2", nil])
        #expect(remaining.map(\.videoId) == ["duplicate", "tail"])
    }

    @Test("Playlist playback continuation auth uses loaded ownership")
    func playlistPlaybackContinuationAuthUsesLoadedOwnership() async {
        let routePlaylist = TestFixtures.makePlaylist(
            id: "VL-owned-playlist",
            title: "Owned Playlist",
            canDelete: false
        )
        let loadedPlaylist = TestFixtures.makePlaylist(
            id: routePlaylist.id,
            title: routePlaylist.title,
            canDelete: true
        )
        let initial = Song(id: "initial", title: "Initial", artists: [], videoId: "initial")
        let continuation = Song(id: "continuation", title: "Continuation", artists: [], videoId: "continuation")
        self.mockClient.playlistDetails[routePlaylist.id] = PlaylistDetail(
            playlist: loadedPlaylist,
            tracks: [initial],
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[routePlaylist.id] = [[continuation]]
        let playerService = PlayerService()

        PlaylistPlaybackActions.playPlaylist(
            routePlaylist,
            client: self.mockClient,
            playerService: playerService
        )
        await self.awaitQueueCount(2, in: playerService)

        #expect(self.mockClient.getPlaylistContinuationRequiresAuthFlags == [true])
    }

    @Test("Pending playlist playback is discarded after guest privacy boundary")
    func pendingPlaylistPlaybackDiscardedAfterGuestPrivacyBoundary() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-delayed-playlist", title: "Delayed Playlist")
        self.mockClient.getPlaylistDelay = .milliseconds(150)
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [Song(id: "initial", title: "Initial", artists: [], videoId: "initial")],
            duration: nil
        )
        let playerService = PlayerService()

        PlaylistPlaybackActions.playPlaylist(
            playlist,
            client: self.mockClient,
            playerService: playerService
        )
        try? await Task.sleep(for: .milliseconds(30))
        playerService.clearPlaybackForGuestStartup()
        try? await Task.sleep(for: .milliseconds(250))

        #expect(playerService.queue.isEmpty)
        #expect(playerService.currentTrack == nil)
    }

    @Test("Playlist continuations preserve authored duplicate songs")
    func playlistContinuationsPreserveAuthoredDuplicates() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-duplicates", title: "Duplicates")
        let first = Song(id: "repeat-1", title: "Repeat", artists: [], videoId: "repeat")
        let duplicate = Song(id: "repeat-2", title: "Repeat Again", artists: [], videoId: "repeat")
        self.mockClient.playlistDetails[playlist.id] = PlaylistDetail(
            playlist: playlist,
            tracks: [first],
            duration: nil
        )
        self.mockClient.playlistContinuationTracks[playlist.id] = [[duplicate]]
        let playerService = PlayerService()

        PlaylistPlaybackActions.playPlaylist(
            playlist,
            client: self.mockClient,
            playerService: playerService
        )
        await self.awaitQueueCount(2, in: playerService)

        #expect(playerService.queue.map(\.videoId) == ["repeat", "repeat"])
        #expect(playerService.queue.map(\.title) == ["Repeat", "Repeat Again"])
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
