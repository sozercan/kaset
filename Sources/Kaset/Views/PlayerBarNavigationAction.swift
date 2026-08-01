import SwiftUI

// MARK: - PlayerBarNavigationAction

struct PlayerBarNavigationAction: @unchecked Sendable {
    var openArtist: ((Artist) -> Void)?
    var openAlbum: ((Playlist) -> Void)?

    static let disabled = PlayerBarNavigationAction()
}

extension EnvironmentValues {
    @Entry var playerBarNavigationAction: PlayerBarNavigationAction = .disabled
    @Entry var playerBarCurrentAlbumID: String?
    @Entry var playerBarCurrentArtistID: String?
}

// MARK: - PlayerBarMusicNavigationModifier

private struct PlayerBarMusicNavigationModifier: ViewModifier {
    @Binding var navigationPath: NavigationPath

    func body(content: Content) -> some View {
        content
            .environment(\.playerBarNavigationAction, PlayerBarNavigationAction(
                openArtist: { artist in
                    self.navigationPath.append(artist)
                },
                openAlbum: { album in
                    self.navigationPath.append(album)
                }
            ))
    }
}

extension View {
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
