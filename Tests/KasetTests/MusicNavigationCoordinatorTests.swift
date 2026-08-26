import SwiftUI
import Testing
@testable import Kaset

// MARK: - MusicNavigationCoordinatorTests

@Suite(.tags(.model))
@MainActor
struct MusicNavigationCoordinatorTests {
    @Test("playerBarNavigationAction routes artist pushes to the active tab stack")
    func routesArtistToActiveTab() {
        let coordinator = MusicNavigationCoordinator()
        coordinator.updateActiveRoute(tab: .home, pinnedContentID: nil)

        let artist = TestFixtures.makeArtist(id: "UC-home-artist", name: "Home Artist")
        coordinator.playerBarNavigationAction.openArtist?(artist)

        #expect(coordinator.homeNavigationPath.count == 1)
        #expect(coordinator.searchNavigationPath.isEmpty)
    }

    @Test("playerBarNavigationAction follows sidebar route changes without resetting other stacks")
    func followsActiveRouteChanges() {
        let coordinator = MusicNavigationCoordinator()
        coordinator.updateActiveRoute(tab: .home, pinnedContentID: nil)
        coordinator.playerBarNavigationAction.openArtist?(TestFixtures.makeArtist(id: "UC-1", name: "One"))

        coordinator.updateActiveRoute(tab: .search, pinnedContentID: nil)
        coordinator.playerBarNavigationAction.openArtist?(TestFixtures.makeArtist(id: "UC-2", name: "Two"))

        #expect(coordinator.homeNavigationPath.count == 1)
        #expect(coordinator.searchNavigationPath.count == 1)
    }

    @Test("playerBarNavigationAction routes album pushes to the active pinned playlist stack")
    func routesAlbumToPinnedStack() {
        let coordinator = MusicNavigationCoordinator()
        coordinator.updateActiveRoute(tab: .home, pinnedContentID: "pinned-playlist-1")

        let album = TestFixtures.makePlaylist(id: "MPRE-pinned-album", title: "Pinned Album")
        coordinator.playerBarNavigationAction.openAlbum?(album)

        #expect(coordinator.pinnedNavigationPaths["pinned-playlist-1"]?.count == 1)
        #expect(coordinator.homeNavigationPath.isEmpty)
    }

    @Test("album route lifecycle ignores playlists and does not clear a newer album")
    func albumRouteLifecycle() {
        let coordinator = MusicNavigationCoordinator()
        let playlist = TestFixtures.makePlaylist(id: "VL-playlist")
        let firstAlbum = TestFixtures.makePlaylist(id: "MPRE-first-album")
        let secondAlbum = TestFixtures.makePlaylist(id: "MPRE-second-album")

        coordinator.showAlbumRoute(for: playlist)
        #expect(coordinator.routeAlbumID == nil)

        coordinator.showAlbumRoute(for: firstAlbum)
        coordinator.showAlbumRoute(for: secondAlbum)
        coordinator.hideAlbumRoute(for: firstAlbum)
        #expect(coordinator.routeAlbumID == secondAlbum.id)

        coordinator.hideAlbumRoute(for: secondAlbum)
        #expect(coordinator.routeAlbumID == nil)
    }

    @Test("resetAllNavigationPaths clears every stack and route context")
    func resetClearsStacksAndRouteContext() {
        let coordinator = MusicNavigationCoordinator()
        coordinator.updateActiveRoute(tab: .library, pinnedContentID: nil)
        coordinator.setRouteArtistID("artist-on-screen")
        coordinator.setRouteAlbumID("album-on-screen")
        coordinator.libraryNavigationPath.append(TestFixtures.makeArtist(id: "UC-lib", name: "Library Artist"))
        coordinator.pinnedNavigationPaths["pin-1"] = NavigationPath()

        coordinator.resetAllNavigationPaths()

        #expect(coordinator.libraryNavigationPath.isEmpty)
        #expect(coordinator.pinnedNavigationPaths.isEmpty)
        #expect(coordinator.routeArtistID == nil)
        #expect(coordinator.routeAlbumID == nil)
    }

    @Test("playerBarNavigationAction is disabled when active route has no mounted navigation stack")
    func disabledWhenNoMountedStack() {
        let coordinator = MusicNavigationCoordinator()
        coordinator.updateActiveRoute(tab: .library, pinnedContentID: nil, hasNavigationStack: false)

        #expect(coordinator.playerBarNavigationAction.openArtist == nil)
        #expect(coordinator.playerBarNavigationAction.openAlbum == nil)
        #expect(coordinator.activeNavigationPathBinding() == nil)
    }

    @Test("guest-gated tabs disable navigation for liked music, library, and history")
    func disabledForGuestGatedTabs() {
        let coordinator = MusicNavigationCoordinator()
        for tab in [NavigationItem.likedMusic, .library, .history] {
            coordinator.updateActiveRoute(tab: tab, pinnedContentID: nil, hasNavigationStack: false)

            #expect(coordinator.playerBarNavigationAction.openArtist == nil)
            #expect(coordinator.playerBarNavigationAction.openAlbum == nil)
        }
    }

    @Test("active route binding returns nil when no tab or pin is selected")
    func disabledNavigationWhenNoActiveRoute() {
        let coordinator = MusicNavigationCoordinator()

        #expect(coordinator.activeNavigationPathBinding() == nil)
        #expect(coordinator.playerBarNavigationAction.openArtist == nil)
        #expect(coordinator.playerBarNavigationAction.openAlbum == nil)
    }
}
