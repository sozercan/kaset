import SwiftUI

// MARK: - YouTubeContentView

/// Detail-column router for the YouTube (video) experience.
///
/// Mirrors `MainWindow.detailView`/`viewForNavigationItem` on the music side.
/// Sections without an implementation yet render placeholders.
struct YouTubeContentView: View {
    let selection: YouTubeNavigationItem?
    @Bindable var store: YouTubeViewModelStore

    @Environment(AuthService.self) private var authService
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    var body: some View {
        Group {
            if let selection {
                NavigationStack(path: self.$store.navigationPath) {
                    // Each navigable view carries its own bar inset
                    // (pushed views don't inherit a parent's safeAreaInset).
                    self.rootView(for: selection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .youtubePlayerBarInset()
                        .youtubeNavigationDestinations(client: self.store.client)
                }
                // Reset the drill-in stack when the sidebar selection changes.
                .id(selection)
            } else {
                Text("Select an item from the sidebar", comment: "Placeholder shown when no sidebar item is selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .youtubePlayerBarInset()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(self.store)
        // Reconcile on (re)mount: switching to the Music source unmounts this
        // view, so the observers below can't see a floating video that finishes
        // or is closed while away. On switching back to YouTube with Home already
        // selected and the path empty, neither `selection` nor the path changes
        // and `YouTubeHomeView.load()` is a no-op — so without this, a conclusion
        // missed during the Music detour would leave the rail stale. The
        // view-model watermark makes this a no-op when nothing was missed.
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
            // Returning to Home via the sidebar is one way back after watching
            // (watch from any section, then pick Home). The path is already — or
            // just reset to — empty, so the depth trigger below won't fire; drive
            // the same gated refresh here. The view-model watermark makes it a
            // no-op when no newer watch activity occurred, so the three observers
            // coalesce safely.
            if newSelection == .home {
                self.store.home.refreshContinueWatching(forGeneration: self.youtubePlayer.watchActivityGeneration)
            }
        }
        // Returning to the Home root by popping the drill-in stack (Back from a
        // video opened on Home) rebuilds the Continue Watching rail (a finished
        // video drops out; a partially-watched one appears). Home's reload is
        // keyed on view-model identity, so a navigation pop never re-runs it on
        // its own. The view model gates on the player's monotonic
        // `watchActivityGeneration` against its own watermark, so incidental
        // returns (no new activity) don't re-fetch.
        .onChange(of: self.store.navigationPath.count) { oldDepth, newDepth in
            guard self.selection == .home, newDepth == 0, oldDepth > 0 else { return }
            self.store.home.refreshContinueWatching(forGeneration: self.youtubePlayer.watchActivityGeneration)
        }
        // The user can also be sitting ON the Home root while a video plays in
        // the floating window (it pops out there when navigating away mid-play)
        // and then skips, finishes, drifts, or is closed — no selection/path
        // change fires. Observe `watchConclusionGeneration`, which advances only
        // when a watch CONCLUDES with progress (skip/finish/drift/stop), NOT on a
        // bare start: a video merely starting while Home is visible has no new
        // resume state, and refreshing then would advance the watermark and
        // swallow the progress that accrues afterward. The value passed to the
        // model stays `watchActivityGeneration` (the gate). Gated to the Home
        // root so it doesn't fetch while drilled in or on another section.
        .onChange(of: self.youtubePlayer.watchConclusionGeneration) { _, _ in
            guard self.selection == .home, self.store.navigationPath.isEmpty else { return }
            self.store.home.refreshContinueWatching(forGeneration: self.youtubePlayer.watchActivityGeneration)
        }
    }

    /// A skip changed the video while docked inline: open the new video's
    /// watch view so the surface has a home.
    private func handleSkipNavigationRequest(_ request: YouTubeVideo?) {
        guard let video = request else { return }
        defer {
            self.youtubePlayer.consumeSkipNavigationRequest()
        }
        self.store.navigationPath.append(YouTubeRoute.watch(video))
    }

    /// Docks a popped-out video back into a watch view: adopts the one that
    /// is already open for this video, or pushes a fresh watch route.
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
            // "LL" is YouTube's fixed liked-videos playlist.
            YouTubePlaylistDetailView(playlistId: "LL", client: self.store.client)
        case .watchLater:
            // "WL" is YouTube's fixed Watch Later playlist.
            YouTubePlaylistDetailView(playlistId: "WL", client: self.store.client)
        case .playlists:
            YouTubePlaylistsView(viewModel: self.store.playlists)
        case .history:
            YouTubeHistoryView(viewModel: self.store.history)
        }
    }
}

// MARK: - YouTubeNavigationItem

/// Sidebar destinations for the YouTube (video) experience.
///
/// Mirrors the music side's `NavigationItem`, mapped to YouTube's content
/// model: the recommended feed, subscriptions, and the user's video library.
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

// MARK: - AccessibilityID.YouTubeContent

extension AccessibilityID {
    enum YouTubeContent {}
}
