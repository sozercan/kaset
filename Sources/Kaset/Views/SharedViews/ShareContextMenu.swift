import AppKit
import SwiftUI

@MainActor
enum ShareContextMenu {
    private static let pickerDelegate = CopyLinkSharingPickerDelegate()

    static func showSharePicker(for url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = Self.pickerDelegate

        let mouseLocation = NSEvent.mouseLocation

        guard let window = NSApp.windows.first(where: { window in
            window.isVisible && window.frame.contains(mouseLocation)
        }) else {
            guard let keyWindow = NSApp.keyWindow,
                  let contentView = keyWindow.contentView
            else { return }
            let windowPoint = keyWindow.convertPoint(fromScreen: mouseLocation)
            let rect = NSRect(origin: windowPoint, size: CGSize(width: 1, height: 1))
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
            return
        }

        let windowPoint = window.convertPoint(fromScreen: mouseLocation)

        guard let contentView = window.contentView else { return }
        let targetView = contentView.hitTest(windowPoint) ?? contentView

        let viewPoint = targetView.convert(windowPoint, from: nil)
        let rect = NSRect(origin: viewPoint, size: CGSize(width: 1, height: 1))

        picker.show(relativeTo: rect, of: targetView, preferredEdge: .minY)
    }

    @ViewBuilder
    static func menuItem(for song: Song) -> some View {
        if let url = song.shareURL {
            Button {
                self.showSharePicker(for: url)
            } label: {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder
    static func menuItem(for playlist: Playlist) -> some View {
        if let url = playlist.shareURL {
            Button {
                self.showSharePicker(for: url)
            } label: {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder
    static func menuItem(for album: Album) -> some View {
        if let url = album.shareURL {
            Button {
                self.showSharePicker(for: url)
            } label: {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder
    static func menuItem(for artist: Artist) -> some View {
        if let url = artist.shareURL {
            Button {
                self.showSharePicker(for: url)
            } label: {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder
    static func menuItem(for podcastShow: PodcastShow) -> some View {
        if let url = podcastShow.shareURL {
            Button {
                self.showSharePicker(for: url)
            } label: {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
            }
        }
    }

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

    @ViewBuilder
    static func menuItem(for item: SearchResultItem) -> some View {
        switch item {
        case let .song(song), let .video(song):
            Self.menuItem(for: song)
        case let .album(album), let .audiobook(album):
            Self.menuItem(for: album)
        case let .playlist(playlist):
            Self.menuItem(for: playlist)
        case let .artist(artist), let .profile(artist):
            Self.menuItem(for: artist)
        case let .podcastShow(show):
            Self.menuItem(for: show)
        case let .podcastEpisode(episode):
            Self.menuItem(for: episode.playbackSong)
        }
    }

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

final class CopyLinkSharingPickerDelegate: NSObject, NSSharingServicePickerDelegate {
    func sharingServicePicker(
        _: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices proposedServices: [NSSharingService]
    ) -> [NSSharingService] {
        let title = String(localized: "Copy Link")
        guard let url = items.lazy.compactMap({ $0 as? URL }).first,
              !proposedServices.contains(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame })
        else { return proposedServices }

        let copyLink = NSSharingService(
            title: title,
            image: NSImage(systemSymbolName: "link", accessibilityDescription: title) ?? NSImage(),
            alternateImage: nil
        ) {
            Self.copy(url, to: .general)
        }
        return [copyLink] + proposedServices
    }

    static func copy(_ url: URL, to pasteboard: NSPasteboard) {
        let link = url.absoluteString
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        pasteboard.setString(link, forType: .URL)
    }
}
