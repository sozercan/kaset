import SwiftUI

/// Settings for the regular YouTube video experience (distinct from the Music
/// experience). Currently hosts the ambient backdrop controls; a natural home
/// for future video-only preferences.
struct YouTubeSettingsView: View {
    @State private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Ambient Color Backdrop"), isOn: self.$settings.ambientBackdropEnabled)
                    .help(String(localized: "Show a soft color glow, drawn from the video, behind the player"))

                if self.settings.ambientBackdropEnabled {
                    Picker(String(localized: "Style"), selection: self.$settings.ambientBackdropStyle) {
                        ForEach(AmbientBackdropStyle.userSelectableCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .help(String(localized: "\"Live\" shifts the colors as the video plays; the others stay constant"))
                }
            } header: {
                Text(String(localized: "Ambient Backdrop"))
            } footer: {
                Text(String(localized: "A soft color glow drawn from the video plays behind the player. Applies to YouTube videos, not Music."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "Show Controls on Video"), isOn: self.$settings.showYouTubeControlsOnVideo)
                    .help(String(localized: "Place the playback controls on the video instead of in the bar at the bottom of the window"))
            } header: {
                Text(String(localized: "Player Controls"))
            } footer: {
                Text(String(localized: "Controls appear when you move the pointer over the video and fade out while it plays. The bottom bar returns when you scroll past the video or it plays in the pop-out player."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "Float on Top"), isOn: self.$settings.keepYouTubeVideoOnTop)
                    .help(String(localized: "Keep the video above standard windows on this Space."))

                Toggle(String(localized: "Pop Out Video When Navigating Away"), isOn: self.$settings.popOutVideoOnNavigateAway)
                    .help(String(localized: "Keep a playing video in a floating window when you leave the page. When off, the video stops instead."))
            } header: {
                Text(String(localized: "Video Window"))
            } footer: {
                Text(String(localized: "When off, navigating back from a playing video stops it instead of opening the floating player. The pop-out and full-view buttons still work."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
