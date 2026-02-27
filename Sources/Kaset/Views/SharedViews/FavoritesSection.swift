import SwiftUI
import UniformTypeIdentifiers

// MARK: - FavoritesSection

/// A horizontal scrolling section displaying pinned Favorites items.
/// Supports drag-and-drop reordering and context menu actions.
@available(macOS 26.0, *)
struct FavoritesSection: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @State private var draggedItem: FavoriteItem?
    @State private var navigationPath: NavigationPath?

    /// Binding to navigation path for navigation within the section.
    var onNavigate: ((any Hashable) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorites")
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(self.favoritesManager.items) { item in
                        FavoriteItemCard(
                            item: item,
                            onTap: { self.handleTap(item) }
                        )
                        .draggable(item) {
                            // Drag preview
                            FavoriteItemCard(item: item, onTap: {})
                                .opacity(0.8)
                        }
                        .dropDestination(for: FavoriteItem.self) { droppedItems, _ in
                            self.handleDrop(droppedItems, on: item)
                        }
                        .contextMenu {
                            self.contextMenu(for: item)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Favorites")
    }

    // MARK: - Actions

    private func handleTap(_ item: FavoriteItem) {
        switch item.itemType {
        case let .song(song):
            Task {
                await self.playerService.playWithRadio(song: song)
            }
        case let .album(album):
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: album.artistsDisplay
            )
            self.onNavigate?(playlist)
        case let .playlist(playlist):
            self.onNavigate?(playlist)
        case let .artist(artist):
            self.onNavigate?(artist)
        case let .podcastShow(show):
            self.onNavigate?(show)
        }
    }

    private func handleDrop(_ droppedItems: [FavoriteItem], on target: FavoriteItem) -> Bool {
        guard let droppedItem = droppedItems.first,
              let sourceIndex = favoritesManager.items.firstIndex(of: droppedItem),
              let targetIndex = favoritesManager.items.firstIndex(of: target),
              sourceIndex != targetIndex
        else {
            return false
        }

        // Calculate the proper destination index
        let destinationIndex = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        self.favoritesManager.move(from: IndexSet(integer: sourceIndex), to: destinationIndex)
        return true
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for item: FavoriteItem) -> some View {
        // Play button for songs
        if case let .song(song) = item.itemType {
            Button {
                Task { await self.playerService.play(song: song) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Divider()
        }

        // View button for albums/playlists/artists/podcasts
        switch item.itemType {
        case .album:
            Button {
                self.handleTap(item)
            } label: {
                Label("View Album", systemImage: "square.stack")
            }

            Divider()
        case .playlist:
            Button {
                self.handleTap(item)
            } label: {
                Label("View Playlist", systemImage: "music.note.list")
            }

            Divider()
        case .artist:
            Button {
                self.handleTap(item)
            } label: {
                Label("View Artist", systemImage: "person")
            }

            Divider()
        case .podcastShow:
            Button {
                self.handleTap(item)
            } label: {
                Label("View Podcast", systemImage: "mic.fill")
            }

            Divider()
        case .song:
            // Songs don't need a "View" button, they play on tap
            EmptyView()
        }

        // Reorder actions
        Button {
            self.favoritesManager.moveToTop(contentId: item.contentId)
        } label: {
            Label("Move to Top", systemImage: "arrow.up.to.line")
        }

        Button {
            self.favoritesManager.moveToEnd(contentId: item.contentId)
        } label: {
            Label("Move to End", systemImage: "arrow.down.to.line")
        }

        Divider()

        // Remove action
        Button(role: .destructive) {
            self.favoritesManager.remove(contentId: item.contentId)
        } label: {
            Label("Remove from Favorites", systemImage: "heart.slash")
        }

        Divider()

        ShareContextMenu.menuItem(for: item)

        // Add to Queue for songs
        if case let .song(song) = item.itemType {
            Divider()
            AddToQueueContextMenu(song: song, playerService: self.playerService)
        }

        Divider()

        // Navigation to related content
        switch item.itemType {
        case let .song(song):
            if let artist = song.artists.first(where: { $0.hasNavigableId }) {
                Button {
                    self.onNavigate?(artist)
                } label: {
                    Label("Go to Artist", systemImage: "person")
                }
            }

            if let album = song.album, album.hasNavigableId {
                let playlist = Playlist(
                    id: album.id,
                    title: album.title,
                    description: nil,
                    thumbnailURL: album.thumbnailURL ?? song.thumbnailURL,
                    trackCount: album.trackCount,
                    author: album.artistsDisplay
                )
                Button {
                    self.onNavigate?(playlist)
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - FavoriteItemCard

/// A card view for a single Favorites item.
@available(macOS 26.0, *)
private struct FavoriteItemCard: View {
    let item: FavoriteItem
    let onTap: () -> Void

    private static let cardWidth: CGFloat = 160
    private static let cardHeight: CGFloat = 160

    @State private var isHovering = false

    var body: some View {
        Button(action: self.onTap) {
            VStack(alignment: .leading, spacing: 8) {
                self.thumbnail
                self.titleAndSubtitle
            }
        }
        .buttonStyle(.interactiveCard)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) {
                self.isHovering = hovering
            }
        }
        .accessibilityLabel("\(self.item.title), \(self.item.typeLabel), \(self.item.subtitle ?? "")")
        .accessibilityHint("Drag to reorder")
    }

    private var thumbnail: some View {
        ZStack {
            if let url = item.thumbnailURL?.highQualityThumbnailURL {
                CachedAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    self.placeholderView
                }
            } else {
                self.placeholderView
            }
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            // Play overlay on hover (for songs)
            if case .song = self.item.itemType, self.isHovering {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .offset(x: 2)
                    }
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var placeholderView: some View {
        Rectangle()
            .fill(Self.gradientForTitle(self.item.title))
            .overlay {
                Image(systemName: self.placeholderIcon)
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.8))
            }
    }

    private var placeholderIcon: String {
        switch self.item.itemType {
        case .song: "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .artist: "person.fill"
        case .podcastShow: "mic.fill"
        }
    }

    private static func gradientForTitle(_ title: String) -> LinearGradient {
        let hash = abs(title.hashValue)
        let hue1 = Double(hash % 360) / 360.0
        let hue2 = (hue1 + 0.1).truncatingRemainder(dividingBy: 1.0)

        let color1 = Color(hue: hue1, saturation: 0.6, brightness: 0.5)
        let color2 = Color(hue: hue2, saturation: 0.7, brightness: 0.35)

        return LinearGradient(
            colors: [color1, color2],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var titleAndSubtitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: Self.cardWidth, alignment: .leading)

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.cardWidth, alignment: .leading)
            }
        }
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    let manager = FavoritesManager(skipLoad: true)
    // Add some sample items for preview
    let song = Song(
        id: "test",
        title: "Test Song",
        artists: [Artist(id: "artist1", name: "Test Artist")],
        videoId: "test"
    )
    manager.add(.from(song))

    let album = Album(
        id: "MPRE123",
        title: "Test Album",
        artists: [Artist(id: "artist1", name: "Test Artist")],
        thumbnailURL: nil,
        year: "2024",
        trackCount: 12
    )
    manager.add(.from(album))

    return FavoritesSection()
        .environment(manager)
        .environment(PlayerService())
        .padding()
}
