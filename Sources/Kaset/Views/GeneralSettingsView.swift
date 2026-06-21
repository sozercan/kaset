import SwiftUI

/// Settings view for general app preferences.
struct GeneralSettingsView: View {
    @Environment(AuthService.self) private var authService
    @State private var settings = SettingsManager.shared
    @State private var cacheSize: String = .init(localized: "Calculating...")
    @State private var isClearing = false

    /// The updater service for managing app updates.
    var updaterService: UpdaterService

    var body: some View {
        @Bindable var updater = self.updaterService

        Form {
            // MARK: - Account Section

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
            } header: {
                Text("Account")
            }

            // MARK: - Behavior Section

            Section {
                // Haptic Feedback
                Toggle("Haptic Feedback", isOn: self.$settings.hapticFeedbackEnabled)
                    .help("Provide tactile feedback for actions on Force Touch trackpads")

                // Default Launch Page
                Picker("Default Page on Launch", selection: self.$settings.defaultLaunchPage) {
                    ForEach(SettingsManager.LaunchPage.allCases) { page in
                        Text(page.displayName).tag(page)
                    }
                }
            } header: {
                Text("Behavior")
            }

            // MARK: - Language Section

            Section {
                // Content Language
                Picker("Content Language", selection: self.$settings.contentLanguage) {
                    ForEach(SettingsManager.ContentLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .help("Choose the language for content and search results from YouTube Music")
            } header: {
                Text("Language")
            }

            // MARK: - Storage Section

            Section {
                // Image Cache
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image Cache")
                        Text(self.cacheSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(self.isClearing ? String(localized: "Clearing...") : String(localized: "Clear Cache")) {
                        Task {
                            await self.clearCache()
                        }
                    }
                    .disabled(self.isClearing)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Storage")
            }

            #if DEBUG

                // MARK: - Debug Section

                Section {
                    Toggle("Use Legacy macOS 15 UI", isOn: self.$settings.useLegacyMacOS15UI)
                        .help("Force macOS 15 fallback views and materials while running on macOS 26+ for compatibility debugging")

                    Text("Disables Liquid Glass, the Command Bar, and Apple Intelligence UI surfaces until toggled off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Debug")
                }
            #endif

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
        .localizedNavigationTitle("General")
        .task {
            await self.updateCacheSize()
        }
    }

    // MARK: - Computed Properties

    private var accountStatusText: String {
        self.authService.state.isLoggedIn ? String(localized: "Signed in to YouTube") : String(localized: "Not signed in")
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
