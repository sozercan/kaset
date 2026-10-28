import AppIntents
import Foundation

// Intents that start new playback bring Kaset forward, like `kaset://play` deep links: the
// playback WebView lives in the main window, and a cold launch has to finish restoring
// sign-in state first (`AppIntentsBridge.waitUntilReady`).

// MARK: - PlayMusicIntent

struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Searches YouTube Music and plays the best matching song, followed by its radio.")
    static let openAppWhenRun = true

    @Parameter(title: "Search", requestValueDialog: "What do you want to play?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SongEntity> & ProvidesDialog {
        let song = try await AppIntentsBridge.shared.playSearchResult(for: self.query)
        let entity = SongEntity(song: song)
        let dialog: IntentDialog = entity.artist.isEmpty
            ? "Playing \(entity.title)."
            : "Playing \(entity.title) by \(entity.artist)."
        return .result(value: entity, dialog: dialog)
    }
}

// MARK: - PlaySongIntent

struct PlaySongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let description = IntentDescription("Plays a song in Kaset, followed by its radio.")
    static let openAppWhenRun = true

    @Parameter(title: "Song")
    var song: SongEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$song)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AppIntentsBridge.shared.play(song: self.song.song)
        return .result()
    }
}

// MARK: - PlayPlaylistIntent

/// Also the `OpenIntent` for playlists, so choosing one in Spotlight plays it.
struct PlayPlaylistIntent: AudioPlaybackIntent, OpenIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays a playlist in Kaset.")
    static let openAppWhenRun = true

    @Parameter(title: "Playlist")
    var target: PlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$target)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AppIntentsBridge.shared.play(playlist: self.target.playlist)
        return .result()
    }
}

// MARK: - PlayAlbumIntent

/// Also the `OpenIntent` for albums, so choosing one in Spotlight plays it.
struct PlayAlbumIntent: AudioPlaybackIntent, OpenIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description = IntentDescription("Plays an album in Kaset.")
    static let openAppWhenRun = true

    @Parameter(title: "Album")
    var target: AlbumEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$target)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AppIntentsBridge.shared.play(album: self.target.album)
        return .result()
    }
}

// MARK: - PlayLikedMusicIntent

struct PlayLikedMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Liked Music"
    static let description = IntentDescription("Plays your Liked Music playlist in Kaset.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AppIntentsBridge.shared.play(playlist: LikedMusicPlaylist.playlist)
        return .result()
    }
}
