import SwiftUI
import CoreImage.CIFilterBuiltins

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
        @Bindable var deviceManager = RemoteDeviceManager.shared

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

                // Synced Lyrics
                Toggle("Enable Synced Lyrics", isOn: self.$settings.syncedLyricsEnabled)
                    .help("Fetch and display real-time synced lyrics when available")

                // Romanization
                Toggle("Romanize Lyrics", isOn: self.$settings.romanizationEnabled)
                    .help("Show romanized text (romaji, pinyin, etc.) below non-Latin lyrics")

                // Remember Playback Settings
                Toggle("Remember Shuffle & Repeat", isOn: self.$settings.rememberPlaybackSettings)
                    .help("Save shuffle and repeat settings across app restarts")

                // Mini Player
                Toggle("Keep Mini Player on Top", isOn: self.$settings.keepMiniPlayerOnTop)
                    .help("Keep the mini player visible above other windows")

                // Playback Audio Quality
                Picker("Playback Audio Quality", selection: self.$settings.playbackAudioQuality) {
                    ForEach(SettingsManager.PlaybackAudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .help("Choose the preferred audio quality for YouTube Music playback")

                // Now Playing Controls
                Picker("Now Playing Controls", selection: self.$settings.mediaControlStyle) {
                    ForEach(SettingsManager.MediaControlStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .help("Choose which buttons appear in the Now Playing widget in Control Center")

                // Local Control API
                Toggle("Local Control API", isOn: self.$settings.localControlServerEnabled)
                    .help("Expose an HTTP API for automation and remote control")

                Stepper(
                    "Local Control Port: \(self.settings.localControlServerPort)",
                    value: self.$settings.localControlServerPort,
                    in: 1024 ... 65_535
                )
                .disabled(!self.settings.localControlServerEnabled)
                .help("Local API endpoint: http://127.0.0.1:\(self.settings.localControlServerPort)")

                Toggle("Allow Local Network Remote", isOn: self.$settings.localControlServerAllowsLAN)
                    .disabled(!self.settings.localControlServerEnabled)
                    .help("Allow devices on the same Wi-Fi to open Kaset Remote using this Mac's IP address")

                HStack {
                    Text("Global PIN")
                    Spacer()
                    TextField("PIN", text: $deviceManager.globalPin)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .disabled(!self.settings.localControlServerEnabled)
                        .help("The security PIN that remote devices must enter to request access")
                }

                if self.settings.localControlServerEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Active Remote URL(s)")
                            .font(.headline)
                        
                        ForEach(LocalControlServer.localControlURLs(), id: \.self) { url in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(url.absoluteString)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Copy URL")
                                }
                                
                                // Show QR code for LAN URL (non-localhost)
                                if url.host != "127.0.0.1" {
                                    HStack {
                                        Spacer()
                                        QRCodeView(urlString: url.absoluteString)
                                            .help("Scan with your phone to open the Remote Control page")
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    // Pending Approvals Section
                    if !deviceManager.pendingRequests.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pending Approvals (\(deviceManager.pendingRequests.count))")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            
                            ForEach(deviceManager.pendingRequests) { request in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(request.name)
                                            .font(.subheadline)
                                        Text(request.requestedAt, style: .time)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Approve") {
                                        deviceManager.approveDevice(deviceId: request.deviceId)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                    
                                    Button("Deny") {
                                        deviceManager.denyDevice(deviceId: request.deviceId)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // Approved Devices Section
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Approved Devices (\(deviceManager.approvedDevices.count))")
                            .font(.headline)
                        
                        if deviceManager.approvedDevices.isEmpty {
                            Text("No approved devices yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(deviceManager.approvedDevices) { device in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.subheadline)
                                        Text("Active: \(device.lastActive, style: .relative)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Revoke") {
                                        deviceManager.revokeDevice(deviceId: device.deviceId)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Default Launch Page
                Picker("Default Page on Launch", selection: self.$settings.defaultLaunchPage) {
                    ForEach(SettingsManager.LaunchPage.allCases) { page in
                        Text(page.displayName).tag(page)
                    }
                }

                // Content Language
                Picker("Content Language", selection: self.$settings.contentLanguage) {
                    ForEach(SettingsManager.ContentLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .help("Choose the language for the app interface")

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
                Text("General")
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
        self.authService.state.isLoggedIn ? String(localized: "Signed in to YouTube Music") : String(localized: "Not signed in")
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

struct QRCodeView: View {
    let urlString: String

    var body: some View {
        if let image = self.generateQRCode(from: self.urlString) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .padding(6)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            VStack {
                Image(systemName: "xmark.circle")
                Text("QR Error")
            }
        }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)

        if let outputImage = filter.outputImage {
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)
            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                return NSImage(cgImage: cgImage, size: NSSize(width: 120, height: 120))
            }
        }
        return nil
    }
}
