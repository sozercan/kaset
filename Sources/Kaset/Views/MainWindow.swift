// swiftlint:disable file_length

import SwiftUI

// MARK: - MainWindow

/// Main application window with sidebar navigation and player bar.
struct MainWindow: View { // swiftlint:disable:this type_body_length
    private static let accountResolutionGateTimeout: Duration = .seconds(2)

    private struct PresentedWhatsNew: Identifiable {
        let whatsNew: WhatsNew
        let requestedVersion: WhatsNew.Version

        var id: String {
            "\(self.requestedVersion.description)::\(self.whatsNew.version.description)"
        }
    }

    private struct PodcastsProbeTaskID: Hashable {
        let authGeneration: UInt64
        let accountID: String
    }

    nonisolated static func shouldMountPersistentPlayer(
        isLoggedIn: Bool,
        pendingVideoId: String?,
        isPendingRestoredLoadDeferred: Bool,
        showVideo: Bool
    ) -> Bool {
        !showVideo && (isLoggedIn || (!isPendingRestoredLoadDeferred && pendingVideoId != nil))
    }

    @Environment(AuthService.self) private var authService
    @Environment(PlayerService.self) private var playerService
    @Environment(YouTubePlayerService.self) private var youtubePlayerService
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(AccountService.self) private var accountService
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(SidebarPinnedItemsManager.self) private var sidebarPinnedItemsManager
    @Environment(PodcastsAvailabilityService.self) private var podcastsAvailability
    @Environment(\.searchFocusTrigger) private var searchFocusTrigger
    @Environment(\.sidebarNavigationReselectGenerations) private var sidebarNavigationReselectGenerations
    @Environment(\.showCommandBar) private var showCommandBar
    @Environment(\.showWhatsNew) private var showWhatsNew
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    /// Binding to navigation selection for keyboard shortcut control from parent.
    @Binding var navigationSelection: NavigationItem?

    /// Binding to the YouTube (video) experience's navigation selection.
    @Binding var youtubeNavigationSelection: YouTubeNavigationItem?

    /// Monotonic request from the View menu to refresh the active Home feed.
    @Binding var homeRefreshRequestID: Int

    /// Whether startup guest playback cleanup has completed.
    @Binding var didCompleteStartupPlaybackCleanup: Bool

    /// Shared API client used by all views and services.
    let client: any YTMusicClientProtocol

    /// Shared YouTube (video) API client.
    let youtubeClient: any YouTubeClientProtocol

    /// App-wide settings; drives the active content source (music vs. video).
    @State private var settings = SettingsManager.shared

    /// View models for the YouTube experience (persist across source toggles).
    @State private var youtubeStore: YouTubeViewModelStore

    @State private var showLoginSheet = false
    @State private var isCommandBarPresented = false
    @State private var whatsNewToPresent: PresentedWhatsNew?
    @State private var selectedSidebarPinnedItem: SidebarPinnedItem?
    @State private var contentResetID = UUID()
    @State private var guestRefreshTask: Task<Void, Never>?
    @State private var accountResolutionFailOpenGeneration: UInt64?

    // MARK: - Cached ViewModels (persist across tab switches)

    @State private var homeViewModel: HomeViewModel?
    @State private var exploreViewModel: ExploreViewModel?
    @State private var searchViewModel: SearchViewModel?
    @State private var chartsViewModel: ChartsViewModel?
    @State private var moodsAndGenresViewModel: MoodsAndGenresViewModel?
    @State private var newReleasesViewModel: NewReleasesViewModel?
    @State private var podcastsViewModel: PodcastsViewModel?
    @State private var likedMusicViewModel: PlaylistDetailViewModel?
    @State private var libraryViewModel: LibraryViewModel?
    @State private var historyViewModel: HistoryViewModel?

    /// Navigation path for the Liked Music route.
    @State private var likedMusicNavigationPath = NavigationPath()

    /// Navigation paths for pinned sidebar playlists/albums keyed by content ID.
    @State private var pinnedNavigationPaths: [String: NavigationPath] = [:]

    /// Column visibility state for NavigationSplitView - persisted to fix restoration from dock.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(
        navigationSelection: Binding<NavigationItem?>,
        youtubeNavigationSelection: Binding<YouTubeNavigationItem?>,
        homeRefreshRequestID: Binding<Int>,
        didCompleteStartupPlaybackCleanup: Binding<Bool>,
        client: any YTMusicClientProtocol,
        youtubeClient: any YouTubeClientProtocol
    ) {
        self._navigationSelection = navigationSelection
        self._youtubeNavigationSelection = youtubeNavigationSelection
        self._homeRefreshRequestID = homeRefreshRequestID
        self._didCompleteStartupPlaybackCleanup = didCompleteStartupPlaybackCleanup
        self.client = client
        self.youtubeClient = youtubeClient
        _youtubeStore = State(initialValue: YouTubeViewModelStore(client: youtubeClient))
        _homeViewModel = State(initialValue: HomeViewModel(client: client))
        _exploreViewModel = State(initialValue: ExploreViewModel(client: client))
        _searchViewModel = State(initialValue: SearchViewModel(client: client))
        _chartsViewModel = State(initialValue: ChartsViewModel(client: client))
        _moodsAndGenresViewModel = State(initialValue: MoodsAndGenresViewModel(client: client))
        _newReleasesViewModel = State(initialValue: NewReleasesViewModel(client: client))
        _podcastsViewModel = State(initialValue: PodcastsViewModel(client: client))
        _likedMusicViewModel = State(
            initialValue: PlaylistDetailViewModel(
                playlist: LikedMusicPlaylist.playlist,
                client: client
            )
        )
        _libraryViewModel = State(initialValue: LibraryViewModel(client: client))
        _historyViewModel = State(initialValue: HistoryViewModel(client: client))
    }

    /// Access to the app delegate for persistent WebView.
    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    var body: some View {
        self.accountLifecycleContent
            .task {
                NowPlayingManager.shared.configure(playerService: self.playerService)
            }
            .task(id: self.accountService.currentAccount?.id) {
                // Keep PodcastsViewModel in sync with the active account so
                // 404 / empty results are recorded against the right account.
                let accountId = self.accountService.currentAccount?.id
                if let accountId {
                    self.podcastsAvailability.activateAccount(accountId)
                }
                self.podcastsViewModel?.configure(
                    availabilityService: self.podcastsAvailability,
                    accountId: accountId
                )
            }
            .task(id: self.podcastsProbeTaskID) {
                // Probe podcasts availability in the background when the
                // initial account resolves for an authenticated session.
                guard self.podcastsProbeTaskID != nil else { return }
                // Brief delay so post-login cookies have a chance to settle
                // into the data store the API client reads from. This does not
                // block content rendering.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await self.podcastsAvailability.probe(
                    for: self.accountService.currentAccount?.id,
                    using: self.client
                )
            }
            .task(id: self.accountResolutionGateTaskID) {
                self.accountResolutionFailOpenGeneration = nil
                guard let authGeneration = self.accountResolutionGateTaskID else { return }

                do {
                    try await Task.sleep(for: Self.accountResolutionGateTimeout)
                } catch {
                    return
                }
                guard self.accountResolutionGateTaskID == authGeneration else { return }
                self.accountResolutionFailOpenGeneration = authGeneration
            }
            .onChange(of: self.likeStatusManager.lastLikeEventBatch) { _, batch in
                guard let batch, batch.accountID == self.likeStatusManager.activeAccountID else { return }
                for event in batch.events {
                    // Global sync 1: keep PlayerService.currentTrackLikeStatus in sync
                    if let currentVideoId = self.playerService.currentTrack?.videoId,
                       event.videoId == currentVideoId
                    {
                        self.playerService.currentTrackLikeStatus = event.status
                    }

                    // Global sync 2: keep Liked Music list in sync when the active
                    // Liked Music detail view is not already forwarding this event.
                    if self.navigationSelection != .likedMusic {
                        self.likedMusicViewModel?.handleLikeStatusChange(event)
                    }
                }
            }
    }

    private var windowChrome: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if self.authService.isCookieRestoreUnavailable {
                    SignInRequiredView(
                        title: String(localized: "Sign-In Temporarily Unavailable"),
                        message: String(localized: "Kaset could not read saved sign-in data. Retry to restore your session.")
                    )
                } else if self.authService.state.isInitializing {
                    // Show loading while checking login status to avoid guest-content flash
                    self.initializingView
                } else if self.authService.hasPersonalAccount {
                    if self.canRenderAuthenticatedContent {
                        self.mainContent
                    } else {
                        // Give the initial account fetch a bounded chance to restore
                        // the selected primary or brand account before requests start.
                        self.initializingView
                    }
                } else if self.didCompleteStartupPlaybackCleanup {
                    // Guest mode: public browsing/search/playback remains available
                    // without login. Personal routes render sign-in prompts below.
                    self.mainContent
                } else {
                    // Hold restored account playback/queue metadata out of the
                    // guest shell until startup cleanup has finished.
                    self.initializingView
                }
            }
            .onAppear {
                DiagnosticsLogger.app.info("MainWindow: UI appeared")
            }

            // Persistent WebView - eager once logged in, and mounted on demand for guest playback.
            // Uses a SINGLETON WebView instance that persists for the app lifetime.
            // Keep it as a hidden 1×1 anchor for audio playback; do not reveal a mini overlay.
            // Keep authenticated Home available while restoration defers watch loading.
            // Let the video window own the visible WebView.
            if !self.authService.isCookieRestoreUnavailable, Self.shouldMountPersistentPlayer(
                isLoggedIn: self.authService.state.isLoggedIn,
                pendingVideoId: self.playerService.pendingPlayVideoId,
                isPendingRestoredLoadDeferred: self.playerService.isPendingRestoredLoadDeferred,
                showVideo: self.playerService.showVideo
            ) {
                PersistentPlayerView(videoId: self.playerService.pendingPlayVideoId, isExpanded: false)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
        .sheet(isPresented: self.$showLoginSheet) {
            LoginSheet()
        }
        .sheet(item: self.$whatsNewToPresent) { presentedWhatsNew in
            WhatsNewView(whatsNew: presentedWhatsNew.whatsNew) {
                self.dismissWhatsNew(presentedWhatsNew)
            }
        }
        .overlay {
            // Command bar overlay - dismisses when clicking outside
            if self.supportsCommandBarUI, self.isCommandBarPresented {
                ZStack {
                    // Background tap area to dismiss
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .accessibilityIdentifier(AccessibilityID.MainWindow.commandBarOverlay)
                        .onTapGesture {
                            self.isCommandBarPresented = false
                        }

                    VStack(spacing: 0) {
                        self.commandBar
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, MainWindowLayout.aiTaskSurfaceTopPadding)
                }
                .animation(.easeInOut(duration: 0.15), value: self.isCommandBarPresented)
            }
        }
        .overlay(alignment: .top) {
            // Error toast for account switching failures
            AccountErrorToast()
                .padding(.top, 60)
        }
        .frame(minWidth: MainWindowLayout.minimumWidth, minHeight: MainWindowLayout.minimumHeight)
    }

    private var podcastsProbeTaskID: PodcastsProbeTaskID? {
        guard self.authService.hasPersonalAccount,
              self.accountService.didCompleteAccountResolution
        else { return nil }
        return PodcastsProbeTaskID(
            authGeneration: self.authService.accountIdentityGeneration,
            accountID: self.accountService.currentAccount?.id ?? "primary"
        )
    }

    private var accountResolutionGateTaskID: UInt64? {
        guard self.authService.hasPersonalAccount,
              !self.accountService.didCompleteAccountResolution
        else { return nil }
        return self.authService.accountIdentityGeneration
    }

    private var canRenderAuthenticatedContent: Bool {
        UITestConfig.isUITestMode
            || self.accountService.didCompleteAccountResolution
            || self.accountResolutionFailOpenGeneration == self.authService.accountIdentityGeneration
    }

    private var appLifecycleContent: some View {
        self.windowChrome
            .onChange(of: self.showCommandBar.wrappedValue) { _, newValue in
                if newValue {
                    self.presentCommandBarIfAvailable()
                    self.showCommandBar.wrappedValue = false
                }
            }
            .onChange(of: self.homeRefreshRequestID) { _, _ in
                Task { await self.refreshActiveHome() }
            }
            .onChange(of: self.usesLegacyMacOS15UI) { _, usesLegacyUI in
                if usesLegacyUI {
                    self.isCommandBarPresented = false
                    self.showCommandBar.wrappedValue = false
                }
            }
            .onChange(of: self.showWhatsNew.wrappedValue) { _, newValue in
                if newValue {
                    // Manual trigger from Help menu — fetch exact-version release notes, bypass version store
                    Task { @MainActor in
                        await self.presentCurrentWhatsNew(respectingPresentedVersions: false)
                    }
                    self.showWhatsNew.wrappedValue = false
                }
            }
            .modifier(PinnedNavigationPathLifecycleModifier(
                navigationSelection: self.$navigationSelection,
                selectedPinnedItem: self.$selectedSidebarPinnedItem,
                navigationPaths: self.$pinnedNavigationPaths,
                committedRemovalGenerations: self.sidebarPinnedItemsManager.committedRemovalGenerations
            ))
            .onChange(of: self.authService.state) { oldState, newState in
                self.handleAuthStateChange(oldState: oldState, newState: newState)
            }
            .onChange(of: self.authService.isGuestModeEnabled) { _, isGuestModeEnabled in
                self.handleGuestModeChange(isGuestModeEnabled: isGuestModeEnabled)
            }
            .onChange(of: self.authService.needsReauth) { _, needsReauth in
                if needsReauth {
                    self.showLoginSheet = true
                }
            }
            .onChange(of: self.authService.loginCleanupRequired) { _, cleanupRequired in
                guard cleanupRequired else { return }
                self.playerService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: true)
                self.youtubePlayerService.reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: true)
            }
            .onChange(of: self.playerService.showVideo) { _, showVideo in
                DiagnosticsLogger.player.debug("showVideo onChange triggered: \(showVideo)")
                if showVideo {
                    VideoWindowController.shared.show(
                        playerService: self.playerService,
                        webKitManager: self.webKitManager,
                        authService: self.authService
                    )
                } else {
                    VideoWindowController.shared.close()
                }
            }
    }

    private var accountLifecycleContent: some View {
        self.appLifecycleContent
            .onChange(of: self.accountService.currentAccountScopeID) { _, newAccountScope in
                self.handleAccountScopeChange(newAccountScope: newAccountScope)
            }
            .onChange(of: self.accountService.verifiedIdentitySequence) { _, _ in
                // Re-point in-flight playback ONLY once the new session identity is
                // verified (DATASYNC_ID confirmed). Driving this off the verified
                // signal — rather than `currentAccount?.id` — avoids reloading the
                // player under an unverified/primary identity on cold-launch brand
                // restore, where `currentAccount` is set before its session pin lands.
                // History is recorded by the playback WebViews' own stats pings, so a
                // track/video still loaded under the previous identity must reload to
                // record to the new account. The shared cookie session covers both.
                guard self.accountService.verifiedAccountId != nil else { return }
                self.playerService.reloadCurrentTrackForIdentitySwitch()
                if self.youtubePlayerService.currentVideo != nil {
                    self.youtubePlayerService.reloadCurrentVideoForIdentitySwitch()
                }
            }
            .onChange(of: self.podcastsAvailability.availability) { oldValue, newValue in
                // If the user is sitting on the Podcasts tab when it flips
                // unavailable, redirect to Home so they don't end up on a
                // sidebar row that no longer exists.
                if newValue == .unavailable, self.navigationSelection == .podcasts {
                    self.navigationSelection = .home
                }

                // Switching back from an unavailable account keeps the
                // Podcasts VM reset/idle until the probe confirms the new
                // account is available. Eagerly refresh then so the tab does
                // not remain on the prior account's loaded-empty state.
                if oldValue == .unavailable, newValue == .available {
                    Task { @MainActor in
                        await self.podcastsViewModel?.refresh()
                    }
                }
            }
    }

    // MARK: - Main Content

    private func handleAccountScopeChange(newAccountScope: String?) {
        let currentAccount = self.accountService.currentAccount
        let newAccountId = self.accountService.currentAccount?.id
        self.client.resetSessionStateForAccountSwitch()
        self.youtubeClient.resetSessionStateForAccountSwitch()
        self.likeStatusManager.clearCache()
        LibraryMutationActions.cancelAllPendingLibraryMutations()
        self.libraryViewModel?.activateAccountScope(
            newAccountScope,
            isPrimary: currentAccount?.isPrimary == true
        )
        self.playerService.resetTrackStatus()
        self.searchViewModel?.clear()
        self.podcastsViewModel?.configure(
            availabilityService: self.podcastsAvailability,
            accountId: newAccountId
        )
        if let newAccountId {
            self.podcastsAvailability.activateAccount(newAccountId)
        }

        Task { @MainActor in
            APICache.shared.invalidateAll()
            URLCache.shared.removeAllCachedResponses()

            guard newAccountId != nil else { return }

            self.historyViewModel?.reset()
            // YouTube surfaces are account-scoped too.
            self.youtubeStore.resetForAccountChange()

            // Brand accounts can have a different region than the
            // primary. Re-probe in the background so the sidebar
            // reflects the new account. The sidebar may briefly show
            // the prior account's tab state until the probe lands.
            DiagnosticsLogger.auth.info("Account switched, refreshing content and current track metadata...")

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.refreshAllContent()
                }

                if let currentVideoId = self.playerService.currentTrack?.videoId {
                    group.addTask {
                        await self.playerService.fetchSongMetadata(videoId: currentVideoId)
                    }
                }
            }
        }
    }

    private func refreshActiveHome() async {
        switch self.settings.appSource {
        case .music:
            guard self.navigationSelection == .home, let homeViewModel else { return }
            await homeViewModel.refresh()
        case .video:
            guard self.youtubeNavigationSelection == .home else { return }
            await self.youtubeStore.home.refresh()
        }
    }

    private var mainContent: some View {
        ZStack(alignment: .trailing) {
            // Main navigation content — sidebar and detail swap with the active source.
            NavigationSplitView(columnVisibility: self.$columnVisibility) {
                if self.settings.appSource == .music {
                    Sidebar(
                        selection: self.$navigationSelection,
                        pinnedSelection: self.$selectedSidebarPinnedItem,
                        client: self.client,
                        onReselectNavigationItem: { item in
                            self.sidebarNavigationReselectGenerations.wrappedValue[item, default: 0] += 1
                            if item == .search {
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(100))
                                    self.searchFocusTrigger.wrappedValue = true
                                }
                            }
                        },
                        onReselectPinnedItem: { item in
                            guard !(self.pinnedNavigationPaths[item.contentId]?.isEmpty ?? true) else { return }
                            self.pinnedNavigationPaths[item.contentId] = NavigationPath()
                        }
                    )
                } else {
                    YouTubeSidebar(
                        selection: self.$youtubeNavigationSelection,
                        onReselect: { _ in
                            self.youtubeStore.navigationPath = NavigationPath()
                        }
                    )
                }
            } detail: {
                if self.settings.appSource == .music {
                    self.detailView(
                        for: self.navigationSelection,
                        pinnedItem: self.selectedSidebarPinnedItem,
                        client: self.client
                    )
                } else {
                    YouTubeContentView(
                        selection: self.youtubeNavigationSelection,
                        store: self.youtubeStore
                    )
                }
            }
            .id(self.contentResetID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                // Ensure the sidebar returns when the app is re-activated from the Dock or app switcher.
                if self.columnVisibility != .all {
                    self.columnVisibility = .all
                }
            }

            // Right sidebar overlay - either lyrics or queue (mutually exclusive)
            self.rightSidebarOverlay(client: self.client)
        }
        .animation(.easeInOut(duration: 0.25), value: self.playerService.showLyrics)
        .animation(.easeInOut(duration: 0.25), value: self.playerService.showQueue)
        .frame(minWidth: MainWindowLayout.minimumWidth, minHeight: MainWindowLayout.minimumHeight)
        .toolbar {
            if self.supportsCommandBarUI {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        self.presentCommandBarIfAvailable()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                    }
                    .keyboardShortcut("k", modifiers: .command)
                    .help(String(localized: "Open Command Bar (⌘K)"))
                    .accessibilityIdentifier(AccessibilityID.MainWindow.aiButton)
                }
            }
        }
    }

    private func presentCommandBarIfAvailable() {
        guard self.supportsCommandBarUI else { return }
        self.isCommandBarPresented = true
    }

    private var supportsCommandBarUI: Bool {
        // The command bar is a music/AI feature; it has no role in the
        // YouTube experience, so the sparkle button hides there.
        PlatformCapabilities.supportsCommandBar(usesLegacyMacOS15UI: self.usesLegacyMacOS15UI)
            && self.settings.appSource == .music
            && self.hasPersonalAccount
    }

    /// Right sidebar overlay showing either lyrics or queue as glass panels (mutually exclusive).
    @ViewBuilder
    private func rightSidebarOverlay(client: any YTMusicClientProtocol) -> some View {
        let showRightSidebar = self.playerService.showLyrics || self.playerService.showQueue

        if showRightSidebar {
            VStack {
                Spacer()

                Group {
                    if self.playerService.showLyrics {
                        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                            LyricsView(client: client)
                        } else {
                            SimpleLyricsView(client: client)
                        }
                    } else if self.playerService.showQueue {
                        if self.playerService.queueDisplayMode == .sidepanel {
                            QueueSidePanelView()
                        } else {
                            QueueView()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 76) // Space for PlayerBar
                .transition(.move(edge: .trailing).combined(with: .opacity))

                Spacer()
            }
            .padding(.trailing, 16)
        }
    }

    private func detailView(
        for item: NavigationItem?,
        pinnedItem: SidebarPinnedItem?,
        client: any YTMusicClientProtocol
    ) -> some View {
        Group {
            if let pinnedItem {
                self.viewForSidebarPinnedItem(pinnedItem, client: client)
            } else if let item {
                self.viewForNavigationItem(item)
            } else {
                Text("Select an item from the sidebar", comment: "Placeholder shown when no sidebar item is selected")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var commandBar: some View {
        if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
            CommandBarView(
                client: self.client,
                playerService: self.playerService,
                isPresented: self.$isCommandBarPresented,
                navigationSelection: self.$navigationSelection,
                searchFocusTrigger: self.searchFocusTrigger,
                sidebarNavigationReselectGenerations: self.sidebarNavigationReselectGenerations,
                searchViewModel: self.searchViewModel
            )
        }
    }

    /// Returns the view for a specific navigation item.
    private func viewForNavigationItem(_ item: NavigationItem) -> some View { // swiftlint:disable:this cyclomatic_complexity
        Group {
            switch item {
            case .home:
                if let vm = homeViewModel {
                    HomeView(viewModel: vm)
                }
            case .explore:
                if let vm = exploreViewModel {
                    ExploreView(viewModel: vm)
                }
            case .search:
                if let vm = searchViewModel {
                    SearchView(viewModel: vm, focusTrigger: self.searchFocusTrigger)
                }
            case .charts:
                if let vm = chartsViewModel {
                    ChartsView(viewModel: vm)
                }
            case .moodsAndGenres:
                if let vm = moodsAndGenresViewModel {
                    MoodsAndGenresView(viewModel: vm)
                }
            case .newReleases:
                if let vm = newReleasesViewModel {
                    NewReleasesView(viewModel: vm)
                }
            case .podcasts:
                if let vm = podcastsViewModel {
                    PodcastsView(viewModel: vm)
                }
            case .likedMusic:
                if self.requiresSignIn(item) {
                    self.signInRequiredView(for: item)
                } else if let vm = likedMusicViewModel {
                    NavigationStack(path: self.$likedMusicNavigationPath) {
                        Group {
                            if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                                PlaylistDetailView(
                                    playlist: LikedMusicPlaylist.playlist,
                                    viewModel: vm,
                                    playerBarNavigationAction: self.likedMusicPlayerBarNavigationAction
                                )
                                .environment(\.libraryViewModel, self.libraryViewModel)
                            } else {
                                SimplePlaylistDetailView(
                                    playlist: LikedMusicPlaylist.playlist,
                                    viewModel: vm,
                                    playerBarNavigationAction: self.likedMusicPlayerBarNavigationAction
                                )
                                .environment(\.libraryViewModel, self.libraryViewModel)
                            }
                        }
                        .navigationDestinations(
                            client: self.client,
                            playerBarNavigationAction: self.likedMusicPlayerBarNavigationAction
                        )
                        .playerBarMusicNavigation(path: self.$likedMusicNavigationPath)
                    }
                    .popsNavigationStackOnSidebarReselect(
                        path: self.$likedMusicNavigationPath,
                        for: .likedMusic
                    )
                }
            case .library:
                if self.requiresSignIn(item) {
                    self.signInRequiredView(for: item)
                } else if let vm = libraryViewModel {
                    LibraryView(viewModel: vm)
                }
            case .history:
                if self.requiresSignIn(item) {
                    self.signInRequiredView(for: item)
                } else if let vm = historyViewModel {
                    HistoryView(viewModel: vm)
                }
            }
        }
        .environment(\.libraryViewModel, self.libraryViewModel)
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private func requiresSignIn(_ item: NavigationItem) -> Bool {
        item.requiresSignIn && !self.hasPersonalAccount
    }

    private func signInRequiredView(for item: NavigationItem) -> some View {
        SignInRequiredView(
            title: String(localized: "Sign in to use \(item.displayName)"),
            message: String(localized: "Kaset works without login for public browsing, search, and playback. Sign in to access personal music collections.")
        )
    }

    private var likedMusicPlayerBarNavigationAction: PlayerBarNavigationAction {
        PlayerBarNavigationAction(
            openArtist: { self.likedMusicNavigationPath.append($0) },
            openAlbum: { self.likedMusicNavigationPath.append($0) }
        )
    }

    private func viewForSidebarPinnedItem(
        _ item: SidebarPinnedItem,
        client: any YTMusicClientProtocol
    ) -> some View {
        NavigationStack(path: Binding(
            get: { self.pinnedNavigationPaths[item.contentId, default: NavigationPath()] },
            set: { self.pinnedNavigationPaths[item.contentId] = $0 }
        )) {
            Group {
                if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                    PlaylistDetailView(
                        playlist: item.playlistRoute,
                        viewModel: PlaylistDetailViewModel(
                            playlist: item.playlistRoute,
                            client: client
                        )
                    )
                    .environment(\.libraryViewModel, self.libraryViewModel)
                } else {
                    SimplePlaylistDetailView(
                        playlist: item.playlistRoute,
                        viewModel: PlaylistDetailViewModel(
                            playlist: item.playlistRoute,
                            client: client
                        )
                    )
                    .environment(\.libraryViewModel, self.libraryViewModel)
                }
            }
            .id(item.contentId)
            .navigationDestinations(client: client)
        }
        .environment(\.libraryViewModel, self.libraryViewModel)
        .environment(\.onPlaylistDeleted) {
            self.selectedSidebarPinnedItem = nil
            self.navigationSelection = .home
        }
    }

    /// View shown while checking initial login status.
    private var initializingView: some View {
        VStack(spacing: 16) {
            CassetteIcon(size: 60)
                .foregroundStyle(.tint)
            ProgressView()
                .controlSize(.regular)
                .frame(width: 20, height: 20)
        }
        .frame(minWidth: MainWindowLayout.minimumWidth, minHeight: MainWindowLayout.minimumHeight)
    }

    private func handleAuthStateChange(oldState: AuthService.State, newState: AuthService.State) {
        self.accountService.authenticationIdentityDidChange()
        switch newState {
        case .initializing:
            // Still checking login status, do nothing
            break
        case .loggedOut:
            let isReauthTransition = self.authService.needsReauth
            let crossedSignOutBoundary = oldState.isLoggedIn && !isReauthTransition
            let shouldRefreshGuestContent = crossedSignOutBoundary || oldState.isInitializing || isReauthTransition
            if crossedSignOutBoundary {
                self.playerService.clearPlaybackForSignOut()
                self.youtubePlayerService.stop()
            }
            if shouldRefreshGuestContent {
                self.client.resetSessionStateForAccountSwitch()
                self.youtubeClient.resetSessionStateForAccountSwitch()
                self.rebuildMusicViewModels()
                self.youtubeStore.resetForAccountChange()
                // Reset podcasts availability so the next sign-in re-probes
                // the endpoint.
                self.podcastsAvailability.reset()
            }
            if !isReauthTransition {
                self.normalizeGuestSelections()
                self.accountService.clearAccounts()
            }
            if shouldRefreshGuestContent {
                self.scheduleGuestContentRefresh()
            }
        case .loggingIn:
            self.showLoginSheet = true
        case .loggedIn:
            self.guestRefreshTask?.cancel()
            self.guestRefreshTask = nil
            let shouldRefreshAuthenticatedContent = oldState == .loggingIn || oldState == .loggedOut
            if shouldRefreshAuthenticatedContent {
                // Replace any mounted guest/expired models so in-flight responses
                // cannot populate the authenticated shell after login or reauth.
                self.client.resetSessionStateForAccountSwitch()
                self.youtubeClient.resetSessionStateForAccountSwitch()
                self.rebuildMusicViewModels(accountId: self.accountService.currentAccount?.id)
                self.youtubeStore.resetForAccountChange()
                self.playerService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: false)
                self.youtubePlayerService.reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: false)
            }
            self.showLoginSheet = false
            // Auto-present "What's New" — fetch from GitHub release notes
            if self.whatsNewToPresent == nil {
                Task { @MainActor in
                    await self.presentCurrentWhatsNew()
                }
            }
            // KasetApp's state-keyed root task owns account loading for every
            // authenticated transition, after startup playback cleanup.
            // If we just completed login/reauth, refresh content. This handles
            // the case where cookies were unavailable during initial load and
            // preserved views that may currently hold auth-expired state.
            if shouldRefreshAuthenticatedContent {
                let authGeneration = self.authService.accountIdentityGeneration
                Task {
                    guard await self.waitForAuthenticatedRefreshReadiness(
                        authGeneration: authGeneration
                    ) else { return }
                    await self.refreshAuthenticatedContent()
                }
            }
        }
    }

    private func waitForAuthenticatedRefreshReadiness(authGeneration: UInt64) async -> Bool {
        let clock = ContinuousClock()
        let accountResolutionDeadline = clock.now + Self.accountResolutionGateTimeout

        do {
            // Keep the existing post-login cookie propagation delay.
            try await Task.sleep(for: .milliseconds(500))
            while !self.accountService.didCompleteAccountResolution,
                  clock.now < accountResolutionDeadline
            {
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            return false
        }

        return !Task.isCancelled
            && self.authService.hasPersonalAccount
            && self.authService.accountIdentityGeneration == authGeneration
    }

    private func handleGuestModeChange(isGuestModeEnabled: Bool) {
        guard self.authService.state.isLoggedIn else { return }
        self.guestRefreshTask?.cancel()
        self.guestRefreshTask = nil
        self.youtubeStore.resetForAccountChange()
        self.podcastsAvailability.reset()

        if isGuestModeEnabled {
            self.client.resetSessionStateForAccountSwitch()
            self.youtubeClient.resetSessionStateForAccountSwitch()
            self.rebuildMusicViewModels()
            self.playerService.clearPlaybackForGuestStartup()
            self.youtubePlayerService.stop()
            self.normalizeGuestSelections()
            self.scheduleGuestContentRefresh()
        } else {
            self.client.resetSessionStateForAccountSwitch()
            self.youtubeClient.resetSessionStateForAccountSwitch()
            self.rebuildMusicViewModels(accountId: self.accountService.currentAccount?.id)
            self.playerService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: false)
            self.youtubePlayerService.reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: false)
            Task { @MainActor in
                await self.accountService.fetchAccounts()
                await self.refreshAuthenticatedContent()
            }
        }
    }

    private func rebuildMusicViewModels(accountId: String? = nil) {
        LibraryMutationActions.cancelAllPendingLibraryMutations()
        self.homeViewModel = HomeViewModel(client: self.client)
        self.exploreViewModel = ExploreViewModel(client: self.client)
        self.searchViewModel = SearchViewModel(client: self.client)
        self.chartsViewModel = ChartsViewModel(client: self.client)
        self.moodsAndGenresViewModel = MoodsAndGenresViewModel(client: self.client)
        self.newReleasesViewModel = NewReleasesViewModel(client: self.client)
        let podcastsViewModel = PodcastsViewModel(client: self.client)
        podcastsViewModel.configure(availabilityService: self.podcastsAvailability, accountId: accountId)
        self.podcastsViewModel = podcastsViewModel
        self.likedMusicViewModel = PlaylistDetailViewModel(
            playlist: LikedMusicPlaylist.playlist,
            client: self.client
        )
        let libraryViewModel = LibraryViewModel(client: self.client)
        let currentAccount = self.accountService.currentAccount
        libraryViewModel.activateAccountScope(
            self.accountService.currentAccountScopeID,
            isPrimary: currentAccount?.isPrimary == true
        )
        self.libraryViewModel = libraryViewModel
        self.historyViewModel = HistoryViewModel(client: self.client)
        self.likedMusicNavigationPath = NavigationPath()
        self.pinnedNavigationPaths = [:]
        self.contentResetID = UUID()
    }

    private func scheduleGuestContentRefresh() {
        self.guestRefreshTask?.cancel()
        self.guestRefreshTask = Task { @MainActor in
            await self.refreshGuestContent()
            if !Task.isCancelled {
                self.guestRefreshTask = nil
            }
        }
    }

    private func normalizeGuestSelections() {
        if self.navigationSelection?.requiresSignIn == true {
            self.navigationSelection = .home
        }
        if self.youtubeNavigationSelection?.requiresSignIn == true {
            self.youtubeNavigationSelection = .home
        }
        self.selectedSidebarPinnedItem = nil
    }

    private func refreshAuthenticatedContent() async {
        // Parallel initial data fetch for ~40% faster app launch. The podcasts
        // probe is driven separately by the account-keyed task.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.homeViewModel?.refresh() }
            group.addTask { await self.exploreViewModel?.refresh() }
            group.addTask { await self.libraryViewModel?.load() }
        }
    }

    @MainActor
    private func dismissWhatsNew(_ whatsNew: PresentedWhatsNew) {
        WhatsNewVersionStore().markPresented(whatsNew.requestedVersion)
        self.whatsNewToPresent = nil
    }

    @MainActor
    private func presentCurrentWhatsNew(respectingPresentedVersions: Bool = true) async {
        let currentVersion = WhatsNew.Version.current()
        let whatsNew = await WhatsNewProvider.fetchWhatsNew(
            for: currentVersion,
            respectingPresentedVersions: respectingPresentedVersions
        )

        guard let whatsNew else { return }

        self.whatsNewToPresent = PresentedWhatsNew(
            whatsNew: whatsNew,
            requestedVersion: currentVersion
        )
    }

    /// Refreshes only public guest-safe surfaces after sign-out so prior
    /// account-personalized content is not left visible in the guest shell.
    private func refreshGuestContent() async {
        // These view models are main-actor-bound observable UI state. Keep the
        // refresh calls on the main actor instead of spawning task-group child
        // tasks that capture `self` and mutate UI state off actor.
        await self.homeViewModel?.refresh()
        await self.exploreViewModel?.refresh()
        await self.chartsViewModel?.refresh()
        await self.moodsAndGenresViewModel?.refresh()
        await self.newReleasesViewModel?.refresh()
        await self.youtubeStore.refreshGuestContent()
        self.podcastsAvailability.activateAccount(nil)
        if self.podcastsAvailability.availability != .unavailable {
            await self.podcastsViewModel?.refresh()
        }
    }

    /// Refreshes all content when switching accounts.
    ///
    /// This method is called when the user switches between their primary account
    /// and brand accounts, ensuring all views display content for the new account.
    private func refreshAllContent() async {
        // Parallel refresh of all content views.
        // The podcasts refresh is gated on the latest availability
        // signal so a brand-account switch into a region without
        // podcasts doesn't fire the spurious 404 the bug is about. The
        // account-keyed task re-evaluates availability separately.
        let podcastsAvailable = self.podcastsAvailability.availability != .unavailable
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.homeViewModel?.refresh() }
            group.addTask { await self.exploreViewModel?.refresh() }
            group.addTask { await self.chartsViewModel?.refresh() }
            group.addTask { await self.moodsAndGenresViewModel?.refresh() }
            group.addTask { await self.newReleasesViewModel?.refresh() }
            if podcastsAvailable {
                group.addTask { await self.podcastsViewModel?.refresh() }
            }
            group.addTask { await self.likedMusicViewModel?.refresh() }
            group.addTask { await self.historyViewModel?.load() }
            group.addTask { await self.libraryViewModel?.refresh() }
        }
    }
}

// MARK: - PinnedNavigationPathLifecycleModifier

private struct PinnedNavigationPathLifecycleModifier: ViewModifier {
    @Binding var navigationSelection: NavigationItem?
    @Binding var selectedPinnedItem: SidebarPinnedItem?
    @Binding var navigationPaths: [String: NavigationPath]
    let committedRemovalGenerations: [String: UInt]

    func body(content: Content) -> some View {
        content
            .onChange(of: self.navigationSelection) { _, newValue in
                if newValue != nil {
                    self.selectedPinnedItem = nil
                }
            }
            .onChange(of: self.selectedPinnedItem?.contentId) { oldContentId, newContentId in
                guard oldContentId != newContentId, let oldContentId else { return }
                self.navigationPaths.removeValue(forKey: oldContentId)
            }
            .onChange(of: self.committedRemovalGenerations) { oldValue, newValue in
                for (contentId, generation) in newValue where oldValue[contentId] != generation {
                    self.navigationPaths.removeValue(forKey: contentId)
                }
            }
    }
}

// MARK: - NavigationItem

enum NavigationItem: String, Hashable, CaseIterable, Identifiable {
    case home = "Home"
    case explore = "Explore"
    case search = "Search"
    case charts = "Charts"
    case moodsAndGenres = "Moods & Genres"
    case newReleases = "New Releases"
    case podcasts = "Podcasts"
    case likedMusic = "Liked Music"
    case library = "Library"
    case history = "History"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .home:
            String(localized: "Home")
        case .explore:
            String(localized: "Explore")
        case .search:
            String(localized: "Search")
        case .charts:
            String(localized: "Charts")
        case .moodsAndGenres:
            String(localized: "Moods & Genres")
        case .newReleases:
            String(localized: "New Releases")
        case .podcasts:
            String(localized: "Podcasts")
        case .likedMusic:
            String(localized: "Liked Music")
        case .library:
            String(localized: "Library")
        case .history:
            String(localized: "History")
        }
    }

    var icon: String {
        switch self {
        case .home:
            "house"
        case .explore:
            "globe"
        case .search:
            "magnifyingglass"
        case .charts:
            "chart.line.uptrend.xyaxis"
        case .moodsAndGenres:
            "theatermask.and.paintbrush"
        case .newReleases:
            "sparkles"
        case .podcasts:
            "mic.fill"
        case .likedMusic:
            "heart.fill"
        case .library:
            "square.stack.fill"
        case .history:
            "clock.arrow.circlepath"
        }
    }

    var requiresSignIn: Bool {
        switch self {
        case .home, .explore, .search, .charts, .moodsAndGenres, .newReleases, .podcasts:
            false
        case .likedMusic, .library, .history:
            true
        }
    }
}

#Preview {
    @Previewable @State var navSelection: NavigationItem? = .home
    @Previewable @State var youtubeNavSelection: YouTubeNavigationItem? = .home
    @Previewable @State var homeRefreshRequestID = 0
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)
    MainWindow(
        navigationSelection: $navSelection,
        youtubeNavigationSelection: $youtubeNavSelection,
        homeRefreshRequestID: $homeRefreshRequestID,
        didCompleteStartupPlaybackCleanup: .constant(true),
        client: ytMusicClient,
        youtubeClient: YouTubeClient(authService: authService)
    )
    .environment(authService)
    .environment(PlayerService())
    .environment(WebKitManager.shared)
    .environment(accountService)
}
