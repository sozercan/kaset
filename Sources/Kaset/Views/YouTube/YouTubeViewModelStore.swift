import Foundation
import Observation

/// Owns the YouTube experience's view models so they persist across
/// source toggles and sidebar navigation (parallel to MainWindow's cached
/// music view models, but grouped to keep MainWindow lean).
@MainActor
@Observable
final class YouTubeViewModelStore {
    let client: any YouTubeClientProtocol

    private(set) var home: YouTubeHomeViewModel
    private(set) var search: YouTubeSearchViewModel
    private(set) var explore: YouTubeExploreViewModel
    private(set) var subscriptions: YouTubeSubscriptionsViewModel
    private(set) var history: YouTubeHistoryViewModel
    private(set) var playlists: YouTubePlaylistsViewModel

    init(client: any YouTubeClientProtocol) {
        self.client = client
        self.home = YouTubeHomeViewModel(client: client)
        self.search = YouTubeSearchViewModel(client: client)
        self.explore = YouTubeExploreViewModel(client: client)
        self.subscriptions = YouTubeSubscriptionsViewModel(client: client)
        self.history = YouTubeHistoryViewModel(client: client)
        self.playlists = YouTubePlaylistsViewModel(client: client)
    }

    /// Resets account-scoped state after an account switch.
    func resetForAccountChange() {
        self.home = YouTubeHomeViewModel(client: self.client)
        self.search = YouTubeSearchViewModel(client: self.client)
        self.explore = YouTubeExploreViewModel(client: self.client)
        self.subscriptions = YouTubeSubscriptionsViewModel(client: self.client)
        self.history = YouTubeHistoryViewModel(client: self.client)
        self.playlists = YouTubePlaylistsViewModel(client: self.client)
    }
}
