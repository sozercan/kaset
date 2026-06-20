import SwiftUI

// MARK: - YouTubeContentView

/// Detail-column router for the YouTube (video) experience.
///
/// Mirrors `MainWindow.detailView`/`viewForNavigationItem` on the music side.
/// Sections without an implementation yet render placeholders.
struct YouTubeContentView: View {
    let selection: YouTubeNavigationItem?
    @Bindable var store: YouTubeViewModelStore

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
        .onChange(of: self.youtubePlayer.popInRequest) { _, request in
            self.handlePopInRequest(request)
        }
        .onChange(of: self.youtubePlayer.skipNavigationRequest) { _, request in
            self.handleSkipNavigationRequest(request)
        }
        .onChange(of: self.selection) { _, newSelection in
            self.store.navigationPath = NavigationPath()
            // Returning to Home via the sidebar is the other way back after
            // watching (watch from any section, then pick Home). The path is
            // already — or just reset to — empty, so the count-based trigger
            // below won't fire; fire the same gated refresh here. It's a no-op
            // when no new activity happened (count unchanged) or on cold launch
            // (count 0), so this never double-fetches with the count trigger.
            if newSelection == .home {
                self.store.home.refreshContinueWatching(afterPlaybackCount: self.youtubePlayer.playbackActivityCount)
            }
        }
        // Returning to the Home root by popping the drill-in stack (Back from a
        // video opened on Home) rebuilds the Continue Watching rail (a finished
        // video drops out; a partially-watched one appears). Home's reload is
        // keyed on view-model identity, so a navigation pop never re-runs it on
        // its own. The player's monotonic `playbackActivityCount` gates the
        // rebuild, so incidental returns from other drill-ins (where nothing was
        // played) don't re-fetch history, while re-watching the same video still
        // counts as new activity.
        .onChange(of: self.store.navigationPath.count) { oldDepth, newDepth in
            guard self.selection == .home, newDepth == 0, oldDepth > 0 else { return }
            self.store.home.refreshContinueWatching(afterPlaybackCount: self.youtubePlayer.playbackActivityCount)
        }
        // The user can also be sitting ON the Home root while a video plays in
        // the floating window (it pops out there when navigating away mid-play)
        // and then skips or finishes — no selection/path change fires. Observe
        // `playbackProgressEventCount`, which advances only on a skip or finish
        // (NOT a bare start), so a video started from Home doesn't prematurely
        // consume the activity gate and suppress a later partial-watch refresh.
        // The gate value passed to the model stays `playbackActivityCount`.
        // Gated to the Home root so it doesn't fetch while drilled in or on
        // another section.
        .onChange(of: self.youtubePlayer.playbackProgressEventCount) { _, _ in
            guard self.selection == .home, self.store.navigationPath.isEmpty else { return }
            self.store.home.refreshContinueWatching(afterPlaybackCount: self.youtubePlayer.playbackActivityCount)
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
}

// MARK: - AccessibilityID.YouTubeContent

extension AccessibilityID {
    enum YouTubeContent {}
}
