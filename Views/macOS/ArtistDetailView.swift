import SwiftUI

/// Detail view for an artist showing their songs and albums.
@available(macOS 26.0, *)
struct ArtistDetailView: View {
    let artist: Artist
    @State var viewModel: ArtistDetailViewModel
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView("Loading artist...")
            case .loaded, .loadingMore:
                if let detail = viewModel.artistDetail {
                    self.contentView(detail)
                } else {
                    ErrorView(title: "Unable to load artist", message: "Artist not found") {
                        Task { await self.viewModel.load() }
                    }
                }
            case let .error(message):
                ErrorView(title: "Unable to load artist", message: message) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .accentBackground(from: self.viewModel.artistDetail?.thumbnailURL?.highQualityThumbnailURL)
        .navigationTitle(self.artist.name)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
        }
        .refreshable {
            await self.viewModel.refresh()
        }
    }

    // MARK: - Views

    private func contentView(_ detail: ArtistDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                self.headerView(detail)

                Divider()

                // Songs section
                if !detail.songs.isEmpty {
                    self.songsSection()
                }

                // Albums section
                if !detail.albums.isEmpty {
                    self.albumsSection(detail.albums)
                }
            }
            .padding(24)
        }
    }

    private func headerView(_ detail: ArtistDetail) -> some View {
        HStack(alignment: .top, spacing: 20) {
            // Thumbnail
            CachedAsyncImage(url: detail.thumbnailURL?.highQualityThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 180, height: 180)
            .clipShape(.circle)

            // Info
            VStack(alignment: .leading, spacing: 8) {
                Text("Artist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(detail.name)
                    .font(.title)
                    .fontWeight(.bold)

                // Subscriber count
                if let subscriberCount = detail.subscriberCount {
                    Text(subscriberCount)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let description = detail.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Spacer()

                HStack(spacing: 12) {
                    // Shuffle button
                    Button {
                        self.shuffleAll(detail.songs)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(detail.songs.isEmpty)

                    // Play all button (Mix)
                    Button {
                        self.playAll(detail.songs)
                    } label: {
                        Label("Mix", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(detail.songs.isEmpty)

                    // Subscribe button
                    if detail.channelId != nil {
                        self.subscribeButton(detail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Returns the text for the subscribe button.
    private func subscribeButtonText(_ detail: ArtistDetail) -> String {
        if detail.isSubscribed {
            return "Subscribed"
        }
        // Format subscriber count (e.g., "Subscribe 34.6M")
        if let count = detail.subscriberCount {
            // Extract just the number part if it contains "subscribers"
            let numberPart = count
                .replacingOccurrences(of: " subscribers", with: "")
                .replacingOccurrences(of: " subscriber", with: "")
            return "Subscribe \(numberPart)"
        }
        return "Subscribe"
    }

    @ViewBuilder
    private func subscribeButton(_ detail: ArtistDetail) -> some View {
        if detail.isSubscribed {
            Button {
                Task {
                    await self.viewModel.toggleSubscription()
                }
            } label: {
                if self.viewModel.isSubscribing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(self.subscribeButtonText(detail))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(self.viewModel.isSubscribing)
        } else {
            Button {
                Task {
                    await self.viewModel.toggleSubscription()
                }
            } label: {
                if self.viewModel.isSubscribing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(self.subscribeButtonText(detail))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(self.viewModel.isSubscribing)
        }
    }

    private func songsSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top songs")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                // See all button - navigates to full top songs view
                if self.viewModel.hasMoreSongs, let detail = viewModel.artistDetail {
                    NavigationLink(value: TopSongsDestination(
                        artistId: detail.id,
                        artistName: detail.name,
                        songs: detail.songs,
                        songsBrowseId: detail.songsBrowseId,
                        songsParams: detail.songsParams
                    )) {
                        Text("See all")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.accent)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(self.viewModel.displayedSongs.enumerated()), id: \.element.id) { index, song in
                    self.topSongRow(song, index: index)

                    if index < self.viewModel.displayedSongs.count - 1 {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
        }
    }

    /// Song row for top songs section - fetches all songs and plays as queue.
    private func topSongRow(_ song: Song, index: Int) -> some View {
        Button {
            // Fetch all songs and play as queue starting from the selected song
            Task {
                let allSongs = await self.viewModel.getAllSongs()
                // Find the index of the selected song in the full list
                let startIndex = allSongs.firstIndex(where: { $0.videoId == song.videoId }) ?? index
                await self.playerService.playQueue(allSongs, startingAt: startIndex)
            }
        } label: {
            HStack(spacing: 12) {
                // Thumbnail
                CachedAsyncImage(url: song.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                }
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 4))

                // Title
                Text(song.title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Artist column
                Text(song.artistsDisplay)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)

                // Album column (if available)
                if let album = song.album {
                    Text(album.title)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                } else {
                    Text("")
                        .frame(width: 150, alignment: .leading)
                }

                // Duration
                Text(song.durationDisplay)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func albumsSection(_ albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Albums")
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: self.playlistFromAlbum(album)) {
                            self.albumCard(album)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func playlistFromAlbum(_ album: Album) -> Playlist {
        Playlist(
            id: album.id,
            title: album.title,
            description: nil,
            thumbnailURL: album.thumbnailURL,
            trackCount: album.trackCount,
            author: album.artistsDisplay
        )
    }

    private func albumCard(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail
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
            .frame(width: 140, height: 140)
            .clipShape(.rect(cornerRadius: 8))

            // Title
            Text(album.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 140, alignment: .leading)

            // Year
            if let year = album.year {
                Text(year)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
            }
        }
    }

    // MARK: - Actions

    private func playAll(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        Task {
            await self.playerService.playQueue(songs, startingAt: 0)
        }
    }

    private func shuffleAll(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        Task {
            let shuffledSongs = songs.shuffled()
            await self.playerService.playQueue(shuffledSongs, startingAt: 0)
        }
    }
}

#Preview {
    let artist = Artist(
        id: "test",
        name: "Test Artist",
        thumbnailURL: nil
    )
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    ArtistDetailView(
        artist: artist,
        viewModel: ArtistDetailViewModel(
            artist: artist,
            client: client
        )
    )
    .environment(PlayerService())
}
