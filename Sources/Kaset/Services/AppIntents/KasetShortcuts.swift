import AppIntents

/// App Shortcuts: Siri phrases and Spotlight actions that work without any setup.
///
/// Phrases are localized from `AppShortcuts.xcstrings`; `Scripts/build-app.sh` fails the
/// build when a phrase here has no catalog entry. Every phrase must name the app.
struct KasetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play music in \(.applicationName)",
                "Play something in \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: PlayLikedMusicIntent(),
            phrases: [
                "Play my liked songs in \(.applicationName)",
                "Play liked songs in \(.applicationName)",
            ],
            shortTitle: "Liked Music",
            systemImageName: "hand.thumbsup.fill"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$target) in \(.applicationName)",
                "Play my \(\.$target) playlist in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause music in \(.applicationName)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume music in \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: [
                "Skip this song in \(.applicationName)",
                "Next song in \(.applicationName)",
            ],
            shortTitle: "Next Song",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: [
                "Previous song in \(.applicationName)",
            ],
            shortTitle: "Previous Song",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: LikeCurrentSongIntent(),
            phrases: [
                "Like this song in \(.applicationName)",
                "Like the current song in \(.applicationName)",
            ],
            shortTitle: "Like Song",
            systemImageName: "hand.thumbsup"
        )
        AppShortcut(
            intent: GetCurrentSongIntent(),
            phrases: [
                "What's playing in \(.applicationName)",
                "What song is this in \(.applicationName)",
            ],
            shortTitle: "Now Playing",
            systemImageName: "waveform"
        )
    }
}
