import SwiftUI

// MARK: - YouTubeContentView

/// Detail-column router for the YouTube (video) experience.
///
/// Mirrors `MainWindow.detailView`/`viewForNavigationItem` on the music side.
/// Sections without an implementation yet render placeholders.
struct YouTubeContentView: View {
    let selection: YouTubeNavigationItem?
    let store: YouTubeViewModelStore

    var body: some View {
        Group {
            if let selection {
                NavigationStack {
                    self.rootView(for: selection)
                        .youtubeNavigationDestinations(client: self.store.client)
                }
                // Reset the drill-in stack when the sidebar selection changes.
                .id(selection)
            } else {
                Text("Select an item from the sidebar", comment: "Placeholder shown when no sidebar item is selected")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
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
