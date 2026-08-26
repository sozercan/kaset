import SwiftUI

// MARK: - MusicNavigationCoordinator

/// Owns music sidebar navigation paths and the active route used by the shared PlayerBar.
@Observable @MainActor
final class MusicNavigationCoordinator {
    var homeNavigationPath = NavigationPath()
    var exploreNavigationPath = NavigationPath()
    var searchNavigationPath = NavigationPath()
    var chartsNavigationPath = NavigationPath()
    var moodsAndGenresNavigationPath = NavigationPath()
    var newReleasesNavigationPath = NavigationPath()
    var podcastsNavigationPath = NavigationPath()
    var likedMusicNavigationPath = NavigationPath()
    var libraryNavigationPath = NavigationPath()
    var historyNavigationPath = NavigationPath()
    var pinnedNavigationPaths: [String: NavigationPath] = [:]

    var activeTab: NavigationItem?
    var activePinnedContentID: String?
    private(set) var activeRouteHasNavigationStack = false

    var routeArtistID: String?
    var routeAlbumID: String?

    func navigationPathBinding(for item: NavigationItem) -> Binding<NavigationPath> {
        switch item {
        case .home:
            Binding(get: { self.homeNavigationPath }, set: { self.homeNavigationPath = $0 })
        case .explore:
            Binding(get: { self.exploreNavigationPath }, set: { self.exploreNavigationPath = $0 })
        case .search:
            Binding(get: { self.searchNavigationPath }, set: { self.searchNavigationPath = $0 })
        case .charts:
            Binding(get: { self.chartsNavigationPath }, set: { self.chartsNavigationPath = $0 })
        case .moodsAndGenres:
            Binding(get: { self.moodsAndGenresNavigationPath }, set: { self.moodsAndGenresNavigationPath = $0 })
        case .newReleases:
            Binding(get: { self.newReleasesNavigationPath }, set: { self.newReleasesNavigationPath = $0 })
        case .podcasts:
            Binding(get: { self.podcastsNavigationPath }, set: { self.podcastsNavigationPath = $0 })
        case .likedMusic:
            Binding(get: { self.likedMusicNavigationPath }, set: { self.likedMusicNavigationPath = $0 })
        case .library:
            Binding(get: { self.libraryNavigationPath }, set: { self.libraryNavigationPath = $0 })
        case .history:
            Binding(get: { self.historyNavigationPath }, set: { self.historyNavigationPath = $0 })
        }
    }

    func pinnedPathBinding(for contentID: String) -> Binding<NavigationPath> {
        Binding(
            get: { self.pinnedNavigationPaths[contentID, default: NavigationPath()] },
            set: { self.pinnedNavigationPaths[contentID] = $0 }
        )
    }

    func updateActiveRoute(tab: NavigationItem?, pinnedContentID: String?, hasNavigationStack: Bool = true) {
        self.activeTab = tab
        self.activePinnedContentID = pinnedContentID
        self.activeRouteHasNavigationStack = hasNavigationStack
    }

    func activeNavigationPathBinding() -> Binding<NavigationPath>? {
        guard self.activeRouteHasNavigationStack else { return nil }
        if let contentID = self.activePinnedContentID {
            return self.pinnedPathBinding(for: contentID)
        }
        if let tab = self.activeTab {
            return self.navigationPathBinding(for: tab)
        }
        return nil
    }

    var playerBarNavigationAction: PlayerBarNavigationAction {
        guard self.activeRouteHasNavigationStack,
              let binding = self.activeNavigationPathBinding() else { return .disabled }
        return PlayerBarNavigationAction(
            openArtist: { artist in binding.wrappedValue.append(artist) },
            openAlbum: { album in binding.wrappedValue.append(album) }
        )
    }

    func resetAllNavigationPaths() {
        self.homeNavigationPath = NavigationPath()
        self.exploreNavigationPath = NavigationPath()
        self.searchNavigationPath = NavigationPath()
        self.chartsNavigationPath = NavigationPath()
        self.moodsAndGenresNavigationPath = NavigationPath()
        self.newReleasesNavigationPath = NavigationPath()
        self.podcastsNavigationPath = NavigationPath()
        self.likedMusicNavigationPath = NavigationPath()
        self.libraryNavigationPath = NavigationPath()
        self.historyNavigationPath = NavigationPath()
        self.pinnedNavigationPaths = [:]
        self.routeArtistID = nil
        self.routeAlbumID = nil
    }

    func setRouteAlbumID(_ albumID: String?) {
        self.routeAlbumID = albumID
    }

    func showAlbumRoute(for playlist: Playlist) {
        guard playlist.isAlbum else { return }
        self.routeAlbumID = playlist.id
    }

    func hideAlbumRoute(for playlist: Playlist) {
        guard playlist.isAlbum, self.routeAlbumID == playlist.id else { return }
        self.routeAlbumID = nil
    }

    func setRouteArtistID(_ artistID: String?) {
        self.routeArtistID = artistID
    }
}
