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

extension EnvironmentValues {
    @Entry var showWhatsNew: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    @Entry var usesLegacyMacOS15UI = false
}

// MARK: - KasetApp

/// Main entry point for the Kaset macOS application.
@main
struct KasetApp: App {
    /// App delegate for lifecycle management (background playback).
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    @State private var authService = AuthService()
    @State private var webKitManager = WebKitManager.shared
    @State private var playerService = PlayerService()
    @State private var youtubePlayerService: YouTubePlayerService
    @State private var playbackArbiter: PlaybackArbiter
    @State private var sharedClient: any YTMusicClientProtocol
    @State private var sharedYouTubeClient: any YouTubeClientProtocol
    @State private var notificationService: NotificationService?
    @State private var updaterService = UpdaterService()
    @State private var favoritesManager = FavoritesManager.shared
    @State private var sidebarPinnedItemsManager = SidebarPinnedItemsManager.shared
    @State private var likeStatusManager = SongLikeStatusManager.shared
    @State private var accountService: AccountService?
    @State private var scrobblingCoordinator: ScrobblingCoordinator
    @State private var syncedLyricsService: SyncedLyricsService
    @State private var equalizerService = EqualizerService.shared
    @State private var settings = SettingsManager.shared
    @State private var podcastsAvailabilityService = PodcastsAvailabilityService()

    /// Triggers search field focus when set to true.
    @State private var searchFocusTrigger = false

    /// Current navigation selection for keyboard navigation.
    @State private var navigationSelection: NavigationItem? = SettingsManager.shared.launchNavigationItem

    /// Current navigation selection for the YouTube (video) experience.
    @State private var youtubeNavigationSelection: YouTubeNavigationItem? = .home

    /// Whether the command bar is visible.
    @State private var showCommandBar = false

    /// Whether the "What's New" sheet should be shown.
    @State private var showWhatsNew = false

    /// Incoming app URLs received before auth initialization and guest-startup
    /// cleanup complete. These are replayed only after guest cleanup has run so
    /// cleanup cannot erase URL-started playback.
    @State private var pendingIncomingURL: URL?

    @State private var didCompleteStartupPlaybackCleanup = false

    init() {
        Bundle.enableAppLocalizationOverride()

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
        player.setAuthService(auth)
        SongLikeStatusManager.shared.setClient(client)

        // Set shared instance for AppleScript access
        PlayerService.shared = player

        // Create account service
        let account = AccountService(ytMusicClient: client, authService: auth, webKitManager: webkit)

        // Wire up brand account provider so API requests use the correct account
        realClient.brandIdProvider = { [weak account] in
            account?.currentBrandId
        }

        // YouTube (video) client — same login, www.youtube.com origin
        let realYouTubeClient = YouTubeClient(authService: auth, webKitManager: webkit)
        realYouTubeClient.brandIdProvider = { [weak account] in
            account?.currentBrandId
        }
        realYouTubeClient.accountCacheIdentityProvider = { [weak account] in
            account?.currentAccount?.cacheIdentity
        }
        let youtubeClient: YouTubeClientProtocol = if UITestConfig.isUITestMode {
            MockUITestYouTubeClient()
        } else {
            realYouTubeClient
        }

        // YouTube video playback service + the one-audio-source arbiter
        let youtubePlayer = YouTubePlayerService(webKitManager: webkit)
        youtubePlayer.youtubeClient = youtubeClient
        let arbiter = PlaybackArbiter(playerService: player, youtubePlayerService: youtubePlayer)

        _authService = State(initialValue: auth)
        _webKitManager = State(initialValue: webkit)
        _playerService = State(initialValue: player)
        _youtubePlayerService = State(initialValue: youtubePlayer)
        _playbackArbiter = State(initialValue: arbiter)
        _sharedClient = State(initialValue: client)
        _sharedYouTubeClient = State(initialValue: youtubeClient)
        _syncedLyricsService = State(initialValue: SyncedLyricsService(providers: [
            YTMusicSyncedProvider(client: client),
            LRCLibProvider(),
        ]))
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
                MainWindow(
                    navigationSelection: self.$navigationSelection,
                    youtubeNavigationSelection: self.$youtubeNavigationSelection,
                    didCompleteStartupPlaybackCleanup: self.$didCompleteStartupPlaybackCleanup,
                    client: self.sharedClient,
                    youtubeClient: self.sharedYouTubeClient
                )
                .id(self.settings.contentLanguage)
                .environment(\.locale, self.settings.contentLanguage.locale)
                .environment(self.authService)
                .environment(self.webKitManager)
                .environment(self.playerService)
                .environment(self.youtubePlayerService)
                .environment(self.favoritesManager)
                .environment(self.sidebarPinnedItemsManager)
                .environment(self.likeStatusManager)
                .environment(self.accountService)
                .environment(self.scrobblingCoordinator)
                .environment(self.syncedLyricsService)
                .environment(self.equalizerService)
                .environment(self.podcastsAvailabilityService)
                .environment(\.searchFocusTrigger, self.$searchFocusTrigger)
                .environment(\.navigationSelection, self.$navigationSelection)
                .environment(\.showCommandBar, self.$showCommandBar)
                .environment(\.showWhatsNew, self.$showWhatsNew)
                .environment(\.usesLegacyMacOS15UI, self.settings.useLegacyMacOS15UI)
                .onAppear {
                    DiagnosticsLogger.app.info("KasetApp: App content appeared")
                    // Wire up PlayerService to AppDelegate for dock menu and AppleScript actions
                    // This runs synchronously so AppleScript commands can access playerService immediately
                    self.appDelegate.playerService = self.playerService
                    // Reference notificationService to keep SwiftUI from deallocating it
                    _ = self.notificationService
                }
                .task {
                    DiagnosticsLogger.app.info("KasetApp: Root task started")
                    // Check if user is already logged in from previous session
                    await self.authService.checkLoginStatus()
                    DiagnosticsLogger.app.info("KasetApp: Login status check complete")
                    if !self.didCompleteStartupPlaybackCleanup {
                        if self.authService.state.isLoggedIn {
                            self.playerService.clearGuestPlaybackForAuthenticatedStartup()
                        } else {
                            self.playerService.clearPlaybackForGuestStartup()
                            self.youtubePlayerService.stop()
                        }
                        self.didCompleteStartupPlaybackCleanup = true
                    }
                    self.drainPendingIncomingURLIfReady()

                    // Fetch accounts after login check (for account switcher)
                    await self.accountService?.fetchAccounts()

                    // Warm up Foundation Models in background (macOS 26+ only)
                    if !self.settings.useLegacyMacOS15UI, #available(macOS 26.0, *) {
                        await FoundationModelsService.shared.warmup()
                    }
                }
                .onOpenURL { url in
                    self.handleIncomingURL(url)
                }
                .onChange(of: self.playerService.isPlaying) { _, isPlaying in
                    // The Core Audio process tap needs WebKit's GPU
                    // process to be actively emitting audio before it
                    // can be discovered. When playback starts, give the
                    // equalizer a chance to spin up.
                    if isPlaying {
                        self.equalizerService.retryStartIfEnabled()
                        // One audio source at a time: music starting pauses video.
                        self.playbackArbiter.musicDidStartPlaying()
                    }
                }
                .onChange(of: self.youtubePlayerService.surfaceLocation) { _, location in
                    self.handleYouTubeSurfaceLocationChange(location)
                }
                .onChange(of: self.youtubePlayerService.popInRequest) { _, request in
                    // Pop-in from the floating window: bring the app to the
                    // video source; YouTubeContentView opens/adopts the
                    // watch view and consumes the request.
                    guard request != nil else { return }
                    self.settings.appSource = .video
                    self.showMainWindow()
                }
                .task {
                    NowPlayingManager.shared.configureYouTubeRouting(
                        youtubePlayerService: self.youtubePlayerService,
                        arbiter: self.playbackArbiter
                    )
                }
                .onChange(of: self.playerService.isMiniPlayerVisible) { _, isVisible in
                    self.handleMiniPlayerVisibilityChange(isVisible)
                }
                .onChange(of: self.playerService.miniPlayerPanel) { _, _ in
                    MiniPlayerWindowController.shared.syncWindowState()
                }
                .onChange(of: self.settings.keepMiniPlayerOnTop) { _, _ in
                    MiniPlayerWindowController.shared.syncWindowState()
                }
            }
        }
        .defaultSize(width: MainWindowLayout.defaultWidth, height: MainWindowLayout.defaultHeight)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(\.locale, self.settings.contentLanguage.locale)
                .environment(self.authService)
                .environment(self.accountService)
                .environment(self.updaterService)
                .environment(self.scrobblingCoordinator)
                .environment(self.equalizerService)
        }
        .commands {
            // Check for Updates command in app menu
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    self.updaterService.checkForUpdates()
                }
                .disabled(!self.updaterService.canCheckForUpdates)
            }

            // Playback commands — routed to whichever player is active
            // (the YouTube video player when it played last, music otherwise).
            CommandMenu("Playback") {
                // Play/Pause - Space
                Button(self.activePlayerIsPlaying ? "Pause" : "Play") {
                    if self.playbackArbiter.routesMediaKeysToVideo {
                        self.youtubePlayerService.playPause()
                    } else {
                        Task {
                            await self.playerService.playPause()
                        }
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(
                    !self.playbackArbiter.routesMediaKeysToVideo
                        && self.playerService.currentTrack == nil
                        && self.playerService.pendingPlayVideoId == nil
                )

                Divider()

                // Next Track - ⌘→
                Button("Next") {
                    if self.playbackArbiter.routesMediaKeysToVideo {
                        Task {
                            await self.youtubePlayerService.skipForward()
                        }
                    } else {
                        Task {
                            await self.playerService.next()
                        }
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!self.playbackArbiter.routesMediaKeysToVideo && self.playerService.currentEpisode != nil)

                // Previous Track - ⌘←
                Button("Previous") {
                    if self.playbackArbiter.routesMediaKeysToVideo {
                        self.youtubePlayerService.skipBackward()
                    } else {
                        Task {
                            await self.playerService.previous()
                        }
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!self.playbackArbiter.routesMediaKeysToVideo && self.playerService.currentEpisode != nil)

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

                // Mute
                Button(self.playerService.isMuted ? "Unmute" : "Mute") {
                    Task {
                        await self.playerService.toggleMute()
                    }
                }

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
            // Each routes to the active source's equivalent destination.
            CommandGroup(replacing: .sidebar) {
                // Home - ⌘1
                Button("Home") {
                    if self.settings.appSource == .video {
                        self.youtubeNavigationSelection = .home
                    } else {
                        self.navigationSelection = .home
                    }
                }
                .keyboardShortcut("1", modifiers: .command)

                // Explore - ⌘2
                Button("Explore") {
                    if self.settings.appSource == .video {
                        self.youtubeNavigationSelection = .explore
                    } else {
                        self.navigationSelection = .explore
                    }
                }
                .keyboardShortcut("2", modifiers: .command)

                // Library - ⌘3
                Button("Library") {
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
                Button("Search") {
                    if self.settings.appSource == .video {
                        self.youtubeNavigationSelection = .search
                        return
                    }
                    self.navigationSelection = .search
                    // Trigger focus after a brief delay to allow view to appear
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        self.searchFocusTrigger = true
                    }
                }
                .keyboardShortcut("f", modifiers: .command)

                // Command Bar - ⌘K
                if PlatformCapabilities.supportsCommandBar(usesLegacyMacOS15UI: self.settings.useLegacyMacOS15UI) {
                    Button("Command Bar") {
                        self.showCommandBar = true
                    }
                    .keyboardShortcut("k", modifiers: .command)
                }
            }

            // Window menu - show main window
            CommandGroup(after: .windowArrangement) {
                Button("Switch to Mini Player") {
                    if self.playerService.isMiniPlayerVisible,
                       self.playerService.miniPlayerMode == .switchFromMainWindow
                    {
                        _ = self.playerService.closeMiniPlayer()
                    } else {
                        self.playerService.openMiniPlayer(mode: .switchFromMainWindow)
                    }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Button("Kaset") {
                    self.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            // Help menu - What's New
            CommandGroup(after: .appInfo) {
                Divider()
                Button("What's New in Kaset") {
                    self.showWhatsNew = true
                }
            }
        }
    }

    private func handleYouTubeSurfaceLocationChange(_ location: YouTubePlayerService.SurfaceLocation) {
        // The floating window hosts the video surface whenever it is popped out
        // (or the inline watch view went away).
        if location == .floating {
            YouTubeVideoWindowController.shared.show(youtubePlayerService: self.youtubePlayerService, authService: self.authService)
        } else {
            YouTubeVideoWindowController.shared.close()
        }
    }

    private func handleMiniPlayerVisibilityChange(_ isVisible: Bool) {
        if isVisible {
            MiniPlayerWindowController.shared.show(
                playerService: self.playerService,
                client: self.sharedClient,
                syncedLyricsService: self.syncedLyricsService,
                authService: self.authService
            )
            if self.playerService.miniPlayerMode == .switchFromMainWindow {
                Task { @MainActor in
                    // Let the AppKit mini-player window order front before hiding
                    // the main SwiftUI scene. Otherwise AppKit can see a transient
                    // no-visible-window state and terminate the app.
                    try? await Task.sleep(for: .milliseconds(100))
                    guard self.playerService.isMiniPlayerVisible,
                          self.playerService.miniPlayerMode == .switchFromMainWindow
                    else { return }
                    self.hideMainWindow()
                }
            }
        } else {
            MiniPlayerWindowController.shared.close()
            if self.playerService.consumeMiniPlayerMainWindowRestoreRequest() {
                self.showMainWindow()
            }
        }
    }

    /// Shows the main window.
    private func showMainWindow() {
        guard !self.focusExistingMainWindow() else { return }

        self.openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            _ = self.focusExistingMainWindow()
        }
    }

    @discardableResult
    private func focusExistingMainWindow() -> Bool {
        // Find and show the main window
        for window in NSApplication.shared.windows where window.frameAutosaveName == MainWindowLayout.autosaveName {
            MainWindowLayout.configure(window)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return true
        }

        for window in NSApplication.shared.windows where window.title == MainWindowLayout.windowTitle && !Self.isAuxiliaryPlayerWindow(window) {
            MainWindowLayout.configure(window)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return true
        }

        // Fallback: find any main-capable window that's not an auxiliary player window.
        // Do not apply the primary-window sizing contract here: a generic fallback
        // may match Settings or another regular scene window.
        for window in NSApplication.shared.windows where window.canBecomeMain {
            if Self.isAuxiliaryPlayerWindow(window) {
                continue
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return true
        }

        return false
    }

    private static func isAuxiliaryPlayerWindow(_ window: NSWindow) -> Bool {
        AccessibilityID.isAuxiliaryPlayerWindowIdentifier(window.identifier?.rawValue)
    }

    /// Hides the main window while keeping playback and auxiliary windows alive.
    private func hideMainWindow() {
        for window in NSApplication.shared.windows where window.frameAutosaveName == MainWindowLayout.autosaveName {
            window.orderOut(nil)
            return
        }

        for window in NSApplication.shared.windows where window.canBecomeMain {
            if Self.isAuxiliaryPlayerWindow(window) {
                continue
            }
            window.orderOut(nil)
            return
        }
    }

    /// Whether the currently routed player (video or music) is playing.
    private var activePlayerIsPlaying: Bool {
        if self.playbackArbiter.routesMediaKeysToVideo {
            self.youtubePlayerService.isPlaying
        } else {
            self.playerService.isPlaying
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

        guard !self.authService.state.isInitializing, self.didCompleteStartupPlaybackCleanup else {
            DiagnosticsLogger.app.info("Startup auth/guest cleanup still running; deferring incoming URL")
            self.pendingIncomingURL = url
            return
        }

        self.handleReadyIncomingURL(url)
    }

    private func drainPendingIncomingURLIfReady() {
        guard !self.authService.state.isInitializing,
              self.didCompleteStartupPlaybackCleanup,
              let url = self.pendingIncomingURL
        else { return }

        self.pendingIncomingURL = nil
        self.handleReadyIncomingURL(url)
    }

    private func handleReadyIncomingURL(_ url: URL) {
        guard let content = URLHandler.parse(url) else {
            DiagnosticsLogger.app.warning("Unrecognized URL format: \(url.absoluteString)")
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

        case let .youtubeVideo(videoId):
            DiagnosticsLogger.app.info("Playing YouTube video from URL")
            // Switch to the video experience and play in the floating
            // window (no inline watch view is open yet).
            self.settings.appSource = .video
            self.youtubePlayerService.play(
                video: YouTubeVideo(videoId: videoId, title: String(localized: "YouTube video")),
                usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore
            )
            self.youtubePlayerService.popOutToWindow()

        case .playlist, .album, .artist:
            // Only song playback is supported via URL scheme
            DiagnosticsLogger.app.info("URL scheme only supports song playback")
        }
    }
}

// MARK: - SettingsView

/// Main settings view with tabbed navigation.
struct SettingsView: View {
    @Environment(UpdaterService.self) private var updaterService
    @Environment(ScrobblingCoordinator.self) private var scrobblingCoordinator
    @State private var settings = SettingsManager.shared

    var body: some View {
        TabView {
            GeneralSettingsView(updaterService: self.updaterService)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            MusicSettingsView()
                .tabItem {
                    Label("Music", systemImage: "music.note")
                }

            YouTubeSettingsView()
                .tabItem {
                    Label("YouTube", systemImage: "play.rectangle.fill")
                }

            EqualizerSettingsView()
                .tabItem {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                }

            ScrobblingSettingsView()
                .environment(self.scrobblingCoordinator)
                .tabItem {
                    Label("Scrobbling", systemImage: "music.note.list")
                }

            // Conditionally rendered (Apple Intelligence is macOS 26+ and
            // hidden in legacy UI mode). Placed near the end so that when it is
            // absent, only the trailing Extensions tab shifts — the stable core
            // tabs (General…Scrobbling) keep their positions.
            if !self.settings.useLegacyMacOS15UI, #available(macOS 26.0, *) {
                IntelligenceSettingsView()
                    .tabItem {
                        Label("Intelligence", systemImage: "sparkles")
                    }
            }

            ExtensionsSettingsView()
                .tabItem {
                    Label("Extensions", systemImage: "puzzlepiece.extension")
                }
        }
        // 520×520 fits the Equalizer tab's six-band slider grid + curve
        // preview; the other tabs grow comfortably into the extra space.
        .frame(width: 520, height: 520)
    }
}
