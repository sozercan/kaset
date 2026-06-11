import SwiftUI

// MARK: - YouTubeContentView

/// Detail-column router for the YouTube (video) experience.
///
/// Mirrors `MainWindow.detailView`/`viewForNavigationItem` on the music side.
/// Items render placeholders until their milestone lands.
struct YouTubeContentView: View {
    let selection: YouTubeNavigationItem?

    var body: some View {
        Group {
            if let selection {
                self.placeholder(for: selection)
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

    private func placeholder(for item: YouTubeNavigationItem) -> some View {
        ContentUnavailableView {
            Label(item.displayName, systemImage: item.icon)
        } description: {
            Text("\(item.displayName) is coming soon.", comment: "Placeholder for an unimplemented YouTube section")
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.placeholder(for: item))
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
    enum YouTubeContent {
        static func placeholder(for item: YouTubeNavigationItem) -> String {
            "youtubeContent.placeholder.\(item.rawValue)"
        }
    }
}

#Preview {
    YouTubeContentView(selection: .home)
        .environment(PlayerService())
        .environment(WebKitManager.shared)
        .environment(FavoritesManager.shared)
        .environment(SongLikeStatusManager.shared)
        .frame(width: 800, height: 600)
}
