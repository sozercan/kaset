import SwiftUI

/// View menu commands that move between sections, routed to the active source's equivalent destination.
struct NavigationCommands: Commands {
    @Binding var navigationSelection: NavigationItem?
    @Binding var youtubeNavigationSelection: YouTubeNavigationItem?
    @Binding var homeRefreshRequestID: Int
    @Binding var navigateBackRequestID: Int
    @Binding var showCommandBar: Bool
    @Binding var searchFocusTrigger: Bool
    @Binding var sidebarNavigationReselectGenerations: [NavigationItem: Int]
    @Bindable var settings: SettingsManager
    let youtubePlayerService: YouTubePlayerService

    var body: some Commands {
        // Navigation commands - replace default sidebar toggle
        // Each routes to the active source's equivalent destination.
        CommandGroup(replacing: .sidebar) {
            Button(String(localized: "Refresh")) {
                self.homeRefreshRequestID += 1
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!self.canRefreshHome)

            // Back - ⌘[
            Button(String(localized: "Back")) {
                self.navigateBackRequestID += 1
            }
            .keyboardShortcut("[", modifiers: .command)

            Divider()

            // Home - ⌘1
            Button(String(localized: "Home")) {
                if self.settings.appSource == .video {
                    self.youtubeNavigationSelection = .home
                } else {
                    self.navigationSelection = .home
                }
            }
            .keyboardShortcut("1", modifiers: .command)

            // Explore - ⌘2
            Button(String(localized: "Explore")) {
                if self.settings.appSource == .video {
                    self.youtubeNavigationSelection = .explore
                } else {
                    self.navigationSelection = .explore
                }
            }
            .keyboardShortcut("2", modifiers: .command)

            // Library - ⌘3
            Button(String(localized: "Library")) {
                if self.settings.appSource == .video {
                    self.youtubeNavigationSelection = .playlists
                } else {
                    self.navigationSelection = .library
                }
            }
            .keyboardShortcut("3", modifiers: .command)

            Divider()

            // Switch Source - ⌘⇧Y
            Button(self.settings.appSource == .music ? "Switch to YouTube" : "Switch to Music") {
                if self.settings.appSource == .video {
                    // Pause a docked video in place — no pop-out handoff.
                    self.youtubePlayerService.prepareForSourceSwitch()
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.settings.appSource = self.settings.appSource == .music ? .video : .music
                }
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])

            Divider()

            // Search - ⌘F
            Button(String(localized: "Search")) {
                if self.settings.appSource == .video {
                    self.youtubeNavigationSelection = .search
                    return
                }
                self.activateMusicSearch()
            }
            .keyboardShortcut("f", modifiers: .command)

            // Command Bar - ⌘K
            if PlatformCapabilities.supportsCommandBar(usesLegacyMacOS15UI: self.settings.useLegacyMacOS15UI) {
                Button(String(localized: "Command Bar")) {
                    self.showCommandBar = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            Divider()

            Toggle(String(localized: "Float on Top"), isOn: self.$settings.keepYouTubeVideoOnTop)
                .disabled(!YouTubeVideoWindowLevelPolicy.canToggleFloatOnTop(
                    isFloating: self.youtubePlayerService.surfaceLocation == .floating,
                    isFullscreenOrTransitioning: self.youtubePlayerService.isWindowFullscreen
                ))

            Divider()

            Picker(String(localized: "Appearance"), selection: self.$settings.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    private func activateMusicSearch() {
        let alreadyOnSearch = self.navigationSelection == .search
        self.navigationSelection = .search
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            if alreadyOnSearch {
                self.sidebarNavigationReselectGenerations[.search, default: 0] += 1
            }
            self.searchFocusTrigger = true
        }
    }

    private var canRefreshHome: Bool {
        switch self.settings.appSource {
        case .music:
            self.navigationSelection == .home
        case .video:
            self.youtubeNavigationSelection == .home
        }
    }
}
