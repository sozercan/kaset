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
                    .help(String(localized: "Show a notification when a new track starts playing"))

                Picker(String(localized: "Now Playing Controls"), selection: self.$settings.mediaControlStyle) {
                    ForEach(SettingsManager.MediaControlStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .help(String(localized: "Choose which buttons appear in the Now Playing widget in Control Center"))

                Toggle(String(localized: "Keep Mini Player on Top"), isOn: self.$settings.keepMiniPlayerOnTop)
                    .help(String(localized: "Keep the mini player visible above other windows"))

                Toggle("Remember Shuffle & Repeat", isOn: self.$settings.rememberPlaybackSettings)
                    .help(String(localized: "Save shuffle and repeat settings across app restarts"))
            } header: {
                Text(String(localized: "Now Playing"))
            }

            // MARK: - Smart Shuffle Section

            Section {
                Toggle("Enable Smart Shuffle", isOn: self.$settings.smartShuffleEnabled)
                    .help(String(localized: "Adds a third 'smart' state to the shuffle button that interleaves recommended tracks into your queue"))

                if self.settings.smartShuffleEnabled {
                    self.numberField(
                        label: "Insert a suggestion every",
                        unit: "songs",
                        value: self.$settings.smartShuffleSuggestEveryN
                    )
                    .help(String(localized: "How far apart suggestions are placed (every N of your playlist's songs)"))

                    self.numberField(
                        label: "Suggestions per insertion",
                        unit: nil,
                        value: self.$settings.smartShuffleBurst
                    )
                    .help(String(localized: "How many recommended tracks to drop in at each insertion point"))

                    self.numberField(
                        label: "Keep suggestions queued ahead",
                        unit: "tracks",
                        value: self.$settings.smartShuffleSuggestionsAhead
                    )
                    .help(String(localized: "How many recommendations to keep ready ahead of the current track"))
                }
            } header: {
                Text(String(localized: "Smart Shuffle"))
            }

            // MARK: - Audio Section

            Section {
                Picker(String(localized: "Playback Audio Quality"), selection: self.$settings.playbackAudioQuality) {
                    ForEach(SettingsManager.PlaybackAudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .help(String(localized: "Choose the preferred audio quality for YouTube Music playback"))
            } header: {
                Text(String(localized: "Audio"))
            }

            // MARK: - Lyrics Section

            Section {
                Toggle("Enable Synced Lyrics", isOn: self.$settings.syncedLyricsEnabled)
                    .help(String(localized: "Fetch and display real-time synced lyrics when available"))

                Toggle("Romanize Lyrics", isOn: self.$settings.romanizationEnabled)
                    .help(String(localized: "Show romanized text (romaji, pinyin, etc.) below non-Latin lyrics"))
            } header: {
                Text(String(localized: "Lyrics"))
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
