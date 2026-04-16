import SwiftUI

// MARK: - MainWindow

/// Main application window with sidebar navigation and player bar.
@available(macOS 26.0, *)
struct MainWindow: View {
    private struct PresentedWhatsNew: Identifiable {
        let whatsNew: WhatsNew
        let requestedVersion: WhatsNew.Version

        var id: String {
            "\(self.requestedVersion.description)::\(self.whatsNew.version.description)"
        }
    }

    private enum Layout {
        static let commandBarTopPadding: CGFloat = 72
    }

    @Environment(AuthService.self) private var authService
    @Environment(PlayerService.self) private var playerService
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(AccountService.self) private var accountService
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(\.searchFocusTrigger) private var searchFocusTrigger
    @Environment(\.showCommandBar) private var showCommandBar
    @Environment(\.showWhatsNew) private var showWhatsNew

    /// Binding to navigation selection for keyboard shortcut control from parent.
    @Binding var navigationSelection: NavigationItem?

    /// Shared API client used by all views and services.
    let client: any YTMusicClientProtocol

    @State private var showLoginSheet = false
    @State private var isCommandBarPresented = false
    @State private var whatsNewToPresent: PresentedWhatsNew?

    // MARK: - Cached ViewModels (persist across tab switches)

    @State private var homeViewModel: HomeViewModel?
    @State private var exploreViewModel: ExploreViewModel?
    @State private var searchViewModel: SearchViewModel?
    @State private var chartsViewModel: ChartsViewModel?
    @State private var moodsAndGenresViewModel: MoodsAndGenresViewModel?
    @State private var newReleasesViewModel: NewReleasesViewModel?
    @State private var podcastsViewModel: PodcastsViewModel?
    @State private var likedMusicViewModel: LikedMusicViewModel?
    @State private var libraryViewModel: LibraryViewModel?
    @State private var historyViewModel: HistoryViewModel?

    /// Column visibility state for NavigationSplitView - persisted to fix restoration from dock.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(navigationSelection: Binding<NavigationItem?>, client: any YTMusicClientProtocol) {
        self._navigationSelection = navigationSelection
        self.client = client
        _homeViewModel = State(initialValue: HomeViewModel(client: client))
        _exploreViewModel = State(initialValue: ExploreViewModel(client: client))
        _searchViewModel = State(initialValue: SearchViewModel(client: client))
        _chartsViewModel = State(initialValue: ChartsViewModel(client: client))
        _moodsAndGenresViewModel = State(initialValue: MoodsAndGenresViewModel(client: client))
        _newReleasesViewModel = State(initialValue: NewReleasesViewModel(client: client))
        _podcastsViewModel = State(initialValue: PodcastsViewModel(client: client))
        _likedMusicViewModel = State(initialValue: LikedMusicViewModel(client: client))
        _libraryViewModel = State(initialValue: LibraryViewModel(client: client))
        _historyViewModel = State(initialValue: HistoryViewModel(client: client))
    }

    /// Access to the app delegate for persistent WebView.
    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    var body: some View {
        @Bindable var player = self.playerService

        ZStack(alignment: .bottomTrailing) {
            Group {
                if self.authService.state.isInitializing {
                    // Show loading while checking login status to avoid onboarding flash
                    self.initializingView
                } else if self.authService.state.isLoggedIn {
                    self.mainContent
                } else {
                    OnboardingView()
                }
            }
            .onAppear {
                DiagnosticsLogger.app.info("MainWindow: UI appeared")
            }
            .task {
                DiagnosticsLogger.app.info("MainWindow: Starting login check check...")
                await self.authService.checkLoginStatus()
                DiagnosticsLogger.app.info("MainWindow: Login check complete")
            }

            // Persistent WebView - always present once a video has been requested
            // Uses a SINGLETON WebView instance that persists for the app lifetime
            // Compact size (120x68) for first-time interaction, then hidden (1x1)
            if let videoId = playerService.pendingPlayVideoId {
                ZStack(alignment: .topTrailing) {
                    PersistentPlayerView(videoId: videoId, isExpanded: self.playerService.showMiniPlayer)
                        .frame(
                            width: self.playerService.showMiniPlayer ? 120 : 1,
                            height: self.playerService.showMiniPlayer ? 68 : 1
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .opacity(self.playerService.showMiniPlayer ? 0.95 : 0)

                    if self.playerService.showMiniPlayer {
                        Button {
                            self.playerService.confirmPlaybackStarted()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(radius: 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Close"))
                        .padding(3)
                    }
                }
                .shadow(color: self.playerService.showMiniPlayer ? .black.opacity(0.2) : .clear, radius: 6, y: 3)
                .padding(.trailing, self.playerService.showMiniPlayer ? 12 : 0)
                .padding(.bottom, self.playerService.showMiniPlayer ? 76 : 0)
                .allowsHitTesting(self.playerService.showMiniPlayer)
                // Hiding must not interpolate frame/opacity (no “shrink”); showing can ease in.
                .transaction { transaction in
                    if !self.playerService.showMiniPlayer {
                        transaction.animation = nil
                    } else {
                        transaction.animation = .easeInOut(duration: 0.2)
                    }
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
            if self.isCommandBarPresented {
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
                    .padding(.top, Self.Layout.commandBarTopPadding)
                }
                .animation(.easeInOut(duration: 0.15), value: self.isCommandBarPresented)
            }
        }
        .overlay(alignment: .top) {
            // Error toast for account switching failures
            AccountErrorToast()
                .padding(.top, 60)
        }
        .onChange(of: self.showCommandBar.wrappedValue) { _, newValue in
            if newValue {
                self.isCommandBarPresented = true
                self.showCommandBar.wrappedValue = false
            }
        }
        .onChange(of: self.showWhatsNew.wrappedValue) { _, newValue in
            if newValue {
                // Manual trigger from Help menu — fetch release notes, bypass version store
                Task { @MainActor in
                    await self.presentCurrentWhatsNew(
                        respectingPresentedVersions: false,
                        allowsGenericFallback: true
                    )
                }
                self.showWhatsNew.wrappedValue = false
            }
        }
        .onChange(of: self.authService.state) { oldState, newState in
            self.handleAuthStateChange(oldState: oldState, newState: newState)
        }
        .onChange(of: self.authService.needsReauth) { _, needsReauth in
            if needsReauth {
                self.showLoginSheet = true
            }
        }
        .onChange(of: self.playerService.isPlaying) { _, isPlaying in
            // Auto-hide the WebView once playback starts
            if isPlaying, self.playerService.showMiniPlayer {
                self.playerService.confirmPlaybackStarted()
            }
        }
        .onChange(of: self.playerService.showVideo) { _, showVideo in
            DiagnosticsLogger.player.debug("showVideo onChange triggered: \(showVideo)")
            if showVideo {
                VideoWindowController.shared.show(
                    playerService: self.playerService,
                    webKitManager: self.webKitManager
                )
            } else {
                VideoWindowController.shared.close()
            }
        }
        .onChange(of: self.accountService.currentAccount?.id) { _, newAccountId in
            self.playerService.resetTrackStatus()

            Task { @MainActor in
                APICache.shared.invalidateAll()
                URLCache.shared.removeAllCachedResponses()

                guard newAccountId != nil else { return }

                self.historyViewModel?.reset()

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
        .task {
            NowPlayingManager.shared.configure(playerService: self.playerService)
        }
        .onChange(of: self.likeStatusManager.lastLikeEvent) { _, event in
            guard let event else { return }

            // Global sync 1: keep PlayerService.currentTrackLikeStatus in sync
            if let currentVideoId = self.playerService.currentTrack?.videoId,
               event.videoId == currentVideoId
            {
                self.playerService.currentTrackLikeStatus = event.status
            }

            // Global sync 2: keep Liked Music list in sync regardless of which tab is active
            self.likedMusicViewModel?.handleLikeStatusChange(event)
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ZStack(alignment: .trailing) {
            // Main navigation content
            NavigationSplitView(columnVisibility: self.$columnVisibility) {
                Sidebar(selection: self.$navigationSelection)
            } detail: {
                self.detailView(for: self.navigationSelection, client: self.client)
            }
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
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    self.isCommandBarPresented = true
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

    /// Right sidebar overlay showing either lyrics or queue as glass panels (mutually exclusive).
    @ViewBuilder
    private func rightSidebarOverlay(client: any YTMusicClientProtocol) -> some View {
        let showRightSidebar = self.playerService.showLyrics || self.playerService.showQueue

        if showRightSidebar {
            VStack {
                Spacer()

                Group {
                    if self.playerService.showLyrics {
                        LyricsView(client: client)
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

    private func detailView(for item: NavigationItem?, client _: any YTMusicClientProtocol) -> some View {
        Group {
            if let item {
                self.viewForNavigationItem(item)
            } else {
                Text("Select an item from the sidebar", comment: "Placeholder shown when no sidebar item is selected")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commandBar: some View {
        CommandBarView(
            client: self.client,
            playerService: self.playerService,
            isPresented: self.$isCommandBarPresented,
            navigationSelection: self.$navigationSelection,
            searchFocusTrigger: self.searchFocusTrigger,
            searchViewModel: self.searchViewModel
        )
    }

    /// Returns the view for a specific navigation item.
    private func viewForNavigationItem(_ item: NavigationItem) -> some View { // swiftlint:disable:this cyclomatic_complexity
        Group {
            switch item {
            case .home:
                if let vm = homeViewModel { HomeView(viewModel: vm) }
            case .explore:
                if let vm = exploreViewModel { ExploreView(viewModel: vm) }
            case .search:
                if let vm = searchViewModel {
                    SearchView(viewModel: vm, focusTrigger: self.searchFocusTrigger)
                }
            case .charts:
                if let vm = chartsViewModel { ChartsView(viewModel: vm) }
            case .moodsAndGenres:
                if let vm = moodsAndGenresViewModel { MoodsAndGenresView(viewModel: vm) }
            case .newReleases:
                if let vm = newReleasesViewModel { NewReleasesView(viewModel: vm) }
            case .podcasts:
                if let vm = podcastsViewModel { PodcastsView(viewModel: vm) }
            case .likedMusic:
                if let vm = likedMusicViewModel { LikedMusicView(viewModel: vm) }
            case .library:
                if let vm = libraryViewModel { LibraryView(viewModel: vm) }
            case .history:
                if let vm = historyViewModel { HistoryView(viewModel: vm) }
            }
        }
        .environment(self.libraryViewModel)
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
        .frame(minWidth: 900, minHeight: 600)
    }

    private func handleAuthStateChange(oldState: AuthService.State, newState: AuthService.State) {
        switch newState {
        case .initializing:
            // Still checking login status, do nothing
            break
        case .loggedOut:
            // Onboarding view handles login, no need to auto-show sheet
            self.accountService.clearAccounts()
        case .loggingIn:
            self.showLoginSheet = true
        case .loggedIn:
            self.showLoginSheet = false
            // Auto-present "What's New" — fetch from GitHub release notes
            if self.whatsNewToPresent == nil {
                Task { @MainActor in
                    await self.presentCurrentWhatsNew()
                }
            }
            Task {
                await self.accountService.fetchAccounts()
            }
            // If we just completed login (transitioning from loggingIn), refresh content
            // This handles the case where cookies weren't ready during initial load
            if case .loggingIn = oldState {
                Task {
                    // Brief delay to ensure cookies are fully propagated in WebKit
                    try? await Task.sleep(for: .milliseconds(500))

                    // Parallel initial data fetch for ~40% faster app launch
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await self.homeViewModel?.refresh() }
                        group.addTask { await self.exploreViewModel?.refresh() }
                        group.addTask { await self.libraryViewModel?.load() }
                    }
                }
            }
        }
    }

    @MainActor
    private func dismissWhatsNew(_ whatsNew: PresentedWhatsNew) {
        WhatsNewVersionStore().markPresented(whatsNew.requestedVersion)
        self.whatsNewToPresent = nil
    }

    @MainActor
    private func presentCurrentWhatsNew(
        respectingPresentedVersions: Bool = true,
        allowsGenericFallback: Bool = false
    ) async {
        let currentVersion = WhatsNew.Version.current()
        let whatsNew = await WhatsNewProvider.fetchWhatsNew(
            for: currentVersion,
            respectingPresentedVersions: respectingPresentedVersions
        ) ?? (allowsGenericFallback ? WhatsNewProvider.fallbackCollection.first : nil)

        guard let whatsNew else { return }

        self.whatsNewToPresent = PresentedWhatsNew(
            whatsNew: whatsNew,
            requestedVersion: currentVersion
        )
    }

    /// Refreshes all content when switching accounts.
    ///
    /// This method is called when the user switches between their primary account
    /// and brand accounts, ensuring all views display content for the new account.
    private func refreshAllContent() async {
        // Parallel refresh of all content views
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.homeViewModel?.refresh() }
            group.addTask { await self.exploreViewModel?.refresh() }
            group.addTask { await self.chartsViewModel?.refresh() }
            group.addTask { await self.moodsAndGenresViewModel?.refresh() }
            group.addTask { await self.newReleasesViewModel?.refresh() }
            group.addTask { await self.podcastsViewModel?.refresh() }
            group.addTask { await self.likedMusicViewModel?.refresh() }
            group.addTask { await self.historyViewModel?.load() }
            group.addTask { await self.libraryViewModel?.refresh() }
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
}

@available(macOS 26.0, *)
#Preview {
    @Previewable @State var navSelection: NavigationItem? = .home
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)
    MainWindow(navigationSelection: $navSelection, client: ytMusicClient)
        .environment(authService)
        .environment(PlayerService())
        .environment(WebKitManager.shared)
        .environment(accountService)
}
