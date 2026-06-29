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
