// swiftlint:disable file_length

import SwiftUI

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
        showVideo: Bool,
        includesMusic: Bool = true
    ) -> Bool {
        includesMusic && !showVideo && (isLoggedIn || (!isPendingRestoredLoadDeferred && pendingVideoId != nil))
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

    @Binding var navigationSelection: NavigationItem?

    @Binding var youtubeNavigationSelection: YouTubeNavigationItem?

    @Binding var homeRefreshRequestID: Int

    @Binding var didCompleteStartupPlaybackCleanup: Bool

    let client: any YTMusicClientProtocol

    let youtubeClient: any YouTubeClientProtocol

    @State private var settings = SettingsManager.shared

    @State private var youtubeStore: YouTubeViewModelStore

    @State private var showLoginSheet = false
    @State private var isCommandBarPresented = false
    @State private var whatsNewToPresent: PresentedWhatsNew?
    @State private var selectedSidebarPinnedItem: SidebarPinnedItem?
    @State private var contentResetID = UUID()
    @State private var guestRefreshTask: Task<Void, Never>?
    @State private var accountResolutionFailOpenGeneration: UInt64?
    @State private var hasRenderedAuthenticatedContent = false

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

    @State private var likedMusicNavigationPath = NavigationPath()

    @State private var pinnedNavigationPaths: [String: NavigationPath] = [:]

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

    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    var body: some View {
        self.accountLifecycleContent
            .task {
                NowPlayingManager.shared.configure(playerService: self.playerService)
            }
            .task(id: self.accountService.currentAccount?.id) {
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
                guard self.podcastsProbeTaskID != nil else { return }
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
                    if let currentVideoId = self.playerService.currentTrack?.videoId,
                       event.videoId == currentVideoId
                    {
                        self.playerService.currentTrackLikeStatus = event.status
                    }

                    if self.navigationSelection != .likedMusic {
                        self.likedMusicViewModel?.handleLikeStatusChange(event)
                    }
                }
            }
            .onChange(of: self.appIntentsLibrary, initial: true) { _, library in
                guard let library else { return }
                AppIntentsBridge.shared.updateLibrary(library)
            }
            .onChange(of: self.libraryViewModel?.currentAccountScopeGeneration) { oldGeneration, _ in
                guard oldGeneration != nil else { return }
                AppIntentsBridge.shared.updateLibrary(.empty)
            }
    }

    private var appIntentsLibrary: AppIntentsLibrary? {
        guard !self.authService.state.isInitializing else { return nil }
        guard self.settings.appExperience.includesMusic, self.authService.hasPersonalAccount else { return .empty }
        guard let libraryViewModel = self.libraryViewModel, libraryViewModel.loadingState == .loaded else {
            return nil
        }
        return AppIntentsLibrary(playlists: libraryViewModel.playlists, albums: libraryViewModel.albums)
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
                    self.initializingView
                } else if self.authService.hasPersonalAccount {
                    if self.canRenderAuthenticatedContent {
                        self.mainContent
                            .onAppear { self.hasRenderedAuthenticatedContent = true }
                    } else {
                        self.initializingView
                    }
                } else if self.didCompleteStartupPlaybackCleanup {
                    self.mainContent
                } else {
                    self.initializingView
                }
            }
            .onAppear {
                DiagnosticsLogger.app.info("MainWindow: UI appeared")
            }

            if !self.authService.isCookieRestoreUnavailable,
               !self.playerService.shouldHostPlaybackInMiniPlayer,
               Self.shouldMountPersistentPlayer(
                   isLoggedIn: self.authService.state.isLoggedIn,
                   pendingVideoId: self.playerService.pendingPlayVideoId,
                   isPendingRestoredLoadDeferred: self.playerService.isPendingRestoredLoadDeferred,
                   showVideo: self.playerService.showVideo,
                   includesMusic: self.settings.appExperience.includesMusic
               )
            {
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
            if self.supportsCommandBarUI, self.isCommandBarPresented {
                ZStack {
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
            AccountErrorToast()
                .padding(.top, 60)
        }
        .frame(minWidth: MainWindowLayout.minimumWidth, minHeight: MainWindowLayout.minimumHeight)
    }

    private var podcastsProbeTaskID: PodcastsProbeTaskID? {
        guard self.settings.appExperience.includesMusic,
              self.authService.hasPersonalAccount,
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
                if self.settings.appExperience.includesMusic {
                    self.playerService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: true)
                }
                if self.settings.appExperience.includesVideo {
                    self.youtubePlayerService.reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: true)
                }
            }
            .onChange(of: self.settings.appExperience) { oldExperience, newExperience in
                guard !oldExperience.includesMusic, newExperience.includesMusic else { return }
                let expectedScope = self.accountService.currentAccountScopeID
                Task { @MainActor in
                    guard self.settings.appExperience.includesMusic,
                          self.authService.hasPersonalAccount,
                          self.accountService.currentAccountScopeID == expectedScope
                    else { return }
                    async let likedMusicLoad: Void? = self.likedMusicViewModel?.ensureLoaded()
                    if let libraryViewModel = self.libraryViewModel,
                       libraryViewModel.loadingState == .idle
                    {
                        await libraryViewModel.load()
                    }
                    _ = await likedMusicLoad
                }
            }
            .onChange(of: self.settings.appSource) { _, source in
                guard source == .video else { return }
                self.playerService.showLyrics = false
                self.playerService.showQueue = false
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
            .onChange(of: self.accountService.currentAccountScopeID) { oldAccountScope, newAccountScope in
                self.handleAccountScopeChange(oldAccountScope: oldAccountScope, newAccountScope: newAccountScope)
            }
            .onChange(of: self.accountService.verifiedIdentitySequence) { _, _ in
                guard let verifiedAccountId = self.accountService.verifiedAccountId else { return }
                let isReverification = self.accountService.currentAccount?.id == verifiedAccountId
                if self.settings.appExperience.includesMusic {
                    self.playerService.reloadCurrentTrackForIdentitySwitch(invalidatesLikeSession: !isReverification)
                }
                if self.settings.appExperience.includesVideo, self.youtubePlayerService.currentVideo != nil {
                    self.youtubePlayerService.reloadCurrentVideoForIdentitySwitch()
                }
            }
            .onChange(of: self.podcastsAvailability.availability) { oldValue, newValue in
                if newValue == .unavailable, self.navigationSelection == .podcasts {
                    self.navigationSelection = .home
                }

                if oldValue == .unavailable, newValue == .available {
                    Task { @MainActor in
                        await self.podcastsViewModel?.refresh()
                    }
                }
            }
    }

    private func handleAccountScopeChange(oldAccountScope: String?, newAccountScope: String?) {
        let currentAccount = self.accountService.currentAccount
        let newAccountId = self.accountService.currentAccount?.id
        let isInitialScopeResolution = oldAccountScope == nil
            && newAccountScope != nil
            && !self.hasRenderedAuthenticatedContent
        if !isInitialScopeResolution {
            self.client.resetSessionStateForAccountSwitch()
            self.youtubeClient.resetSessionStateForAccountSwitch()
            self.likeStatusManager.clearCache()
            LibraryMutationActions.cancelAllPendingLibraryMutations()
        }
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
            if isInitialScopeResolution {
                guard self.settings.appExperience.includesMusic,
                      self.authService.hasPersonalAccount,
                      self.accountService.currentAccountScopeID == newAccountScope
                else { return }

                async let likedMusicLoad: Void? = self.likedMusicViewModel?.ensureLoaded()
                if let libraryViewModel = self.libraryViewModel,
                   libraryViewModel.loadingState == .idle
                {
                    await libraryViewModel.load()
                }
                _ = await likedMusicLoad
                return
            }

            APICache.shared.invalidateAll()
            URLCache.shared.removeAllCachedResponses()

            guard newAccountId != nil else { return }

            self.historyViewModel?.reset()
            self.youtubeStore.resetForAccountChange()

            DiagnosticsLogger.auth.info("Account switched, refreshing content and current track metadata...")

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.refreshAllContent()
                }

                if self.settings.appExperience.includesMusic,
                   let currentVideoId = self.playerService.currentTrack?.videoId
                {
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

            self.rightSidebarOverlay(client: self.client)

            if self.playerService.showFullScreenPlayer, self.settings.appSource == .music {
                FullScreenPlayerView()
                    .ignoresSafeArea()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: self.playerService.showLyrics)
        .animation(.easeInOut(duration: 0.25), value: self.playerService.showQueue)
        .toolbar(self.isShowingFullScreenPlayer ? .hidden : .automatic, for: .windowToolbar)
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

    private var isShowingFullScreenPlayer: Bool {
        self.playerService.showFullScreenPlayer && self.settings.appSource == .music
    }

    private func presentCommandBarIfAvailable() {
        guard self.supportsCommandBarUI else { return }
        self.isCommandBarPresented = true
    }

    private var supportsCommandBarUI: Bool {
        PlatformCapabilities.supportsCommandBar(usesLegacyMacOS15UI: self.usesLegacyMacOS15UI)
            && self.settings.appSource == .music
            && self.hasPersonalAccount
    }

    @ViewBuilder
    private func rightSidebarOverlay(client: any YTMusicClientProtocol) -> some View {
        let showRightSidebar = self.settings.appSource == .music
            && (self.playerService.showLyrics || self.playerService.showQueue)

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
                .padding(.bottom, 76)
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

    @ViewBuilder private var commandBar: some View {
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
                                PlaylistDetailView(playlist: LikedMusicPlaylist.playlist, viewModel: vm)
                                    .environment(\.libraryViewModel, self.libraryViewModel)
                            } else {
                                SimplePlaylistDetailView(playlist: LikedMusicPlaylist.playlist, viewModel: vm)
                                    .environment(\.libraryViewModel, self.libraryViewModel)
                            }
                        }
                        .navigationDestinations(client: self.client)
                    }
                    .playerBarMusicNavigation(path: self.$likedMusicNavigationPath)
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

    private func viewForSidebarPinnedItem(
        _ item: SidebarPinnedItem,
        client: any YTMusicClientProtocol
    ) -> some View {
        let path = Binding(
            get: { self.pinnedNavigationPaths[item.contentId, default: NavigationPath()] },
            set: { self.pinnedNavigationPaths[item.contentId] = $0 }
        )
        return NavigationStack(path: path) {
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
        .playerBarMusicNavigation(path: path)
        .environment(\.libraryViewModel, self.libraryViewModel)
        .environment(\.onPlaylistDeleted) {
            self.selectedSidebarPinnedItem = nil
            self.navigationSelection = .home
        }
    }

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
            break
        case .loggedOut:
            self.hasRenderedAuthenticatedContent = false
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
                self.client.resetSessionStateForAccountSwitch()
                self.youtubeClient.resetSessionStateForAccountSwitch()
                self.rebuildMusicViewModels(accountId: self.accountService.currentAccount?.id)
                self.youtubeStore.resetForAccountChange()
                if self.settings.appExperience.includesMusic {
                    self.playerService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: false)
                }
                if self.settings.appExperience.includesVideo {
                    self.youtubePlayerService.reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: false)
                }
            }
            self.showLoginSheet = false
            if self.whatsNewToPresent == nil {
                Task { @MainActor in
                    await self.presentCurrentWhatsNew()
                }
            }
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
            if self.settings.appExperience.includesMusic {
                self.playerService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: false)
            }
            if self.settings.appExperience.includesVideo {
                self.youtubePlayerService.reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: false)
            }
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
        guard self.settings.appExperience.includesMusic else { return }
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

    private func refreshGuestContent() async {
        if self.settings.appExperience.includesMusic {
            await self.homeViewModel?.refresh()
            await self.exploreViewModel?.refresh()
            await self.chartsViewModel?.refresh()
            await self.moodsAndGenresViewModel?.refresh()
            await self.newReleasesViewModel?.refresh()
            self.podcastsAvailability.activateAccount(nil)
            if self.podcastsAvailability.availability != .unavailable {
                await self.podcastsViewModel?.refresh()
            }
        }
        if self.settings.appExperience.includesVideo {
            await self.youtubeStore.refreshGuestContent()
        }
    }

    private func refreshAllContent() async {
        guard self.settings.appExperience.includesMusic else { return }
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
