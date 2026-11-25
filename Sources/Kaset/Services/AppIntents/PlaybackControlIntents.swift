import AppIntents
import Foundation

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Pauses Kaset if it is playing, otherwise resumes playback.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try AppIntentsBridge.shared.sendTransportCommand(.togglePlayPause)
        return .result()
    }
}

struct PausePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause"
    static let description = IntentDescription("Pauses playback in Kaset.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try AppIntentsBridge.shared.sendTransportCommand(.pause)
        return .result()
    }
}

struct ResumePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Playback"
    static let description = IntentDescription("Resumes playback in Kaset.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try AppIntentsBridge.shared.sendTransportCommand(.play)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skips to the next track in Kaset.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try AppIntentsBridge.shared.sendTransportCommand(.trackNavigation(direction: .forward))
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description = IntentDescription("Goes back to the previous track in Kaset.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try AppIntentsBridge.shared.sendTransportCommand(.trackNavigation(direction: .backward))
        return .result()
    }
}

struct GetCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Song"
    static let description = IntentDescription("Returns the song playing in Kaset.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SongEntity> & ProvidesDialog {
        guard let song = AppIntentsBridge.shared.currentSong else {
            throw AppIntentsError.nothingPlaying
        }
        let entity = SongEntity(song: song)
        let dialog: IntentDialog = entity.artist.isEmpty
            ? "Now playing \(entity.title)."
            : "Now playing \(entity.title) by \(entity.artist)."
        return .result(value: entity, dialog: dialog)
    }
}

struct LikeCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Like Current Song"
    static let description = IntentDescription("Likes the song playing in Kaset. A song that is already liked stays liked.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SongEntity> {
        let song = try await AppIntentsBridge.shared.rateCurrentSong(.like)
        return .result(value: SongEntity(song: song))
    }
}

struct DislikeCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Dislike Current Song"
    static let description = IntentDescription("Dislikes the song playing in Kaset. A song that is already disliked stays disliked.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SongEntity> {
        let song = try await AppIntentsBridge.shared.rateCurrentSong(.dislike)
        return .result(value: SongEntity(song: song))
    }
}
