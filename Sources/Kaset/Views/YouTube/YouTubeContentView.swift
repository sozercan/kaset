import SwiftUI

struct YouTubeContentView: View {
    let selection: YouTubeNavigationItem?
    @Bindable var store: YouTubeViewModelStore

    @Environment(AuthService.self) private var authService
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    var body: some View {
        Group {
            if let selection {
                NavigationStack(path: self.$store.navigationPath) {
                    self.rootView(for: selection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .youtubePagePlayerBarInset(keepsBar: selection == .shorts)
                        .youtubeNavigationDestinations(client: self.store.client)
                }
                .id(selection)
            } else {
                Text("Select an item from the sidebar", comment: "Placeholder shown when no sidebar item is selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .youtubePagePlayerBarInset()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(self.store)
        .onAppear {
            guard self.selection == .home, self.store.navigationPath.isEmpty else { return }
            self.store.home.refreshContinueWatching(forGeneration: self.youtubePlayer.watchActivityGeneration)
        }
        .onChange(of: self.youtubePlayer.popInRequest) { _, request in
            self.handlePopInRequest(request)
        }
        .onChange(of: self.youtubePlayer.skipNavigationRequest) { _, request in
            self.handleSkipNavigationRequest(request)
        }
        .onChange(of: self.selection) { _, newSelection in
            self.store.navigationPath = NavigationPath()
            if newSelection == .home {
                self.store.home.refreshContinueWatching(forGeneration: self.youtubePlayer.watchActivityGeneration)
            }
        }
        .onChange(of: self.store.navigationPath.count) { oldDepth, newDepth in
            guard self.selection == .home, newDepth == 0, oldDepth > 0 else { return }
            self.store.home.refreshContinueWatching(forGeneration: self.youtubePlayer.watchActivityGeneration)
        }
        .onChange(of: self.youtubePlayer.watchConclusionGeneration) { _, _ in
            guard self.selection == .home, self.store.navigationPath.isEmpty else { return }
            self.store.home.refreshContinueWatching(forGeneration: self.youtubePlayer.watchActivityGeneration)
        }
    }

    private func handleSkipNavigationRequest(_ request: YouTubeVideo?) {
        guard let video = request else { return }
        defer {
            self.youtubePlayer.consumeSkipNavigationRequest()
        }
        self.store.navigationPath.append(YouTubeRoute.watch(video))
    }

    private func handlePopInRequest(_ request: YouTubeVideo?) {
        guard let video = request else { return }
        defer {
            self.youtubePlayer.consumePopInRequest()
        }

        if self.youtubePlayer.activeInlineVideoId == video.videoId {
            self.youtubePlayer.dockInline()
        } else {
            self.store.navigationPath.append(YouTubeRoute.watch(video))
        }
    }

    @ViewBuilder
    private func rootView(for item: YouTubeNavigationItem) -> some View {
        if item.requiresSignIn, !self.hasPersonalAccount {
            SignInRequiredView(
                title: String(localized: "Sign in to use \(item.displayName)"),
                message: String(localized: "Kaset works without login for public YouTube search, discovery, and playback. Sign in to access personal video collections.")
            )
        } else {
            self.publicOrAuthenticatedRootView(for: item)
        }
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    @ViewBuilder
    private func publicOrAuthenticatedRootView(for item: YouTubeNavigationItem) -> some View {
        switch item {
        case .home:
            YouTubeHomeView(viewModel: self.store.home)
        case .search:
            YouTubeSearchView(viewModel: self.store.search)
        case .explore:
            YouTubeExploreView(viewModel: self.store.explore)
        case .shorts:
            YouTubeShortsView(viewModel: self.store.shorts)
        case .subscriptions:
            YouTubeSubscriptionsView(viewModel: self.store.subscriptions)
        case .likedVideos:
            YouTubePlaylistDetailView(playlistId: "LL", client: self.store.client)
        case .watchLater:
            YouTubePlaylistDetailView(playlistId: "WL", client: self.store.client)
        case .playlists:
            YouTubePlaylistsView(viewModel: self.store.playlists)
        case .history:
            YouTubeHistoryView(viewModel: self.store.history)
        }
    }
}

enum YouTubeNavigationItem: String, Hashable, CaseIterable, Identifiable {
    case home = "Home"
    case search = "Search"
    case subscriptions = "Subscriptions"
    case explore = "Explore"
    case shorts = "Shorts"
    case likedVideos = "Liked Videos"
    case watchLater = "Watch Later"
    case playlists = "Playlists"
    case history = "History"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .home:
            String(localized: "Home")
        case .search:
            String(localized: "Search")
        case .subscriptions:
            String(localized: "Subscriptions")
        case .explore:
            String(localized: "Explore")
        case .shorts:
            String(localized: "Shorts")
        case .likedVideos:
            String(localized: "Liked Videos")
        case .watchLater:
            String(localized: "Watch Later")
        case .playlists:
            String(localized: "Playlists")
        case .history:
            String(localized: "History")
        }
    }

    var icon: String {
        switch self {
        case .home:
            "house"
        case .search:
            "magnifyingglass"
        case .subscriptions:
            "rectangle.stack.badge.play"
        case .explore:
            "globe"
        case .shorts:
            "rectangle.portrait.on.rectangle.portrait.angled"
        case .likedVideos:
            "hand.thumbsup.fill"
        case .watchLater:
            "clock"
        case .playlists:
            "list.and.film"
        case .history:
            "clock.arrow.circlepath"
        }
    }

    var requiresSignIn: Bool {
        switch self {
        case .home, .search, .explore, .shorts:
            false
        case .subscriptions, .likedVideos, .watchLater, .playlists, .history:
            true
        }
    }
}

extension AccessibilityID {
    enum YouTubeContent {}
}
