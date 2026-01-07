import SwiftUI

// MARK: - MainWindow

/// Main application window with sidebar navigation and player bar.
@available(macOS 26.0, *)
struct MainWindow: View {
    @Environment(AuthService.self) private var authService
    @Environment(PlayerService.self) private var playerService
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(\.showCommandBar) private var showCommandBar

    /// Binding to navigation selection for keyboard shortcut control from parent.
    @Binding var navigationSelection: NavigationItem?

    @State private var showLoginSheet = false
    @State private var showCommandBarSheet = false
    @State private var ytMusicClient: (any YTMusicClientProtocol)?

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

    /// Column visibility state for NavigationSplitView - persisted to fix restoration from dock.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
                        .accessibilityLabel("Close")
                        .padding(3)
                    }
                }
                .shadow(color: self.playerService.showMiniPlayer ? .black.opacity(0.2) : .clear, radius: 6, y: 3)
                .padding(.trailing, self.playerService.showMiniPlayer ? 12 : 0)
                .padding(.bottom, self.playerService.showMiniPlayer ? 76 : 0)
                .allowsHitTesting(self.playerService.showMiniPlayer)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: self.playerService.showMiniPlayer)
        .sheet(isPresented: self.$showLoginSheet) {
            LoginSheet()
        }
        .overlay {
            // Command bar overlay - dismisses when clicking outside
            if self.showCommandBarSheet, let client = ytMusicClient {
                ZStack {
                    // Background tap area to dismiss
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            self.showCommandBarSheet = false
                        }

                    // Command bar centered
                    CommandBarView(client: client, isPresented: self.$showCommandBarSheet)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                .animation(.easeInOut(duration: 0.15), value: self.showCommandBarSheet)
            }
        }
        .onChange(of: self.showCommandBar.wrappedValue) { _, newValue in
            if newValue {
                self.showCommandBarSheet = true
                self.showCommandBar.wrappedValue = false
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
        .task {
            self.setupClient()
            NowPlayingManager.shared.configure(playerService: self.playerService)
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if let client = ytMusicClient {
            ZStack(alignment: .trailing) {
                // Main navigation content
                NavigationSplitView(columnVisibility: self.$columnVisibility) {
                    Sidebar(selection: self.$navigationSelection)
                } detail: {
                    self.detailView(for: self.navigationSelection, client: client)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    // Ensure sidebar is visible when window becomes key (e.g., restored from dock)
                    if self.columnVisibility != .all {
                        self.columnVisibility = .all
                    }
                }

                // Right sidebar overlay - either lyrics or queue (mutually exclusive)
                self.rightSidebarOverlay(client: client)
            }
            .animation(.easeInOut(duration: 0.25), value: self.playerService.showLyrics)
            .animation(.easeInOut(duration: 0.25), value: self.playerService.showQueue)
            .frame(minWidth: 900, minHeight: 600)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        self.showCommandBarSheet = true
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Ask AI (⌘K)")
                    .accessibilityIdentifier(AccessibilityID.MainWindow.aiButton)
                    .requiresIntelligence()
                }
            }
        } else {
            self.loadingView
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
                        QueueView()
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

    @ViewBuilder
    private func detailView(for item: NavigationItem?, client _: any YTMusicClientProtocol) -> some View {
        Group {
            if let item {
                self.viewForNavigationItem(item)
            } else {
                Text("Select an item from the sidebar")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Returns the view for a specific navigation item.
    @ViewBuilder
    // swiftlint:disable:next cyclomatic_complexity
    private func viewForNavigationItem(_ item: NavigationItem) -> some View {
        switch item {
        case .home:
            if let vm = homeViewModel { HomeView(viewModel: vm) }
        case .explore:
            if let vm = exploreViewModel { ExploreView(viewModel: vm) }
        case .search:
            if let vm = searchViewModel { SearchView(viewModel: vm) }
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
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
                .scaleEffect(1.5)
                .frame(width: 30, height: 30)
            Text("Loading YouTube Music...")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 900, minHeight: 600)
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

    // MARK: - Setup

    private func setupClient() {
        // Use mock client in UI test mode, real client otherwise
        let client: any YTMusicClientProtocol = if UITestConfig.isUITestMode {
            MockUITestYTMusicClient()
        } else {
            YTMusicClient(
                authService: self.authService,
                webKitManager: self.webKitManager
            )
        }

        self.ytMusicClient = client

        // Create view models once and cache them
        self.homeViewModel = HomeViewModel(client: client)
        self.exploreViewModel = ExploreViewModel(client: client)
        self.searchViewModel = SearchViewModel(client: client)
        self.chartsViewModel = ChartsViewModel(client: client)
        self.moodsAndGenresViewModel = MoodsAndGenresViewModel(client: client)
        self.newReleasesViewModel = NewReleasesViewModel(client: client)
        self.podcastsViewModel = PodcastsViewModel(client: client)
        self.likedMusicViewModel = LikedMusicViewModel(client: client)
        self.libraryViewModel = LibraryViewModel(client: client)

        // Don't start loading here - let each view's onAppear handle it
        // This avoids race conditions after login where cookies may not be fully ready
    }

    private func handleAuthStateChange(oldState: AuthService.State, newState: AuthService.State) {
        switch newState {
        case .initializing:
            // Still checking login status, do nothing
            break
        case .loggedOut:
            // Onboarding view handles login, no need to auto-show sheet
            break
        case .loggingIn:
            self.showLoginSheet = true
        case .loggedIn:
            self.showLoginSheet = false
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

    var id: String { rawValue }

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
        }
    }
}

@available(macOS 26.0, *)
#Preview {
    @Previewable @State var navSelection: NavigationItem? = .home
    let authService = AuthService()
    MainWindow(navigationSelection: $navSelection)
        .environment(authService)
        .environment(PlayerService())
        .environment(WebKitManager.shared)
}
