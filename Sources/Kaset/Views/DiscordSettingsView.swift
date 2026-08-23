import SwiftUI

// MARK: - DiscordSettingsView

/// Settings view for configuring Discord Rich Presence options and privacy toggles.
struct DiscordSettingsView: View {
    @Environment(DiscordPresenceCoordinator.self) private var coordinator
    @State private var settings = SettingsManager.shared

    var body: some View {
        Form {
            // MARK: - General Integration

            Section {
                Toggle(String(localized: "Enable Discord Rich Presence"), isOn: self.$settings.discordPresenceEnabled)
                    .onChange(of: self.settings.discordPresenceEnabled) { _, isEnabled in
                        if isEnabled {
                            Task {
                                await self.coordinator.connect()
                            }
                        } else {
                            Task {
                                await self.coordinator.disconnect()
                            }
                        }
                    }

                if self.settings.discordPresenceEnabled {
                    // Connection status row
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Status"))
                                .font(.headline)
                            Text(self.statusDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        self.connectionActionControl
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(String(localized: "Discord Integration"))
            } footer: {
                Text(String(localized: "Requires the Discord desktop app to be installed and running locally on your Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if self.settings.discordPresenceEnabled {
                // MARK: - Content Experience Sources

                Section {
                    Toggle(String(localized: "Show YouTube Music Listening Status"), isOn: self.$settings.discordShowMusic)
                    Toggle(String(localized: "Show YouTube Video Watching Status"), isOn: self.$settings.discordShowVideo)
                } header: {
                    Text(String(localized: "Activity Sources"))
                }

                // MARK: - Privacy & Metadata Toggles

                Section {
                    Toggle(String(localized: "Show Song / Video Title"), isOn: self.$settings.discordShowTitle)
                    Toggle(String(localized: "Show Artist / Channel Name"), isOn: self.$settings.discordShowArtist)
                    Toggle(String(localized: "Show Album Name"), isOn: self.$settings.discordShowAlbum)
                    Toggle(String(localized: "Show Elapsed / Duration Timestamps"), isOn: self.$settings.discordShowTimestamps)
                    Toggle(String(localized: "Show Artwork Image"), isOn: self.$settings.discordShowArtwork)
                    Toggle(String(localized: "Show 'Listen on YouTube Music' Button"), isOn: self.$settings.discordShowListenButton)
                } header: {
                    Text(String(localized: "Presence Details & Privacy"))
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .localizedNavigationTitle("Discord")
    }

    // MARK: - Computed Properties

    private var statusDescription: String {
        switch self.coordinator.state {
        case .disconnected:
            String(localized: "Disconnected")
        case let .connecting(attempt):
            String(localized: "Connecting (attempt \(attempt)/5)…")
        case .connected:
            String(localized: "Connected & Active")
        case let .error(message):
            String(localized: String.LocalizationValue(message))
        }
    }

    @ViewBuilder
    private var connectionActionControl: some View {
        switch self.coordinator.state {
        case .disconnected, .error:
            Button(String(localized: "Connect")) {
                Task {
                    await self.coordinator.connect()
                }
            }

        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Button(String(localized: "Cancel")) {
                    Task {
                        await self.coordinator.disconnect()
                    }
                }
            }

        case .connected:
            Button(String(localized: "Disconnect")) {
                Task {
                    await self.coordinator.disconnect()
                }
            }
        }
    }
}
