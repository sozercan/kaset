import Foundation
import Testing
@testable import Kaset

// MARK: - DiscordPresenceTests

@Suite(.serialized, .tags(.service))
@MainActor
struct DiscordPresenceTests {
    @Test("DiscordPresencePayload encodes and decodes JSON correctly")
    func payloadSerialization() throws {
        let timestamps = DiscordPresencePayload.Timestamps(start: 1_700_000_000_000, end: 1_700_000_200_000)
        let assets = DiscordPresencePayload.Assets(
            large_image: "https://example.com/art.jpg",
            large_text: "Album Name",
            small_image: "kaset_icon",
            small_text: "Kaset for macOS"
        )
        let buttons = [
            DiscordPresencePayload.Button(label: "Listen on YouTube Music", url: "https://music.youtube.com/watch?v=abc"),
        ]

        let payload = DiscordPresencePayload(
            type: 2,
            details: "Song Title",
            state: "Artist Name • Album Name",
            timestamps: timestamps,
            assets: assets,
            buttons: buttons
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        #expect(!data.isEmpty)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DiscordPresencePayload.self, from: data)

        #expect(decoded.type == 2)
        #expect(decoded.details == "Song Title")
        #expect(decoded.state == "Artist Name • Album Name")
        #expect(decoded.timestamps?.start == 1_700_000_000_000)
        #expect(decoded.assets?.large_image == "https://example.com/art.jpg")
        #expect(decoded.buttons?.first?.label == "Listen on YouTube Music")
    }

    @Test("DiscordPresenceState connection flags")
    func stateFlags() {
        let disconnected = DiscordPresenceState.disconnected
        #expect(!disconnected.isConnected)
        #expect(!disconnected.isConnecting)

        let connecting = DiscordPresenceState.connecting(attempt: 2)
        #expect(!connecting.isConnected)
        #expect(connecting.isConnecting)

        let connected = DiscordPresenceState.connected
        #expect(connected.isConnected)
        #expect(!connected.isConnecting)

        let error = DiscordPresenceState.error("Failed")
        #expect(!error.isConnected)
        #expect(!error.isConnecting)
    }

    private struct SettingsSnapshot {
        let presenceEnabled: Bool
        let showMusic: Bool
        let showVideo: Bool
        let showTitle: Bool
        let showArtist: Bool
        let showAlbum: Bool
        let showTimestamps: Bool
        let showArtwork: Bool
        let showListenButton: Bool

        @MainActor
        static func capture() -> SettingsSnapshot {
            let s = SettingsManager.shared
            return SettingsSnapshot(
                presenceEnabled: s.discordPresenceEnabled,
                showMusic: s.discordShowMusic,
                showVideo: s.discordShowVideo,
                showTitle: s.discordShowTitle,
                showArtist: s.discordShowArtist,
                showAlbum: s.discordShowAlbum,
                showTimestamps: s.discordShowTimestamps,
                showArtwork: s.discordShowArtwork,
                showListenButton: s.discordShowListenButton
            )
        }

        @MainActor
        func restore() {
            let s = SettingsManager.shared
            s.discordPresenceEnabled = self.presenceEnabled
            s.discordShowMusic = self.showMusic
            s.discordShowVideo = self.showVideo
            s.discordShowTitle = self.showTitle
            s.discordShowArtist = self.showArtist
            s.discordShowAlbum = self.showAlbum
            s.discordShowTimestamps = self.showTimestamps
            s.discordShowArtwork = self.showArtwork
            s.discordShowListenButton = self.showListenButton
        }
    }

    @Test("DiscordPresenceCoordinator builds music payload respecting privacy settings")
    @MainActor
    func coordinatorMusicPayload() async {
        let snapshot = SettingsSnapshot.capture()
        defer { snapshot.restore() }

        let player = PlayerService()
        let youtubePlayer = YouTubePlayerService(webKitManager: WebKitManager.shared)
        let settings = SettingsManager.shared
        let mockService = MockDiscordPresenceService()

        // Enable presence and privacy controls
        settings.discordPresenceEnabled = true
        settings.discordShowMusic = true
        settings.discordShowTitle = true
        settings.discordShowArtist = true
        settings.discordShowAlbum = true
        settings.discordShowTimestamps = true
        settings.discordShowArtwork = true
        settings.discordShowListenButton = true

        let coordinator = DiscordPresenceCoordinator(
            playerService: player,
            youtubePlayerService: youtubePlayer,
            settings: settings,
            service: mockService
        )

        let song = Song(
            id: "song-123",
            title: "Test Track",
            artists: [Artist(id: "art-1", name: "Test Artist")],
            album: Album(
                id: "alb-1",
                title: "Test Album",
                artists: [Artist(id: "art-1", name: "Test Artist")],
                thumbnailURL: nil,
                year: "2024",
                trackCount: 10
            ),
            duration: 180,
            thumbnailURL: URL(string: "https://example.com/thumb.jpg"),
            videoId: "song-123"
        )

        player.currentTrack = song
        player.state = .playing

        await coordinator.syncPresence()

        #expect(mockService.lastPayload?.details == "Test Track")
        #expect(mockService.lastPayload?.state == "Test Artist • Test Album")
        #expect(mockService.lastPayload?.type == 2)
        #expect(mockService.lastPayload?.buttons?.first?.label == "Listen on YouTube Music")
    }

    @Test("DiscordPresenceCoordinator clears presence when paused or disabled")
    @MainActor
    func coordinatorClearsPresence() async {
        let snapshot = SettingsSnapshot.capture()
        defer { snapshot.restore() }

        let player = PlayerService()
        let youtubePlayer = YouTubePlayerService(webKitManager: WebKitManager.shared)
        let settings = SettingsManager.shared
        let mockService = MockDiscordPresenceService()

        settings.discordPresenceEnabled = false

        let coordinator = DiscordPresenceCoordinator(
            playerService: player,
            youtubePlayerService: youtubePlayer,
            settings: settings,
            service: mockService
        )

        await coordinator.syncPresence()
        #expect(mockService.clearPresenceCalled == true)
    }

    @Test("DiscordPresenceCoordinator builds video payload for YouTube playback")
    @MainActor
    func coordinatorVideoPayload() async {
        let snapshot = SettingsSnapshot.capture()
        defer { snapshot.restore() }

        let player = PlayerService()
        let youtubePlayer = YouTubePlayerService(webKitManager: WebKitManager.shared)
        let settings = SettingsManager.shared
        let mockService = MockDiscordPresenceService()

        settings.discordPresenceEnabled = true
        settings.discordShowVideo = true
        settings.discordShowTitle = true
        settings.discordShowArtist = true
        settings.discordShowArtwork = true
        settings.discordShowListenButton = true

        let coordinator = DiscordPresenceCoordinator(
            playerService: player,
            youtubePlayerService: youtubePlayer,
            settings: settings,
            service: mockService
        )

        let video = YouTubeVideo(
            videoId: "vid-123",
            title: "WWDC Keynote",
            channelName: "Apple",
            channelId: "apple-ch",
            lengthText: "2:00:00",
            viewCountText: "1M views",
            publishedText: "1 day ago",
            thumbnailURL: URL(string: "https://example.com/apple.jpg")
        )

        youtubePlayer.play(video: video)
        youtubePlayer.updatePlaybackState(.init(isPlaying: true, progress: 10, duration: 7200, videoId: "vid-123"))

        await coordinator.syncPresence()

        #expect(mockService.lastPayload?.details == "WWDC Keynote")
        #expect(mockService.lastPayload?.state == "Apple")
        #expect(mockService.lastPayload?.type == 3) // Watching
        #expect(mockService.lastPayload?.buttons?.first?.label == "Watch on YouTube")
    }

    @Test("DiscordPresenceCoordinator privacy toggles hide artist and title")
    @MainActor
    func coordinatorPrivacyToggles() async {
        let snapshot = SettingsSnapshot.capture()
        defer { snapshot.restore() }

        let player = PlayerService()
        let youtubePlayer = YouTubePlayerService(webKitManager: WebKitManager.shared)
        let settings = SettingsManager.shared
        let mockService = MockDiscordPresenceService()

        settings.discordPresenceEnabled = true
        settings.discordShowMusic = true
        settings.discordShowTitle = false
        settings.discordShowArtist = false
        settings.discordShowAlbum = false
        settings.discordShowTimestamps = false
        settings.discordShowArtwork = false
        settings.discordShowListenButton = false

        let coordinator = DiscordPresenceCoordinator(
            playerService: player,
            youtubePlayerService: youtubePlayer,
            settings: settings,
            service: mockService
        )

        let song = Song(
            id: "song-secret",
            title: "Private Song",
            artists: [Artist(id: "art-1", name: "Secret Artist")],
            duration: 120,
            videoId: "song-secret"
        )

        player.currentTrack = song
        player.state = .playing

        await coordinator.syncPresence()

        #expect(mockService.lastPayload?.details == nil)
        #expect(mockService.lastPayload?.state == nil)
        #expect(mockService.lastPayload?.timestamps == nil)
        #expect(mockService.lastPayload?.assets == nil)
        #expect(mockService.lastPayload?.buttons == nil)
    }

    @Test("DiscordPresenceCoordinator respects album toggle when artist is hidden")
    @MainActor
    func coordinatorAlbumWithoutArtist() async {
        let snapshot = SettingsSnapshot.capture()
        defer { snapshot.restore() }

        let player = PlayerService()
        let youtubePlayer = YouTubePlayerService(webKitManager: WebKitManager.shared)
        let settings = SettingsManager.shared
        let mockService = MockDiscordPresenceService()

        settings.discordPresenceEnabled = true
        settings.discordShowMusic = true
        settings.discordShowTitle = true
        settings.discordShowArtist = false
        settings.discordShowAlbum = true
        settings.discordShowArtwork = true

        let coordinator = DiscordPresenceCoordinator(
            playerService: player,
            youtubePlayerService: youtubePlayer,
            settings: settings,
            service: mockService
        )

        let song = Song(
            id: "song-1",
            title: "Solo Song",
            artists: [Artist(id: "a1", name: "Hidden Artist")],
            album: Album(id: "alb-1", title: "Visible Album", artists: [], thumbnailURL: nil, year: "2024", trackCount: 1),
            duration: 200,
            videoId: "song-1"
        )

        player.currentTrack = song
        player.state = .playing

        await coordinator.syncPresence()

        #expect(mockService.lastPayload?.details == "Solo Song")
        #expect(mockService.lastPayload?.state == "Visible Album")
        #expect(mockService.lastPayload?.assets?.large_text == "Visible Album")
    }

    @Test("DiscordPresenceCoordinator calculates timestamps relative to playback progress")
    @MainActor
    func coordinatorTimestampsProgress() async {
        let snapshot = SettingsSnapshot.capture()
        defer { snapshot.restore() }

        let player = PlayerService()
        let youtubePlayer = YouTubePlayerService(webKitManager: WebKitManager.shared)
        let settings = SettingsManager.shared
        let mockService = MockDiscordPresenceService()

        settings.discordPresenceEnabled = true
        settings.discordShowMusic = true
        settings.discordShowTimestamps = true

        let coordinator = DiscordPresenceCoordinator(
            playerService: player,
            youtubePlayerService: youtubePlayer,
            settings: settings,
            service: mockService
        )

        let song = Song(
            id: "song-time",
            title: "Time Track",
            artists: [],
            duration: 100,
            videoId: "song-time"
        )

        player.currentTrack = song
        player.state = .playing
        player.progress = 30

        await coordinator.syncPresence()

        guard let timestamps = mockService.lastPayload?.timestamps,
              let start = timestamps.start,
              let end = timestamps.end
        else {
            Issue.record("Expected timestamps to be populated")
            return
        }

        let diff = Double(end - start) / 1000.0
        #expect(abs(diff - 100.0) < 1.0)
    }
}
