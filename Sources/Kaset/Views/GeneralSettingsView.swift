import SwiftUI

/// Settings view for general app preferences.
@available(macOS 26.0, *)
struct GeneralSettingsView: View {
    @Environment(AuthService.self) private var authService
    @State private var settings = SettingsManager.shared
    @State private var cacheSize: String = "Calculating..."
    @State private var isClearing = false

    /// The updater service for managing app updates.
    var updaterService: UpdaterService

    var body: some View {
        @Bindable var updater = self.updaterService

        Form {
            // MARK: - General Section

            Section {
                // Account status
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Account")
                            .font(.headline)
                        Text(self.accountStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if self.authService.state.isLoggedIn {
                        Button("Sign Out") {
                            Task {
                                await self.authService.signOut()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                // Now Playing Notifications
                Toggle("Show Now Playing Notifications", isOn: self.$settings.showNowPlayingNotifications)

                // Haptic Feedback
                Toggle("Haptic Feedback", isOn: self.$settings.hapticFeedbackEnabled)
                    .help("Provide tactile feedback for actions on Force Touch trackpads")

                // Remember Playback Settings
                Toggle("Remember Shuffle & Repeat", isOn: self.$settings.rememberPlaybackSettings)
                    .help("Save shuffle and repeat settings across app restarts")

                // Default Launch Page
                Picker("Default Page on Launch", selection: self.$settings.defaultLaunchPage) {
                    ForEach(SettingsManager.LaunchPage.allCases) { page in
                        Text(page.displayName).tag(page)
                    }
                }

                // Image Cache
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image Cache")
                        Text(self.cacheSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(self.isClearing ? "Clearing..." : "Clear Cache") {
                        Task {
                            await self.clearCache()
                        }
                    }
                    .disabled(self.isClearing)
                }
                .padding(.vertical, 4)
            } header: {
                Text("General")
            }

            // MARK: - Updates Section

            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticChecksEnabled)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Software Update")
                        if let lastCheck = self.updaterService.lastUpdateCheckDate {
                            Text("Last checked: \(lastCheck, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Never checked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Check Now") {
                        self.updaterService.checkForUpdates()
                    }
                    .disabled(!self.updaterService.canCheckForUpdates)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Updates")
            }

            // MARK: - About Section

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(self.appVersion)
                        .foregroundStyle(.secondary)
                }

                Link(destination: URL(string: "https://github.com/sozercan/kaset")!) {
                    HStack {
                        Text("GitHub")
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("General")
        .task {
            await self.updateCacheSize()
        }
    }

    // MARK: - Computed Properties

    private var accountStatusText: String {
        self.authService.state.isLoggedIn ? "Signed in to YouTube Music" : "Not signed in"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    // MARK: - Actions

    private func updateCacheSize() async {
        let size = await ImageCache.shared.diskCacheSize()
        self.cacheSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func clearCache() async {
        self.isClearing = true
        await ImageCache.shared.clearAllCaches()
        await self.updateCacheSize()
        self.isClearing = false
    }
}
