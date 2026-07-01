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

            // MARK: - Smart Shuffle Section

            Section {
                Toggle("Enable Smart Shuffle", isOn: self.$settings.smartShuffleEnabled)
                    .help("Adds a third 'smart' state to the shuffle button that interleaves recommended tracks into your queue")

                if self.settings.smartShuffleEnabled {
                    self.numberField(
                        label: "Insert a suggestion every",
                        unit: "songs",
                        value: self.$settings.smartShuffleSuggestEveryN
                    )
                    .help("How far apart suggestions are placed (every N of your playlist's songs)")

                    self.numberField(
                        label: "Suggestions per insertion",
                        unit: nil,
                        value: self.$settings.smartShuffleBurst
                    )
                    .help("How many recommended tracks to drop in at each insertion point")

                    self.numberField(
                        label: "Keep suggestions queued ahead",
                        unit: "tracks",
                        value: self.$settings.smartShuffleSuggestionsAhead
                    )
                    .help("How many recommendations to keep ready ahead of the current track")
                }
            } header: {
                Text("Smart Shuffle")
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

    /// A Form row with a leading label, a trailing numeric entry field, and an optional unit suffix.
    private func numberField(label: LocalizedStringKey, unit: LocalizedStringKey?, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .labelsHidden()
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text(label))
            if let unit {
                Text(unit)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
