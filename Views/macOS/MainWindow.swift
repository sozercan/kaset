import SwiftUI

// MARK: - MainWindow

/// Main application window with sidebar navigation and player bar.
@available(macOS 26.0, *)
struct MainWindow: View {
    @Environment(AuthService.self) private var authService
    @Environment(PlayerService.self) private var playerService
    @Environment(WebKitManager.self) private var webKitManager

    @State private var selectedNavigation: NavigationItem? = .home
    @State private var showLoginSheet = false
    @State private var ytMusicClient: YTMusicClient?
    @State private var nowPlayingManager: NowPlayingManager?

    /// Access to the app delegate for persistent WebView.
    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    var body: some View {
        @Bindable var player = playerService

        ZStack(alignment: .bottomTrailing) {
            Group {
                if authService.state.isLoggedIn {
                    mainContent
                } else {
                    OnboardingView()
                }
            }

            // Persistent WebView - always present once a video has been requested
            // Uses a SINGLETON WebView instance that persists for the app lifetime
            // Resizes between visible (160x90) and hidden (1x1) based on showMiniPlayer
            if let videoId = playerService.pendingPlayVideoId {
                ZStack(alignment: .topTrailing) {
                    PersistentPlayerView(videoId: videoId, isExpanded: playerService.showMiniPlayer)
                        .frame(
                            width: playerService.showMiniPlayer ? 160 : 1,
                            height: playerService.showMiniPlayer ? 90 : 1
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    if playerService.showMiniPlayer {
                        Button {
                            playerService.confirmPlaybackStarted()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(radius: 2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                        .padding(4)
                    }
                }
                .shadow(color: playerService.showMiniPlayer ? .black.opacity(0.3) : .clear, radius: 8, y: 4)
                .padding(.trailing, playerService.showMiniPlayer ? 16 : 0)
                .padding(.bottom, playerService.showMiniPlayer ? 80 : 0)
                .allowsHitTesting(playerService.showMiniPlayer)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playerService.showMiniPlayer)
        .sheet(isPresented: $showLoginSheet) {
            LoginSheet()
        }
        .onChange(of: authService.state) { _, newState in
            handleAuthStateChange(newState)
        }
        .onChange(of: authService.needsReauth) { _, needsReauth in
            if needsReauth {
                showLoginSheet = true
            }
        }
        .onChange(of: playerService.isPlaying) { _, isPlaying in
            // Auto-hide the WebView once playback starts
            if isPlaying, playerService.showMiniPlayer {
                playerService.confirmPlaybackStarted()
            }
        }
        .task {
            setupClient()
            setupNowPlaying()
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if let client = ytMusicClient {
            NavigationSplitView {
                Sidebar(selection: $selectedNavigation)
            } detail: {
                detailView(for: selectedNavigation, client: client)
            }
            .frame(minWidth: 900, minHeight: 600)
        } else {
            loadingView
        }
    }

    @ViewBuilder
    private func detailView(for item: NavigationItem?, client: YTMusicClient) -> some View {
        switch item {
        case .home:
            HomeView(viewModel: HomeViewModel(client: client))
        case .explore:
            ExploreView(viewModel: ExploreViewModel(client: client))
        case .search:
            SearchView(viewModel: SearchViewModel(client: client))
        case .library:
            LibraryView(viewModel: LibraryViewModel(client: client))
        case .none:
            Text("Select an item from the sidebar")
                .foregroundStyle(.secondary)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading YouTube Music...")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: - Setup

    private func setupClient() {
        ytMusicClient = YTMusicClient(
            authService: authService,
            webKitManager: webKitManager
        )
    }

    private func setupNowPlaying() {
        nowPlayingManager = NowPlayingManager(playerService: playerService)
    }

    private func handleAuthStateChange(_ state: AuthService.State) {
        switch state {
        case .loggedOut:
            // Onboarding view handles login, no need to auto-show sheet
            break
        case .loggingIn:
            showLoginSheet = true
        case .loggedIn:
            showLoginSheet = false
        }
    }
}

// MARK: - NavigationItem

enum NavigationItem: String, Hashable, CaseIterable, Identifiable {
    case home = "Home"
    case explore = "Explore"
    case search = "Search"
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
        case .library:
            "music.note.list"
        }
    }
}

@available(macOS 26.0, *)
#Preview {
    let authService = AuthService()
    MainWindow()
        .environment(authService)
        .environment(PlayerService())
        .environment(WebKitManager.shared)
}
