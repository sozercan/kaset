import SwiftUI

// MARK: - MoodCategoryDetailView

/// Detail view for a moods/genres category page.
/// Displays sections of songs and playlists for the selected mood/genre.
/// Note: This view is pushed onto an existing NavigationStack, so it uses NavigationLink
/// to leverage the parent's navigation context.
@available(macOS 26.0, *)
struct MoodCategoryDetailView: View {
    @State var viewModel: MoodCategoryViewModel
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView("Loading \(self.viewModel.category.title)...")
            case .loaded, .loadingMore:
                self.contentView
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.refresh() }
                }
            }
        }
        .navigationTitle(self.viewModel.category.title)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {} else {
                PlayerBar()
            }
        }
        .onAppear {
            if self.viewModel.loadingState == .idle {
                Task {
                    await self.viewModel.load()
                }
            }
        }
        .refreshable {
            await self.viewModel.refresh()
        }
    }

    // MARK: - Views

    private var contentView: some View {
        Group {
            if self.viewModel.sections.isEmpty {
                ContentUnavailableView(
                    "No Content Available",
                    systemImage: "music.note",
                    description: Text("No songs or playlists found in this category.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        ForEach(self.viewModel.sections) { section in
                            self.sectionView(section)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
        }
    }

    private func sectionView(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { _, item in
                        self.itemView(item)
                    }
                }
            }
        }
    }

    /// Creates navigation-aware item views.
    /// Songs use Button (play action), other items use NavigationLink.
    @ViewBuilder
    private func itemView(_ item: HomeSectionItem) -> some View {
        switch item {
        case let .song(song):
            // Songs play directly
            HomeSectionItemCard(item: item) {
                Task {
                    await self.playerService.playWithRadio(song: song)
                }
            }
        case let .playlist(playlist):
            // Playlists navigate using NavigationLink
            if MoodCategory.isMoodCategory(playlist.id),
               let parsed = MoodCategory.parseId(playlist.id)
            {
                let category = MoodCategory(
                    browseId: parsed.browseId,
                    params: parsed.params,
                    title: playlist.title
                )
                NavigationLink(value: category) {
                    ItemCardContent(item: item)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: playlist) {
                    ItemCardContent(item: item)
                }
                .buttonStyle(.plain)
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
            NavigationLink(value: playlist) {
                ItemCardContent(item: item)
            }
            .buttonStyle(.plain)
        case let .artist(artist):
            NavigationLink(value: artist) {
                ItemCardContent(item: item)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - ItemCardContent

/// A non-button card view for use inside NavigationLink.
@available(macOS 26.0, *)
private struct ItemCardContent: View {
    let item: HomeSectionItem

    private static let cardWidth: CGFloat = 160
    private static let cardHeight: CGFloat = 160

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.thumbnail
            self.titleAndSubtitle
        }
        .scaleEffect(self.isHovering ? 1.02 : 1.0)
        .shadow(
            color: self.isHovering ? .black.opacity(0.15) : .clear,
            radius: self.isHovering ? 12 : 0,
            x: 0,
            y: self.isHovering ? 4 : 0
        )
        .animation(.spring(duration: 0.2), value: self.isHovering)
        .onHover { hovering in
            self.isHovering = hovering
        }
    }

    private var thumbnail: some View {
        ZStack {
            if let url = self.item.thumbnailURL?.highQualityThumbnailURL {
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
    }

    private var placeholderView: some View {
        let gradient = Self.gradientForTitle(self.item.title)
        return Rectangle()
            .fill(gradient)
            .overlay {
                Image(systemName: self.placeholderIcon)
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.8))
            }
    }

    private var placeholderIcon: String {
        switch self.item {
        case .song: "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .artist: "person.fill"
        }
    }

    private static func gradientForTitle(_ title: String) -> LinearGradient {
        let hash = abs(title.hashValue)
        let hue1 = Double(hash % 360) / 360.0
        let hue2 = (hue1 + 0.1).truncatingRemainder(dividingBy: 1.0)
        let color1 = Color(hue: hue1, saturation: 0.6, brightness: 0.5)
        let color2 = Color(hue: hue2, saturation: 0.7, brightness: 0.35)
        return LinearGradient(colors: [color1, color2], startPoint: .topLeading, endPoint: .bottomTrailing)
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
