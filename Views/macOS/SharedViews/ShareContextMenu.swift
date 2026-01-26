import AppKit
import SwiftUI

// MARK: - ShareContextMenu

/// Shared context menu items for sharing items via NSSharingServicePicker.
/// Uses native macOS sharing services for proper popup positioning in context menus.
@available(macOS 26.0, *)
@MainActor
enum ShareContextMenu {
    /// Shows the share picker at the current mouse location.
    private static func showSharePicker(for url: URL) {
        let picker = NSSharingServicePicker(items: [url])

        // Get the current mouse location in screen coordinates
        let mouseLocation = NSEvent.mouseLocation

        // Find the window under the mouse
        guard let window = NSApp.windows.first(where: { window in
            window.isVisible && window.frame.contains(mouseLocation)
        }) else {
            // Fallback: use key window
            guard let keyWindow = NSApp.keyWindow,
                  let contentView = keyWindow.contentView
            else { return }
            let windowPoint = keyWindow.convertPoint(fromScreen: mouseLocation)
            let rect = NSRect(origin: windowPoint, size: CGSize(width: 1, height: 1))
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
            return
        }

        // Convert screen coordinates to window coordinates
        let windowPoint = window.convertPoint(fromScreen: mouseLocation)

        // Find the view at this point, or use contentView as fallback
        guard let contentView = window.contentView else { return }
        let targetView = contentView.hitTest(windowPoint) ?? contentView

        // Convert the point to the target view's coordinate system
        let viewPoint = targetView.convert(windowPoint, from: nil)
        let rect = NSRect(origin: viewPoint, size: CGSize(width: 1, height: 1))

        picker.show(relativeTo: rect, of: targetView, preferredEdge: .minY)
    }

    /// Creates a share menu item for a song.
    @ViewBuilder
    static func menuItem(for song: Song) -> some View {
        if let url = song.shareURL {
            Button {
                self.showSharePicker(for: url)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Creates a share menu item for a playlist.
    @ViewBuilder
    static func menuItem(for playlist: Playlist) -> some View {
        if let url = playlist.shareURL {
            Button {
                self.showSharePicker(for: url)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Creates a share menu item for an album.
    /// Only shows if the album has a navigable ID.
    @ViewBuilder
    static func menuItem(for album: Album) -> some View {
        if let url = album.shareURL {
            Button {
                self.showSharePicker(for: url)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Creates a share menu item for an artist.
    /// Only shows if the artist has a valid YouTube channel ID.
    @ViewBuilder
    static func menuItem(for artist: Artist) -> some View {
        if let url = artist.shareURL {
            Button {
                self.showSharePicker(for: url)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Creates a share menu item for a podcast show.
    /// Only shows if the show has a navigable ID.
    @ViewBuilder
    static func menuItem(for podcastShow: PodcastShow) -> some View {
        if let url = podcastShow.shareURL {
            Button {
                self.showSharePicker(for: url)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Creates a share menu item for a HomeSectionItem.
    @ViewBuilder
    static func menuItem(for item: HomeSectionItem) -> some View {
        switch item {
        case let .song(song):
            Self.menuItem(for: song)
        case let .album(album):
            Self.menuItem(for: album)
        case let .playlist(playlist):
            Self.menuItem(for: playlist)
        case let .artist(artist):
            Self.menuItem(for: artist)
        }
    }

    /// Creates a share menu item for a SearchResultItem.
    @ViewBuilder
    static func menuItem(for item: SearchResultItem) -> some View {
        switch item {
        case let .song(song):
            Self.menuItem(for: song)
        case let .album(album):
            Self.menuItem(for: album)
        case let .playlist(playlist):
            Self.menuItem(for: playlist)
        case let .artist(artist):
            Self.menuItem(for: artist)
        case let .podcastShow(show):
            Self.menuItem(for: show)
        }
    }

    /// Creates a share menu item for a FavoriteItem.
    @ViewBuilder
    static func menuItem(for item: FavoriteItem) -> some View {
        switch item.itemType {
        case let .song(song):
            Self.menuItem(for: song)
        case let .album(album):
            Self.menuItem(for: album)
        case let .playlist(playlist):
            Self.menuItem(for: playlist)
        case let .artist(artist):
            Self.menuItem(for: artist)
        case let .podcastShow(show):
            Self.menuItem(for: show)
        }
    }
}
