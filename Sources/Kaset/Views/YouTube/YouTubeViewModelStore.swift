import Foundation
import Observation
import SwiftUI

/// Owns the YouTube experience's view models so they persist across
/// source toggles and sidebar navigation (parallel to MainWindow's cached
/// music view models, but grouped to keep MainWindow lean).
@MainActor
@Observable
final class YouTubeViewModelStore {
    let client: any YouTubeClientProtocol

    /// Drill-in path for the active section's stack. Lives here (not in
    /// the content view) so toggling to Music and back restores the exact
    /// screen — e.g. the watch view you were on.
    var navigationPath = NavigationPath()

    private(set) var home: YouTubeHomeViewModel
    private(set) var search: YouTubeSearchViewModel
    private(set) var explore: YouTubeExploreViewModel
    private(set) var shorts: YouTubeShortsViewModel
    private(set) var subscriptions: YouTubeSubscriptionsViewModel
    private(set) var history: YouTubeHistoryViewModel
    private(set) var playlists: YouTubePlaylistsViewModel

    init(client: any YouTubeClientProtocol) {
        self.client = client
        self.home = YouTubeHomeViewModel(client: client)
        self.search = YouTubeSearchViewModel(client: client)
        self.explore = YouTubeExploreViewModel(client: client)
        self.shorts = YouTubeShortsViewModel(client: client)
        self.subscriptions = YouTubeSubscriptionsViewModel(client: client)
        self.history = YouTubeHistoryViewModel(client: client)
        self.playlists = YouTubePlaylistsViewModel(client: client)
    }

    /// Resets account-scoped state after an account switch.
    func resetForAccountChange() {
        self.navigationPath = NavigationPath()
        // Cancel outgoing in-flight work before discarding the models: their
        // unstructured single-flight tasks intentionally survive SwiftUI task
        // cancellation, so account changes must explicitly stop them before the
        // shared client/cache scope moves to the new account.
        self.home.cancelLoad()
        self.search.cancelSearch()
        self.explore.cancelLoad()
        self.shorts.cancelLoad()
        self.subscriptions.cancelLoad()
        self.history.cancelLoad()
        self.playlists.cancelLoad()

        self.home = YouTubeHomeViewModel(client: self.client)
        self.search = YouTubeSearchViewModel(client: self.client)
        self.explore = YouTubeExploreViewModel(client: self.client)
        self.shorts = YouTubeShortsViewModel(client: self.client)
        self.subscriptions = YouTubeSubscriptionsViewModel(client: self.client)
        self.history = YouTubeHistoryViewModel(client: self.client)
        self.playlists = YouTubePlaylistsViewModel(client: self.client)
    }

    /// Refreshes public guest-safe YouTube surfaces after sign-out.
    ///
    /// Signed-in-only surfaces (subscriptions, history, playlists) are reset
    /// above and hidden in guest mode, so only public feeds should fetch here.
    func refreshGuestContent() async {
        await self.home.refresh()
        await self.explore.refresh()
        await self.shorts.refresh()
    }
}
