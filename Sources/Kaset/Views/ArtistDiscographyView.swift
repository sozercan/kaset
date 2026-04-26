import SwiftUI

/// View displaying an artist's full discography behind an Albums-shelf "See all".
@available(macOS 26.0, *)
struct ArtistDiscographyView: View {
    @State var viewModel: ArtistDiscographyViewModel

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                if self.viewModel.albums.isEmpty {
                    LoadingView(String(localized: "Loading discography..."))
                } else {
                    self.gridView
                }
            case .loaded, .loadingMore:
                self.gridView
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .navigationTitle(self.viewModel.destination.sectionTitle)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {} else {
                PlayerBar()
            }
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 16)],
                spacing: 20
            ) {
                ForEach(self.viewModel.albums) { album in
                    NavigationLink(value: self.playlistFromAlbum(album)) {
                        self.albumCard(album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
    }

    private func playlistFromAlbum(_ album: Album) -> Playlist {
        Playlist(
            id: album.id,
            title: album.title,
            description: nil,
            thumbnailURL: album.thumbnailURL,
            trackCount: album.trackCount,
            author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
        )
    }

    private func albumCard(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: album.thumbnailURL?.highQualityThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "square.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 160, height: 160)
            .clipShape(.rect(cornerRadius: 8))

            Text(album.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 160, alignment: .leading)

            if let year = album.year {
                Text(year)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .leading)
            }
        }
    }
}
