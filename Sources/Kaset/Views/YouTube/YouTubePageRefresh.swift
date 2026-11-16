import SwiftUI

// MARK: - YouTubePageRefresh

/// Requests to refresh the YouTube page on screen, from the toolbar's Refresh
/// button and View → Refresh (⇧⌘R), the way a browser reloads the page.
///
/// Pages observe this shared object rather than an environment value: pages
/// pushed onto a navigation stack inside a `NavigationSplitView` take the split
/// view's environment, not the stack's. For the same reason it holds the
/// store, whose navigation path tells which page is on top.
@MainActor
@Observable
final class YouTubePageRefresh {
    static let shared = YouTubePageRefresh()

    /// Bumped by each request; pages refresh when it changes.
    private(set) var requestID = 0

    /// The store whose navigation stack the pages are on, set by
    /// `YouTubeContentView`.
    weak var store: YouTubeViewModelStore?

    /// Where the page for `route` sits in the path: the index a page pushed
    /// for it takes, its last occurrence; nil for a section's root page.
    /// Pages read this when they first appear, which is when they're pushed.
    func position(of route: YouTubeRoute?) -> Int? {
        guard let route else { return nil }
        return self.store?.navigationPath.lastIndex(of: route)
    }

    /// Whether the page at `position` for `route` is the one on screen: the
    /// section's root page while the path is empty, otherwise the last page
    /// pushed, so an earlier page for the same route doesn't count.
    ///
    /// A stack rebuilt with its path already pushed (after a switch to Music
    /// and back) brings all its pages up at once, so pages for a repeated
    /// route all note its last index. A position past the end of the path is
    /// one of those, and is on top once its route is last again. While the
    /// repeats are both in the path, both count as on top.
    func isOnTop(route: YouTubeRoute?, position: Int?) -> Bool {
        let path = self.store?.navigationPath ?? []
        guard let route else { return path.isEmpty }
        guard path.last == route else { return false }
        guard let position, position < path.count else { return true }
        return position == path.count - 1
    }

    func request() {
        self.requestID += 1
    }
}

// MARK: - Page Route

extension EnvironmentValues {
    /// The route a pushed YouTube page was opened for; nil on a section's
    /// root page. Set by `youtubeNavigationDestinations(client:)`.
    @Entry var youtubePageRoute: YouTubeRoute?
}

// MARK: - View Modifier

extension View {
    /// Runs `action` when a page refresh is requested while this page is the
    /// one on screen: a section's root page while nothing is pushed, a pushed
    /// page while it is the last in the path. A newer request, or the page
    /// going away, cancels a reload still running.
    func youtubePageRefreshable(_ action: @escaping @MainActor () async -> Void) -> some View {
        self.modifier(YouTubePageRefreshModifier(action: action))
    }
}

// MARK: - YouTubePageRefreshModifier

private struct YouTubePageRefreshModifier: ViewModifier {
    let action: @MainActor () async -> Void

    @Environment(\.youtubePageRoute) private var route
    @State private var pageRefresh = YouTubePageRefresh.shared
    /// The last request this page saw, so appearing doesn't count as one.
    @State private var lastSeenRequestID: Int?
    /// Where this page sits in the path, noted when it first appears.
    @State private var position: Int?

    func body(content: Content) -> some View {
        content
            .task(id: self.pageRefresh.requestID) {
                let requestID = self.pageRefresh.requestID
                defer { self.lastSeenRequestID = requestID }
                guard let lastSeen = self.lastSeenRequestID else {
                    self.position = self.pageRefresh.position(of: self.route)
                    return
                }
                guard requestID != lastSeen,
                      self.pageRefresh.isOnTop(route: self.route, position: self.position)
                else {
                    return
                }
                await self.action()
            }
    }
}
