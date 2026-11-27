import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class YouTubeViewModelStore {
    let client: any YouTubeClientProtocol

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

    func resetForAccountChange() {
        self.navigationPath = NavigationPath()
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

    func refreshGuestContent() async {
        await self.home.refresh()
        await self.explore.refresh()
        await self.shorts.refresh()
    }
}
