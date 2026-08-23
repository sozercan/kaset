import Foundation
import Observation

// MARK: - DiscordPresenceCoordinator

/// Coordinates active playback states between PlayerService (Music) and YouTubePlayerService (Video)
/// with the local Discord IPC presence transport and user privacy preferences.
@MainActor
@Observable
final class DiscordPresenceCoordinator {
    // MARK: - Dependencies

    let playerService: PlayerService
    let youtubePlayerService: YouTubePlayerService
    private let settings: SettingsManager
    private let logger = DiagnosticsLogger.discord

    let service: any DiscordPresenceServiceProtocol

    private var updateTask: Task<Void, Never>?

    init(
        playerService: PlayerService,
        youtubePlayerService: YouTubePlayerService,
        settings: SettingsManager = .shared,
        service: any DiscordPresenceServiceProtocol = DiscordLocalIPCService()
    ) {
        self.playerService = playerService
        self.youtubePlayerService = youtubePlayerService
        self.settings = settings
        self.service = service
    }

    /// Current connection state of the presence service.
    var state: DiscordPresenceState {
        self.service.state
    }

    // MARK: - Lifecycle

    func start() {
        self.startMonitoring()
        if self.settings.discordPresenceEnabled {
            Task {
                await self.service.connect()
                await self.syncPresence()
            }
        }
    }

    private func startMonitoring() {
        self.observePlayback()
        self.observeSettings()
    }

    private func observePlayback() {
        withObservationTracking {
            _ = self.playerService.currentTrack?.videoId
            _ = self.playerService.currentTrack?.title
            _ = self.playerService.isPlaying
            _ = self.playerService.duration

            _ = self.youtubePlayerService.currentVideo?.videoId
            _ = self.youtubePlayerService.currentVideo?.title
            _ = self.youtubePlayerService.isPlaying
            _ = self.youtubePlayerService.duration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observePlayback()
                await self.syncPresence()
            }
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = self.settings.discordPresenceEnabled
            _ = self.settings.discordShowMusic
            _ = self.settings.discordShowVideo
            _ = self.settings.discordShowTitle
            _ = self.settings.discordShowArtist
            _ = self.settings.discordShowAlbum
            _ = self.settings.discordShowTimestamps
            _ = self.settings.discordShowArtwork
            _ = self.settings.discordShowListenButton
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSettings()
                await self.syncPresence()
            }
        }
    }

    func connect() async {
        await self.service.connect()
        await self.syncPresence()
    }

    func disconnect() async {
        await self.service.disconnect()
    }

    // MARK: - Playback Synchronization

    /// Evaluates current playback and settings to construct and dispatch the Rich Presence payload.
    func syncPresence() async {
        guard self.settings.discordPresenceEnabled else {
            await self.service.clearPresence()
            return
        }

        // Determine if video is actively playing
        if self.youtubePlayerService.isPlaying,
           let currentVideo = self.youtubePlayerService.currentVideo,
           self.settings.discordShowVideo
        {
            let payload = self.buildVideoPayload(for: currentVideo)
            try? await self.service.updatePresence(payload)
            return
        }

        // Determine if music is actively playing
        if self.playerService.isPlaying,
           let currentTrack = self.playerService.currentTrack,
           self.settings.discordShowMusic
        {
            let payload = self.buildMusicPayload(for: currentTrack)
            try? await self.service.updatePresence(payload)
            return
        }

        // Otherwise clear presence when paused or inactive
        await self.service.clearPresence()
    }

    // MARK: - Payload Builders

    private func buildMusicPayload(for track: Song) -> DiscordPresencePayload {
        let title = self.settings.discordShowTitle ? track.title : nil
        let artist = self.settings.discordShowArtist ? track.artistsDisplay : nil
        let album = self.settings.discordShowAlbum ? track.album?.title : nil

        var stateText: String?
        if let artist, let album, !album.isEmpty {
            stateText = "\(artist) • \(album)"
        } else if let artist {
            stateText = artist
        } else if let album, !album.isEmpty {
            stateText = album
        }

        var timestamps: DiscordPresencePayload.Timestamps?
        if self.settings.discordShowTimestamps {
            let now = Date().timeIntervalSince1970
            let currentPos = self.playerService.progress
            let start = Int((now - currentPos) * 1000)
            var end: Int?
            if let duration = track.duration, duration > 0 {
                let remaining = max(0, duration - currentPos)
                end = Int((now + remaining) * 1000)
            }
            timestamps = DiscordPresencePayload.Timestamps(start: start, end: end)
        }

        var assets: DiscordPresencePayload.Assets?
        if self.settings.discordShowArtwork {
            let thumbnailURL = track.thumbnailURL?.absoluteString
            let tooltip = album ?? title
            assets = DiscordPresencePayload.Assets(
                large_image: thumbnailURL ?? "kaset_logo",
                large_text: tooltip,
                small_image: "kaset_icon",
                small_text: "Kaset for macOS"
            )
        }

        var buttons: [DiscordPresencePayload.Button]?
        if self.settings.discordShowListenButton {
            let videoId = track.videoId
            let listenURL = "https://music.youtube.com/watch?v=\(videoId)"
            buttons = [
                DiscordPresencePayload.Button(label: "Listen on YouTube Music", url: listenURL),
            ]
        }

        return DiscordPresencePayload(
            type: 2, // Listening
            details: title,
            state: stateText,
            timestamps: timestamps,
            assets: assets,
            buttons: buttons
        )
    }

    private func buildVideoPayload(for video: YouTubeVideo) -> DiscordPresencePayload {
        let title = self.settings.discordShowTitle ? video.title : nil
        let channel = self.settings.discordShowArtist ? video.channelName : nil

        var timestamps: DiscordPresencePayload.Timestamps?
        if self.settings.discordShowTimestamps {
            let now = Date().timeIntervalSince1970
            let currentPos = self.youtubePlayerService.progress
            let start = Int((now - currentPos) * 1000)
            var end: Int?
            let duration = self.youtubePlayerService.duration
            if duration > 0 {
                let remaining = max(0, duration - currentPos)
                end = Int((now + remaining) * 1000)
            }
            timestamps = DiscordPresencePayload.Timestamps(start: start, end: end)
        }

        var assets: DiscordPresencePayload.Assets?
        if self.settings.discordShowArtwork {
            let thumbnailURL = video.thumbnailURL?.absoluteString
            assets = DiscordPresencePayload.Assets(
                large_image: thumbnailURL ?? "kaset_logo",
                large_text: title,
                small_image: "kaset_icon",
                small_text: "Kaset for macOS"
            )
        }

        var buttons: [DiscordPresencePayload.Button]?
        if self.settings.discordShowListenButton {
            let watchURL = "https://www.youtube.com/watch?v=\(video.videoId)"
            buttons = [
                DiscordPresencePayload.Button(label: "Watch on YouTube", url: watchURL),
            ]
        }

        return DiscordPresencePayload(
            type: 3, // Watching
            details: title,
            state: channel,
            timestamps: timestamps,
            assets: assets,
            buttons: buttons
        )
    }
}
