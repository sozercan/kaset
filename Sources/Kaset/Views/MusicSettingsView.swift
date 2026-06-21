import SwiftUI

/// Settings for the YouTube Music experience (distinct from the YouTube video
/// experience). Hosts the playback, now-playing, audio-quality, and lyrics
/// preferences that only apply when `appSource` is `.music`.
struct MusicSettingsView: View {
    @State private var settings = SettingsManager.shared

    var body: some View {
        Form {
            // MARK: - Now Playing Section

            Section {
                Toggle("Show Now Playing Notifications", isOn: self.$settings.showNowPlayingNotifications)
                    .help("Show a notification when a new track starts playing")

                Picker("Now Playing Controls", selection: self.$settings.mediaControlStyle) {
                    ForEach(SettingsManager.MediaControlStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .help("Choose which buttons appear in the Now Playing widget in Control Center")

                Toggle("Keep Mini Player on Top", isOn: self.$settings.keepMiniPlayerOnTop)
                    .help("Keep the mini player visible above other windows")

                Toggle("Remember Shuffle & Repeat", isOn: self.$settings.rememberPlaybackSettings)
                    .help("Save shuffle and repeat settings across app restarts")
            } header: {
                Text("Now Playing")
            }

            // MARK: - Audio Section

            Section {
                Picker("Playback Audio Quality", selection: self.$settings.playbackAudioQuality) {
                    ForEach(SettingsManager.PlaybackAudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .help("Choose the preferred audio quality for YouTube Music playback")
            } header: {
                Text("Audio")
            }

            // MARK: - Lyrics Section

            Section {
                Toggle("Enable Synced Lyrics", isOn: self.$settings.syncedLyricsEnabled)
                    .help("Fetch and display real-time synced lyrics when available")

                Toggle("Romanize Lyrics", isOn: self.$settings.romanizationEnabled)
                    .help("Show romanized text (romaji, pinyin, etc.) below non-Latin lyrics")
            } header: {
                Text("Lyrics")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .localizedNavigationTitle("Music")
    }
}
