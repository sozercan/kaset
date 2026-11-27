// swiftlint:disable file_length
import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var searchFocusTrigger: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    @Entry var sidebarNavigationReselectGenerations: Binding<[NavigationItem: Int]> = .constant([:])
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

extension EnvironmentValues {
    @Entry var libraryViewModel: LibraryViewModel?
}

extension EnvironmentValues {
    @Entry var onPlaylistDeleted: (() -> Void)?
}

@main
struct KasetApp: App {
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
    @State private var nowPlayingTracklistProvider: NowPlayingTracklistProvider
    @State private var syncedLyricsService: SyncedLyricsService
    @State private var equalizerService = EqualizerService.shared
    @State private var settings = SettingsManager.shared
    @State private var podcastsAvailabilityService = PodcastsAvailabilityService()

    @State private var searchFocusTrigger = false

    @State private var textInputFocusState = TextInputFocusState()

    @State private var playbackSpaceKeyMonitor = PlaybackSpaceKeyMonitor()

    @State private var sidebarNavigationReselectGenerations: [NavigationItem: Int] = [:]

    @State private var navigationSelection: NavigationItem? = SettingsManager.shared.launchNavigationItem

    @State private var youtubeNavigationSelection: YouTubeNavigationItem? = .home

    @State private var homeRefreshRequestID = 0

    @State private var showCommandBar = false

    @State private var showWhatsNew = false

    @State private var pendingIncomingURLs: [URL] = []

    @State private var didCompleteStartupPlaybackCleanup = false

    init() {
        Bundle.enableAppLocalizationOverride()

        let auth = AuthService()
        let webkit = WebKitManager.shared
        let player = PlayerService()

        let realClient = YTMusicClient(authService: auth, webKitManager: webkit)
        let client: YTMusicClientProtocol = if UITestConfig.isUITestMode {
            MockUITestYTMusicClient()
        } else {
            realClient
        }

        player.setYTMusicClient(client)
        player.setAuthService(auth)
        SongLikeStatusManager.shared.setClient(client)

        PlayerService.shared = player

        AppIntentsBridge.shared.configureForLaunch(playerService: player, client: client, authService: auth)

        let account = AccountService(ytMusicClient: client, authService: auth, webKitManager: webkit)
        let beginAccountBoundary: @MainActor @Sendable () -> Void = {
            LibraryMutationActions.beginAccountBoundary()
        }
        let endAccountBoundary: @MainActor @Sendable () -> Void = {
            LibraryMutationActions.endAccountBoundary()
        }
        let drainAccountBoundary: @MainActor @Sendable () async -> Void = {
            await LibraryMutationActions.awaitAccountBoundaryDrain()
        }
        auth.setAccountBoundaryHandlers(
            willBegin: beginAccountBoundary,
            didEnd: endAccountBoundary,
            drain: drainAccountBoundary
        )
        account.setAccountBoundaryHandlers(
            willBegin: beginAccountBoundary,
            didEnd: endAccountBoundary,
            drain: drainAccountBoundary
        )

        realClient.brandIdProvider = { [weak account] in
            account?.currentBrandId
        }
        realClient.accountScopeProvider = { [weak account] in
            account?.currentAccountScopeID
        }

        let realYouTubeClient = YouTubeClient(authService: auth, webKitManager: webkit, askFeatureEnabled: true)
        realYouTubeClient.brandIdProvider = { [weak account] in
            account?.currentBrandId
        }
        realYouTubeClient.accountCacheIdentityProvider = { [weak account] in
            account?.currentAccount?.cacheIdentity
        }
        realYouTubeClient.askAccountBindingProvider = { [weak account] in
            guard let account,
                  let currentAccount = account.currentAccount,
                  currentAccount.isPrimary,
                  account.verifiedAccountId == currentAccount.id,
                  let scopeID = account.currentAccountScopeID
            else {
                return nil
            }
            return YouTubeAskAccountBinding(scopeID: scopeID)
        }
        let youtubeClient: YouTubeClientProtocol = if UITestConfig.isUITestMode {
            MockUITestYouTubeClient()
        } else {
            realYouTubeClient
        }

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

        let mixTracklistParser = MixTracklistParser(youTubeClient: youtubeClient)
        let tracklistProvider = NowPlayingTracklistProvider(parser: mixTracklistParser)
        player.setNowPlayingTracklistProvider(tracklistProvider)
        _nowPlayingTracklistProvider = State(initialValue: tracklistProvider)

        let lastFMService = LastFMService(credentialStore: KeychainCredentialStore())
        let scrobblingCoordinator = ScrobblingCoordinator(
            playerService: player,
            services: [lastFMService],
            mixTracklistParser: mixTracklistParser
        )
        scrobblingCoordinator.restoreAuthState()
        scrobblingCoordinator.startMonitoring()
        _scrobblingCoordinator = State(initialValue: scrobblingCoordinator)

        self.appDelegate.playerService = player
        self.appDelegate.scrobblingCoordinator = scrobblingCoordinator

        if UITestConfig.isUITestMode {
            DiagnosticsLogger.ui.info("App launched in UI Test mode")
        }
    }

    var body: some Scene {
        Window("Kaset", id: MainWindowLayout.sceneIdentifier) {
            if UITestConfig.isRunningUnitTests, !UITestConfig.isUITestMode {
                Color.clear
                    .frame(width: 1, height: 1)
            } else {
                let startupState = self.authService.startupState
                MainWindow(
                    navigationSelection: self.$navigationSelection,
                    youtubeNavigationSelection: self.$youtubeNavigationSelection,
                    homeRefreshRequestID: self.$homeRefreshRequestID,
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
                .environment(self.nowPlayingTracklistProvider)
                .environment(self.syncedLyricsService)
                .environment(self.equalizerService)
                .environment(self.podcastsAvailabilityService)
                .environment(\.searchFocusTrigger, self.$searchFocusTrigger)
                .environment(\.sidebarNavigationReselectGenerations, self.$sidebarNavigationReselectGenerations)
                .environment(\.navigationSelection, self.$navigationSelection)
                .environment(\.showCommandBar, self.$showCommandBar)
                .environment(\.showWhatsNew, self.$showWhatsNew)
                .environment(\.usesLegacyMacOS15UI, self.settings.useLegacyMacOS15UI)
                .background {
                    MainWindowRegistrationView(
                        register: { [weak appDelegate = self.appDelegate] window in
                            appDelegate?.registerMainWindow(window)
                        },
                        unregister: { [weak appDelegate = self.appDelegate] window in
                            appDelegate?.unregisterMainWindow(window)
                        }
                    )
                }
                .onAppear {
                    DiagnosticsLogger.app.info("KasetApp: App content appeared")
                    self.textInputFocusState.startMonitoring()
                    self.playbackSpaceKeyMonitor.start(
                        isPlaybackCommandEnabled: { !self.shouldDisablePlaybackCommand },
                        onPlayPause: { self.performPlayPause() }
                    )
                    self.appDelegate.playerService = self.playerService
                    self.appDelegate.beginOpenURLDelivery()
                    AppIntentsBridge.shared.setShowMainWindowHandler { self.showMainWindow() }
                    _ = self.notificationService
                }
                .onReceive(NotificationCenter.default.publisher(for: .kasetOpenURLs)) { notification in
                    guard let urls = notification.object as? [URL] else { return }
                    for url in urls {
                        self.handleIncomingURL(url)
                    }
                }
                .task(id: startupState) {
                    guard let startupState else { return }
                    DiagnosticsLogger.app.info("KasetApp: Root task started")
                    let signOutSequence = self.authService.signOutSequence
                    guard await self.authService.checkLoginStatusForStartup(
                        expectedState: startupState
                    ), !Task.isCancelled,
                    self.authService.startupState == startupState,
                    self.authService.signOutSequence == signOutSequence
                    else { return }
                    DiagnosticsLogger.app.info("KasetApp: Login status check complete")
                    if !self.didCompleteStartupPlaybackCleanup {
                        if self.authService.signOutSequence > 0 {
                            self.playerService.clearPlaybackForSignOut()
                            self.youtubePlayerService.stop()
                        } else if self.authService.state.isLoggedIn {
                            self.playerService.clearGuestPlaybackForAuthenticatedStartup()
                        } else {
                            self.playerService.clearPlaybackForGuestStartup()
                            self.youtubePlayerService.stop()
                        }
                        self.didCompleteStartupPlaybackCleanup = true
                        AppIntentsBridge.shared.markStartupComplete()
                    }
                    self.drainPendingIncomingURLsIfReady()

                    self.accountService?.authenticationIdentityDidChange()
                    await self.accountService?.fetchAccounts()

                    if !self.settings.useLegacyMacOS15UI, #available(macOS 26.0, *),
                       !FoundationModelsService.shared.isWarmedUp
                    {
                        await FoundationModelsService.shared.warmup()
                    }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onChange(of: self.playerService.isPlaying) { _, isPlaying in
                    if isPlaying {
                        self.equalizerService.retryStartIfEnabled()
                        self.playbackArbiter.musicDidStartPlaying()
                    }
                }
                .onChange(of: self.youtubePlayerService.surfaceLocation) { _, location in
                    self.handleYouTubeSurfaceLocationChange(location)
                }
                .onChange(of: self.youtubePlayerService.popInRequest) { _, request in
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
                .onChange(of: self.settings.keepYouTubeVideoOnTop) { _, _ in
                    YouTubeVideoWindowController.shared.syncWindowState()
                }
            }
        }
        .defaultSize(width: MainWindowLayout.defaultWidth, height: MainWindowLayout.defaultHeight)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: ["*"])

        Settings {
            SettingsView()
                .id(self.settings.contentLanguage)
                .environment(\.locale, self.settings.contentLanguage.locale)
                .environment(self.authService)
                .environment(self.accountService)
                .environment(self.updaterService)
                .environment(self.scrobblingCoordinator)
                .environment(self.equalizerService)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(String(localized: "Check for Updates...")) {
                    self.updaterService.checkForUpdates()
                }
                .disabled(!self.updaterService.canCheckForUpdates)
            }

            CommandMenu("Playback") {
                Button(self.activePlayerIsPlaying ? "Pause" : "Play") {
                    self.performPlayPause()
                }
                .keyboardShortcut(self.playbackShortcut(.space, modifiers: []))
                .disabled(self.shouldDisablePlaybackCommand)

                Divider()

                Button(String(localized: "Next")) {
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
                .keyboardShortcut(self.playbackShortcut(.rightArrow, modifiers: .command))
                .disabled(self.shouldDisableTrackNavigationCommands)

                Button(String(localized: "Previous")) {
                    if self.playbackArbiter.routesMediaKeysToVideo {
                        self.youtubePlayerService.skipBackward()
                    } else {
                        Task {
                            await self.playerService.previous()
                        }
                    }
                }
                .keyboardShortcut(self.playbackShortcut(.leftArrow, modifiers: .command))
                .disabled(self.shouldDisableTrackNavigationCommands)

                Divider()

                Button(String(localized: "Volume Up")) {
                    Task {
                        await self.playerService.setVolume(min(1.0, self.playerService.volume + 0.1))
                    }
                }
                .keyboardShortcut(self.playbackShortcut(.upArrow, modifiers: .command))

                Button(String(localized: "Volume Down")) {
                    Task {
                        await self.playerService.setVolume(max(0.0, self.playerService.volume - 0.1))
                    }
                }
                .keyboardShortcut(self.playbackShortcut(.downArrow, modifiers: .command))

                Button(self.playerService.isMuted ? "Unmute" : "Mute") {
                    Task {
                        await self.playerService.toggleMute()
                    }
                }

                Divider()

                Button(self.playerService.shuffleEnabled ? "Shuffle Off" : "Shuffle On") {
                    self.playerService.toggleShuffle()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button(self.repeatModeLabel) {
                    self.playerService.cycleRepeatMode()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button(self.playerService.showLyrics ? "Hide Lyrics" : "Show Lyrics") {
                    guard self.settings.appSource == .music else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.playerService.showLyrics.toggle()
                    }
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(self.settings.appSource != .music)
            }

            CommandGroup(replacing: .sidebar) {
                Button(String(localized: "Refresh")) {
                    self.homeRefreshRequestID += 1
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!self.canRefreshHome)

                Divider()

                Button(String(localized: "Home")) {
                    if self.settings.appSource == .video {
                        self.youtubeNavigationSelection = .home
                    } else {
                        self.navigationSelection = .home
                    }
                }
                .keyboardShortcut("1", modifiers: .command)

                Button(String(localized: "Explore")) {
                    if self.settings.appSource == .video {
                        self.youtubeNavigationSelection = .explore
                    } else {
                        self.navigationSelection = .explore
                    }
                }
                .keyboardShortcut("2", modifiers: .command)

                Button(String(localized: "Library")) {
                    if self.settings.appSource == .video {
                        self.youtubeNavigationSelection = .playlists
                    } else {
                        self.navigationSelection = .library
                    }
                }
                .keyboardShortcut("3", modifiers: .command)

                Divider()

                Button(self.settings.appSource == .music ? "Switch to YouTube" : "Switch to Music") {
                    if self.settings.appSource == .video {
                        self.youtubePlayerService.prepareForSourceSwitch()
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.settings.appSource = self.settings.appSource == .music ? .video : .music
                    }
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])

                Divider()

                Button(String(localized: "Search")) {
                    if self.settings.appSource == .video {
                        self.youtubeNavigationSelection = .search
                        return
                    }
                    self.activateMusicSearch()
                }
                .keyboardShortcut("f", modifiers: .command)

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

            CommandGroup(after: .windowArrangement) {
                Button(String(localized: "Switch to Mini Player")) {
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

                Button(String(localized: "Kaset")) {
                    self.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Divider()
                Button(String(localized: "What's New in Kaset")) {
                    self.showWhatsNew = true
                }
            }
        }
    }

    private func handleYouTubeSurfaceLocationChange(_ location: YouTubePlayerService.SurfaceLocation) {
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

    private func showMainWindow() {
        guard !self.focusExistingMainWindow() else { return }

        self.openWindow(id: MainWindowLayout.sceneIdentifier)
        NSApplication.shared.activate(ignoringOtherApps: true)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            _ = self.focusExistingMainWindow()
        }
    }

    @discardableResult
    private func focusExistingMainWindow() -> Bool {
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

    private func performPlayPause() {
        if self.playbackArbiter.routesMediaKeysToVideo {
            self.youtubePlayerService.playPause()
        } else {
            Task {
                await self.playerService.playPause()
            }
        }
    }

    private var activePlayerIsPlaying: Bool {
        if self.playbackArbiter.routesMediaKeysToVideo {
            self.youtubePlayerService.isPlaying
        } else {
            self.playerService.isPlaying
        }
    }

    private func playbackShortcut(_ key: KeyEquivalent, modifiers: EventModifiers) -> KeyboardShortcut? {
        guard !self.textInputFocusState.isFocused else { return nil }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    private var shouldDisablePlaybackCommand: Bool {
        !self.playbackArbiter.routesMediaKeysToVideo
            && self.playerService.currentTrack == nil
            && self.playerService.pendingPlayVideoId == nil
    }

    private var shouldDisableTrackNavigationCommands: Bool {
        !self.playbackArbiter.routesMediaKeysToVideo && self.playerService.currentEpisode != nil
    }

    private var canRefreshHome: Bool {
        switch self.settings.appSource {
        case .music:
            self.navigationSelection == .home
        case .video:
            self.youtubeNavigationSelection == .home
        }
    }

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

    private func handleIncomingURL(_ url: URL) {
        DiagnosticsLogger.app.info("Received URL: \(url.absoluteString)")

        guard !self.authService.state.isInitializing, self.didCompleteStartupPlaybackCleanup else {
            DiagnosticsLogger.app.info("Startup auth/guest cleanup still running; deferring incoming URL")
            self.pendingIncomingURLs.append(url)
            return
        }

        self.handleReadyIncomingURL(url)
    }

    private func drainPendingIncomingURLsIfReady() {
        guard !self.authService.state.isInitializing,
              self.didCompleteStartupPlaybackCleanup,
              !self.pendingIncomingURLs.isEmpty
        else { return }

        let urls = self.pendingIncomingURLs
        self.pendingIncomingURLs.removeAll()
        for url in urls {
            self.handleReadyIncomingURL(url)
        }
    }

    private func handleReadyIncomingURL(_ url: URL) {
        guard let content = URLHandler.parse(url) else {
            DiagnosticsLogger.app.warning("Unrecognized URL format: \(url.absoluteString)")
            return
        }

        self.handleParsedContent(content)
    }

    private func handleParsedContent(_ content: URLHandler.ParsedContent) {
        self.showMainWindow()

        switch content {
        case let .song(videoId):
            DiagnosticsLogger.app.info("Playing song from URL: \(videoId)")
            let song = Song.placeholder(videoId: videoId)
            let intent = self.playerService.beginMusicPlaybackIntent()
            Task {
                await self.playerService.playWithRadio(song: song, intent: intent)
            }

        case let .youtubeVideo(videoId):
            DiagnosticsLogger.app.info("Playing YouTube video from URL")
            self.settings.appSource = .video
            self.youtubePlayerService.play(
                video: YouTubeVideo(videoId: videoId, title: String(localized: "YouTube video")),
                usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore
            )
            self.youtubePlayerService.popOutToWindow()

        case .playlist, .album, .artist:
            DiagnosticsLogger.app.info("URL scheme only supports song playback")
        }
    }
}

struct SettingsView: View {
    @Environment(UpdaterService.self) private var updaterService
    @Environment(ScrobblingCoordinator.self) private var scrobblingCoordinator
    @State private var settings = SettingsManager.shared

    var body: some View {
        TabView {
            GeneralSettingsView(updaterService: self.updaterService)
                .tabItem {
                    Label(String(localized: "General"), systemImage: "gearshape")
                }

            MusicSettingsView()
                .tabItem {
                    Label(String(localized: "Music"), systemImage: "music.note")
                }

            YouTubeSettingsView()
                .tabItem {
                    Label(String(localized: "YouTube"), systemImage: "play.rectangle.fill")
                }

            EqualizerSettingsView()
                .tabItem {
                    Label(String(localized: "Equalizer"), systemImage: "slider.vertical.3")
                }

            ScrobblingSettingsView()
                .environment(self.scrobblingCoordinator)
                .tabItem {
                    Label(String(localized: "Scrobbling"), systemImage: "music.note.list")
                }

            if !self.settings.useLegacyMacOS15UI, #available(macOS 26.0, *) {
                IntelligenceSettingsView()
                    .tabItem {
                        Label(String(localized: "Intelligence"), systemImage: "sparkles")
                    }
            }

            ExtensionsSettingsView()
                .tabItem {
                    Label(String(localized: "Extensions"), systemImage: "puzzlepiece.extension")
                }
        }
        .frame(width: 520, height: 520)
    }
}
