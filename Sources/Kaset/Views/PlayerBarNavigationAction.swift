import SwiftUI

// MARK: - PlayerBarNavigationAction

struct PlayerBarNavigationAction: @unchecked Sendable {
    var openArtist: ((Artist) -> Void)?
    var openAlbum: ((Playlist) -> Void)?

    static let disabled = PlayerBarNavigationAction()

    /// Opens artists and albums by pushing them onto `path`.
    static func appending(to path: Binding<NavigationPath>) -> PlayerBarNavigationAction {
        PlayerBarNavigationAction(
            openArtist: { path.wrappedValue.append($0) },
            openAlbum: { path.wrappedValue.append($0) }
        )
    }
}

extension EnvironmentValues {
    @Entry var playerBarNavigationAction: PlayerBarNavigationAction = .disabled
    /// IDs of the album page hosting the player bar, including its OLAK/MPRE aliases.
    @Entry var playerBarCurrentAlbumIDs: Set<String> = []
    @Entry var playerBarCurrentArtistID: String?
}

// MARK: - PlayerBarCurrentRoute

/// Matches player bar link targets against the album or artist page hosting the player bar,
/// so links to the page already on screen stay inert.
enum PlayerBarCurrentRoute {
    static func albumIDs(for playlist: Playlist, detail: PlaylistDetail?) -> Set<String> {
        guard playlist.isAlbum else { return [] }
        // An album opened by its OLAK ID loads the album's playlist page, whose tracks name its MPRE ID.
        let trackAlbumIDs = detail?.tracks.compactMap(\.album).filter(\.hasNavigableId).map(\.id) ?? []
        return Set([playlist.id, playlist.libraryTargetId, detail?.libraryTargetId].compactMap(\.self) + trackAlbumIDs)
    }

    static func isAlbum(_ album: Playlist, in routeAlbumIDs: Set<String>) -> Bool {
        !routeAlbumIDs.isDisjoint(with: [album.id, album.libraryTargetId].compactMap(\.self))
    }

    static func isArtist(_ artist: Artist, routeArtistID: String?) -> Bool {
        guard let routeArtistID else { return false }
        return artist.id == routeArtistID || artist.publicChannelId == routeArtistID
    }
}

// MARK: - PlayerBarMusicNavigationModifier

private struct PlayerBarMusicNavigationModifier: ViewModifier {
    @Binding var navigationPath: NavigationPath

    func body(content: Content) -> some View {
        content
            .environment(\.playerBarNavigationAction, .appending(to: self.$navigationPath))
    }
}

extension View {
    /// Routes player bar artist/album links onto `path`.
    ///
    /// Apply this to the `NavigationStack` itself: views pushed through `navigationDestination`
    /// inherit the stack's environment, not values set on the stack's root content.
    func playerBarMusicNavigation(path: Binding<NavigationPath>) -> some View {
        self.modifier(PlayerBarMusicNavigationModifier(navigationPath: path))
    }
}

// MARK: - SidebarReselectNavigationModifier

private struct SidebarReselectNavigationModifier: ViewModifier {
    @Binding var navigationPath: NavigationPath
    let navigationItem: NavigationItem
    @Environment(\.sidebarNavigationReselectGenerations) private var reselectGenerations

    func body(content: Content) -> some View {
        content.onChange(of: self.reselectGenerations.wrappedValue[self.navigationItem, default: 0]) { _, _ in
            guard !self.navigationPath.isEmpty else { return }
            self.navigationPath = NavigationPath()
        }
    }
}

extension View {
    func popsNavigationStackOnSidebarReselect(
        path: Binding<NavigationPath>,
        for navigationItem: NavigationItem
    ) -> some View {
        self.modifier(SidebarReselectNavigationModifier(
            navigationPath: path,
            navigationItem: navigationItem
        ))
    }
}
