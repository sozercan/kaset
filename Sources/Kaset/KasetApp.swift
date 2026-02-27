import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var searchFocusTrigger: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    @Entry var navigationSelection: Binding<NavigationItem?> = .constant(nil)
}

extension EnvironmentValues {
    @Entry var showCommandBar: Binding<Bool> = .constant(false)
}

// MARK: - KasetApp

/// Main entry point for the Kaset macOS application.
@available(macOS 26.0, *)
@main
struct KasetApp: App {
    /// App delegate for lifecycle management (background playback).
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var authService = AuthService()
    @State private var webKitManager = WebKitManager.shared
    @State private var playerService = PlayerService()
    @State private var sharedClient: any YTMusicClientProtocol
    @State private var notificationService: NotificationService?
    @State private var updaterService = UpdaterService()
    @State private var favoritesManager = FavoritesManager.shared
    @State private var likeStatusManager = SongLikeStatusManager.shared
    @State private var accountService: AccountService?
    @State private var scrobblingCoordinator: ScrobblingCoordinator

    /// Triggers search field focus when set to true.
    @State private var searchFocusTrigger = false

    /// Current navigation selection for keyboard navigation.
    @State private var navigationSelection: NavigationItem? = SettingsManager.shared.launchNavigationItem

    /// Whether the command bar is visible.
    @State private var showCommandBar = false

    init() {
        let auth = AuthService()
        let webkit = WebKitManager.shared
        let player = PlayerService()

        // Use mock client in UI test mode, real client otherwise
        let realClient = YTMusicClient(authService: auth, webKitManager: webkit)
        let client: YTMusicClientProtocol = if UITestConfig.isUITestMode {
            MockUITestYTMusicClient()
        } else {
            realClient
        }

        // Wire up dependencies
        player.setYTMusicClient(client)
        SongLikeStatusManager.shared.setClient(client)

        // Set shared instance for AppleScript access
        PlayerService.shared = player

        // Create account service
        let account = AccountService(ytMusicClient: client, authService: auth)

        // Wire up brand account provider so API requests use the correct account
        realClient.brandIdProvider = { [weak account] in
            account?.currentBrandId
        }

        _authService = State(initialValue: auth)
        _webKitManager = State(initialValue: webkit)
        _playerService = State(initialValue: player)
        _sharedClient = State(initialValue: client)
        _notificationService = State(initialValue: NotificationService(playerService: player))
        _accountService = State(initialValue: account)

        // Create scrobbling coordinator
        let lastFMService = LastFMService(credentialStore: KeychainCredentialStore())
        let scrobblingCoordinator = ScrobblingCoordinator(
            playerService: player,
            services: [lastFMService]
        )
        scrobblingCoordinator.restoreAuthState()
        scrobblingCoordinator.startMonitoring()
        _scrobblingCoordinator = State(initialValue: scrobblingCoordinator)

        // Wire up PlayerService to AppDelegate immediately (not in onAppear)
        // This ensures playerService is available for lifecycle events like queue restoration
        self.appDelegate.playerService = player

        if UITestConfig.isUITestMode {
            DiagnosticsLogger.ui.info("App launched in UI Test mode")
        }
    }

    var body: some Scene {
        Window("Kaset", id: "main") {
            // Skip UI during unit tests to prevent window spam
            if UITestConfig.isRunningUnitTests, !UITestConfig.isUITestMode {
                Color.clear
                    .frame(width: 1, height: 1)
            } else {
                MainWindow(navigationSelection: self.$navigationSelection, client: self.sharedClient)
                    .environment(self.authService)
                    .environment(self.webKitManager)
                    .environment(self.playerService)
                    .environment(self.favoritesManager)
                    .environment(self.likeStatusManager)
                    .environment(self.accountService)
                    .environment(self.scrobblingCoordinator)
                    .environment(\.searchFocusTrigger, self.$searchFocusTrigger)
                    .environment(\.navigationSelection, self.$navigationSelection)
                    .environment(\.showCommandBar, self.$showCommandBar)
                    .onAppear {
                        // Wire up PlayerService to AppDelegate for dock menu and AppleScript actions
                        // This runs synchronously so AppleScript commands can access playerService immediately
                        self.appDelegate.playerService = self.playerService
                        // Reference notificationService to keep SwiftUI from deallocating it
                        _ = self.notificationService
                    }
                    .task {
                        // Check if user is already logged in from previous session
                        await self.authService.checkLoginStatus()

                        // Fetch accounts after login check (for account switcher)
                        await self.accountService?.fetchAccounts()

                        // Warm up Foundation Models in background
                        await FoundationModelsService.shared.warmup()
                    }
                    .onOpenURL { url in
                        self.handleIncomingURL(url)
                    }
            }
        }

        Settings {
            SettingsView()
                .environment(self.authService)
                .environment(self.updaterService)
                .environment(self.scrobblingCoordinator)
        }
        .commands {
            // Check for Updates command in app menu
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    self.updaterService.checkForUpdates()
                }
                .disabled(!self.updaterService.canCheckForUpdates)
            }

            // Playback commands
            CommandMenu("Playback") {
                // Play/Pause - Space
                Button(self.playerService.isPlaying ? "Pause" : "Play") {
                    Task {
                        await self.playerService.playPause()
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(self.playerService.currentTrack == nil && self.playerService.pendingPlayVideoId == nil)

                Divider()

                // Next Track - ⌘→
                Button("Next") {
                    Task {
                        await self.playerService.next()
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                // Previous Track - ⌘←
                Button("Previous") {
                    Task {
                        await self.playerService.previous()
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Divider()

                // Volume Up - ⌘↑
                Button("Volume Up") {
                    Task {
                        await self.playerService.setVolume(min(1.0, self.playerService.volume + 0.1))
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                // Volume Down - ⌘↓
                Button("Volume Down") {
                    Task {
                        await self.playerService.setVolume(max(0.0, self.playerService.volume - 0.1))
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                // Mute - ⌘⇧M
                Button(self.playerService.isMuted ? "Unmute" : "Mute") {
                    Task {
                        await self.playerService.toggleMute()
                    }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                // Shuffle - ⌘S
                Button(self.playerService.shuffleEnabled ? "Shuffle Off" : "Shuffle On") {
                    self.playerService.toggleShuffle()
                }
                .keyboardShortcut("s", modifiers: .command)

                // Repeat - ⌘R
                Button(self.repeatModeLabel) {
                    self.playerService.cycleRepeatMode()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                // Lyrics - ⌘L
                Button(self.playerService.showLyrics ? "Hide Lyrics" : "Show Lyrics") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.playerService.showLyrics.toggle()
                    }
                }
                .keyboardShortcut("l", modifiers: .command)
            }

            // Navigation commands - replace default sidebar toggle
            CommandGroup(replacing: .sidebar) {
                // Home - ⌘1
                Button("Home") {
                    self.navigationSelection = .home
                }
                .keyboardShortcut("1", modifiers: .command)

                // Explore - ⌘2
                Button("Explore") {
                    self.navigationSelection = .explore
                }
                .keyboardShortcut("2", modifiers: .command)

                // Library - ⌘3
                Button("Library") {
                    self.navigationSelection = .library
                }
                .keyboardShortcut("3", modifiers: .command)

                Divider()

                // Search - ⌘F
                Button("Search") {
                    self.navigationSelection = .search
                    // Trigger focus after a brief delay to allow view to appear
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        self.searchFocusTrigger = true
                    }
                }
                .keyboardShortcut("f", modifiers: .command)

                // Command Bar - ⌘K
                Button("Command Bar") {
                    self.showCommandBar = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            // Window menu - show main window
            CommandGroup(after: .windowArrangement) {
                Button("Kaset") {
                    self.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    /// Shows the main window.
    private func showMainWindow() {
        // Find and show the main window
        for window in NSApplication.shared.windows where window.frameAutosaveName == "KasetMainWindow" {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        // Fallback: find any main-capable window that's not the video window
        for window in NSApplication.shared.windows where window.canBecomeMain {
            if window.identifier?.rawValue == AccessibilityID.VideoWindow.container {
                continue
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
    }

    /// Label for repeat mode menu item.
    private var repeatModeLabel: String {
        switch self.playerService.repeatMode {
        case .off:
            "Repeat All"
        case .all:
            "Repeat One"
        case .one:
            "Repeat Off"
        }
    }

    // MARK: - URL Handling

    /// Handles an incoming URL (from custom scheme).
    private func handleIncomingURL(_ url: URL) {
        DiagnosticsLogger.app.info("Received URL: \(url.absoluteString)")

        guard let content = URLHandler.parse(url) else {
            DiagnosticsLogger.app.warning("Unrecognized URL format: \(url.absoluteString)")
            return
        }

        // If not logged in, ignore for now
        guard self.authService.state.isLoggedIn else {
            DiagnosticsLogger.app.info("Not logged in, ignoring URL")
            return
        }

        self.handleParsedContent(content)
    }

    /// Handles parsed URL content.
    private func handleParsedContent(_ content: URLHandler.ParsedContent) {
        switch content {
        case let .song(videoId):
            DiagnosticsLogger.app.info("Playing song from URL: \(videoId)")
            let song = Song(
                id: videoId,
                title: "Loading...",
                artists: [],
                videoId: videoId
            )
            Task {
                await self.playerService.play(song: song)
            }

        case .playlist, .album, .artist:
            // Only song playback is supported via URL scheme
            DiagnosticsLogger.app.info("URL scheme only supports song playback")
        }
    }
}

// MARK: - SettingsView

/// Main settings view with tabbed navigation.
@available(macOS 26.0, *)
struct SettingsView: View {
    @Environment(UpdaterService.self) private var updaterService
    @Environment(ScrobblingCoordinator.self) private var scrobblingCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView(updaterService: self.updaterService)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            IntelligenceSettingsView()
                .tabItem {
                    Label("Intelligence", systemImage: "sparkles")
                }

            ScrobblingSettingsView()
                .environment(self.scrobblingCoordinator)
                .tabItem {
                    Label("Scrobbling", systemImage: "music.note.list")
                }
        }
        .frame(width: 450, height: 400)
    }
}
