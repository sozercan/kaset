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
