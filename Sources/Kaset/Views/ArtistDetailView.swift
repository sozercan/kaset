// swiftlint:disable file_length

import SwiftUI

/// Detail view for an artist showing their songs and albums.
@available(macOS 26.0, *)
struct ArtistDetailView: View { // swiftlint:disable:this type_body_length
    let artist: Artist
    @State var viewModel: ArtistDetailViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView(String(localized: "Loading artist..."))
            case .loaded, .loadingMore:
                if let detail = viewModel.artistDetail {
                    self.contentView(detail)
                } else {
                    ErrorView(title: String(localized: "Unable to load artist"), message: String(localized: "Artist not found")) {
                        Task { await self.viewModel.load() }
                    }
                }
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .accentBackground(from: self.viewModel.artistDetail?.thumbnailURL?.highQualityThumbnailURL)
        .navigationTitle(self.artist.name)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .topFade()
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

                // Latest episodes (includes live radio streams). Episodes are
                // kept out of orderedSections because they use their own card
                // layout and route.
                if !detail.episodes.isEmpty {
                    self.episodesSection(detail.episodes)
                }

                if !detail.orderedSections.isEmpty {
                    ForEach(detail.orderedSections) { section in
                        switch section.content {
                        case let .albums(albums):
                            self.albumsSection(
                                albums,
                                title: section.title,
                                shelfKind: self.albumShelfKind(for: section.title)
                            )
                        case let .artists(artists):
                            self.artistsSection(artists, title: section.title)
                        case let .playlists(playlists):
                            self.playlistsSection(playlists, title: section.title)
                        }
                    }
                } else {
                    // Fallback for older/parser-test ArtistDetail values that do
                    // not populate orderedSections.
                    if !detail.albums.isEmpty {
                        self.albumsSection(detail.albums)
                    }

                    if !detail.singles.isEmpty {
                        self.singlesSection(detail.singles)
                    }

                    if !detail.playlistsByArtist.isEmpty {
                        self.playlistsByArtistSection(detail.playlistsByArtist)
                    }

                    if !detail.relatedArtists.isEmpty {
                        self.relatedArtistsSection(detail.relatedArtists)
                    }
                }

                // Podcast shows owned by this artist.
                if !detail.podcasts.isEmpty {
                    self.podcastsSection(detail.podcasts)
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
                if let headerTypeLabel = self.headerTypeLabel(for: detail) {
                    Text(headerTypeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }

                Text(detail.name)
                    .font(.title)
                    .fontWeight(.bold)

                if let monthlyAudience = detail.monthlyAudience {
                    Text(monthlyAudience)
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
                    if detail.profileKind == .artist {
                        // Shuffle button - shuffles all artist's songs (fetches if needed)
                        Button {
                            Task {
                                await self.shuffleAllSongs()
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(detail.songs.isEmpty && !detail.hasMoreSongs)
                    }

                    // Mix button - plays personalized radio with mix of artists
                    // Only shown if mix data is available from the API
                    // Passing nil for startVideoId lets the API pick a random starting point on the server
                    // in addition to client-side shuffling applied when the mix tracks are played
                    if let mixPlaylistId = detail.mixPlaylistId {
                        Button {
                            self.playMix(playlistId: mixPlaylistId, startVideoId: nil)
                        } label: {
                            Label("Mix", systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

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
        let baseText = detail.isSubscribed
            ? (detail.subscribedButtonText ?? String(localized: "Subscribed"))
            : (detail.unsubscribedButtonText ?? String(localized: "Subscribe"))

        if let subscriberCount = detail.subscriberCount, !subscriberCount.isEmpty {
            return "\(baseText) \(subscriberCount)"
        }
        return baseText
    }

    private func headerTypeLabel(for detail: ArtistDetail) -> String? {
        switch detail.profileKind {
        case .artist:
            String(localized: "Artist")
        case .profile:
            String(localized: "Profile")
        case .unknown:
            nil
        }
    }

    @ViewBuilder
    private func subscribeButton(_ detail: ArtistDetail) -> some View {
        if detail.isSubscribed {
            Button {
                HapticService.toggle()
                Task {
                    await self.viewModel.toggleSubscription()
                }
            } label: {
                if self.viewModel.isSubscribing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Text(self.subscribeButtonText(detail))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(self.viewModel.isSubscribing)
        } else {
            Button {
                HapticService.toggle()
                Task {
                    await self.viewModel.toggleSubscription()
                }
            } label: {
                if self.viewModel.isSubscribing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Text(self.subscribeButtonText(detail))
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(self.viewModel.isSubscribing)
        }
    }

    private func songsSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(self.viewModel.artistDetail?.songsSectionTitle ?? String(localized: "Top songs"))
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                // See all button - navigates to full top songs view
                if self.viewModel.hasMoreSongs, let detail = viewModel.artistDetail {
                    NavigationLink(value: TopSongsDestination(
                        artistId: detail.id,
                        artistName: detail.name,
                        title: detail.songsSectionTitle ?? String(localized: "Top songs"),
                        songs: detail.songs,
                        songsBrowseId: detail.songsBrowseId,
                        songsParams: detail.songsParams
                    )) {
                        Text("See all")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(self.viewModel.displayedSongs.enumerated()), id: \.offset) { index, song in
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
        HoverObservingRow { isHovered in
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
                    SongThumbnailView(song: song, size: 40, cornerRadius: 4)

                    // Title (with optional explicit badge)
                    HStack(spacing: 6) {
                        Text(song.title)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if song.isExplicit == true {
                            ExplicitBadge()
                        }
                    }
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

                    // Favorite toggle
                    FavoriteHeartButton(song: song, isRowHovered: isHovered)

                    // Duration
                    Text(song.durationDisplay)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button {
                Task {
                    let allSongs = await self.viewModel.getAllSongs()
                    let startIndex = allSongs.firstIndex(where: { $0.videoId == song.videoId }) ?? index
                    await self.playerService.playQueue(allSongs, startingAt: startIndex)
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: song, manager: self.favoritesManager)

            Divider()

            LikeDislikeContextMenu(song: song, likeStatusManager: self.likeStatusManager)

            Divider()

            StartRadioContextMenu.menuItem(for: song, playerService: self.playerService)

            Divider()

            Button {
                SongActionsHelper.addToLibrary(song, playerService: self.playerService)
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }

            Divider()

            ShareContextMenu.menuItem(for: song)

            Divider()

            AddToQueueContextMenu(song: song, playerService: self.playerService)

            Divider()

            AddToPlaylistContextMenu(song: song, client: self.viewModel.client)

            // Go to Album - show if album has valid browse ID
            if let album = song.album, album.hasNavigableId {
                Divider()

                let playlist = Playlist(
                    id: album.id,
                    title: album.title,
                    description: nil,
                    thumbnailURL: album.thumbnailURL ?? song.thumbnailURL,
                    trackCount: album.trackCount,
                    author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
                )
                NavigationLink(value: playlist) {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
        }
    }

    private func albumsSection(
        _ albums: [Album],
        title: String = "Albums",
        shelfKind: ArtistShelfKind = .albums
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            self.sectionHeader(title: title, shelfKind: shelfKind)

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

    private func playlistsSection(_ playlists: [Playlist], title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            self.sectionHeader(title: title, shelfKind: .playlistsByArtist)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: playlist) {
                            self.playlistCard(playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func artistsSection(_ artists: [Artist], title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            self.sectionHeader(title: title, shelfKind: .relatedArtists)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(artists) { artist in
                        NavigationLink(value: artist) {
                            self.artistCard(artist)
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
            author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
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

    private func playlistCard(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: playlist.thumbnailURL?.highQualityThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 140, height: 140)
            .clipShape(.rect(cornerRadius: 8))

            Text(playlist.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 140, alignment: .leading)

            if let authorName = playlist.author?.name, !authorName.isEmpty {
                Text(authorName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            } else if let trackCount = playlist.trackCount {
                Text(trackCount == 1 ? "1 song" : "\(trackCount) songs")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
            }
        }
    }

    private func artistCard(_ artist: Artist) -> some View {
        VStack(alignment: .center, spacing: 8) {
            CachedAsyncImage(url: artist.thumbnailURL?.highQualityThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 140, height: 140)
            .clipShape(.circle)

            Text(artist.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 140, alignment: .center)

            if let subtitle = artist.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 140, alignment: .center)
            }
        }
    }

    // MARK: - Actions

    private func playMix(playlistId: String, startVideoId: String?) {
        Task {
            await self.playerService.playWithMix(playlistId: playlistId, startVideoId: startVideoId)
        }
    }

    private func playAll(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        Task {
            await self.playerService.playQueue(songs, startingAt: 0)
        }
    }

    /// Fetches all artist songs and plays them shuffled.
    private func shuffleAllSongs() async {
        let allSongs = await self.viewModel.getAllSongs()
        guard !allSongs.isEmpty else { return }
        let shuffledSongs = allSongs.shuffled()
        await self.playerService.playQueue(shuffledSongs, startingAt: 0)
    }

    // MARK: - Episodes Section (Latest episodes / live radios)

    private func episodesSection(_ episodes: [ArtistEpisode]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            self.sectionHeader(title: "Latest episodes", shelfKind: .episodes)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(episodes) { episode in
                        Button {
                            Task {
                                await self.playerService.playEpisode(episode)
                            }
                        } label: {
                            self.episodeCard(episode)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func episodeCard(_ episode: ArtistEpisode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                CachedAsyncImage(url: episode.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "play.rectangle")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 220, height: 124)
                .clipShape(.rect(cornerRadius: 8))

                if episode.isLive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                        Text("LIVE", comment: "Live badge on artist episode card")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .tracking(0.5)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red, in: .capsule)
                    .padding(8)
                }
            }

            Text(episode.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 220, alignment: .leading)

            if let subtitle = episode.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
            }
        }
    }

    // MARK: - Singles & EPs Section

    private func singlesSection(_ singles: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            self.sectionHeader(title: "Singles & EPs", shelfKind: .singles)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(singles) { album in
                        NavigationLink(value: self.playlistFromAlbum(album)) {
                            self.albumCard(album)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Playlists by Artist Section

    private func playlistsByArtistSection(_ playlists: [Playlist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            self.sectionHeader(title: "Playlists", shelfKind: .playlistsByArtist)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: playlist) {
                            VStack(alignment: .leading, spacing: 8) {
                                CachedAsyncImage(url: playlist.thumbnailURL?.highQualityThumbnailURL) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle()
                                        .fill(.quaternary)
                                        .overlay {
                                            Image(systemName: "music.note.list")
                                                .font(.largeTitle)
                                                .foregroundStyle(.secondary)
                                        }
                                }
                                .frame(width: 140, height: 140)
                                .clipShape(.rect(cornerRadius: 8))

                                Text(playlist.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(width: 140, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Podcasts Section

    private func podcastsSection(_ podcasts: [PodcastShow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            self.sectionHeader(title: "Podcasts", shelfKind: .podcasts)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(podcasts) { show in
                        NavigationLink(value: show) {
                            self.podcastCard(show)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func podcastCard(_ show: PodcastShow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: show.thumbnailURL?.highQualityThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "mic")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 140, height: 140)
            .clipShape(.rect(cornerRadius: 8))

            Text(show.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 140, alignment: .leading)
        }
    }

    // MARK: - Related Artists Section

    private func relatedArtistsSection(_ artists: [Artist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            self.sectionHeader(title: "Fans might also like", shelfKind: .relatedArtists)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(artists) { artist in
                        NavigationLink(value: artist) {
                            self.relatedArtistCard(artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func relatedArtistCard(_ artist: Artist) -> some View {
        VStack(alignment: .center, spacing: 8) {
            CachedAsyncImage(url: artist.thumbnailURL?.highQualityThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 120, height: 120)
            .clipShape(.circle)

            Text(artist.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 120, alignment: .center)
        }
    }

    private func albumShelfKind(for title: String) -> ArtistShelfKind {
        let lowercasedTitle = title.lowercased()
        return lowercasedTitle.contains("single")
            || lowercasedTitle.contains(" ep")
            || lowercasedTitle.hasPrefix("ep")
            ? .singles
            : .albums
    }

    // MARK: - Section Header with Optional See-all

    private func sectionHeader(title: String, shelfKind: ArtistShelfKind) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            if let detail = viewModel.artistDetail,
               let more = detail.moreEndpoints[shelfKind]
            {
                self.seeAllLink(more: more, sectionTitle: title, artistName: detail.name)
            }
        }
    }

    @ViewBuilder
    private func seeAllLink(
        more: ShelfMoreEndpoint,
        sectionTitle: String,
        artistName: String
    ) -> some View {
        switch more.pageType {
        case .playlist:
            // Playlist-backed See-all destinations reuse the existing
            // `Playlist` navigation route so `PlaylistDetailView` can render
            // the full list.
            NavigationLink(value: Playlist(
                id: more.browseId,
                title: sectionTitle,
                description: nil,
                thumbnailURL: nil,
                trackCount: nil,
                author: Artist.inline(name: artistName, namespace: "playlist-author")
            )) {
                Text("See all").font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        case .artist, .discography:
            NavigationLink(value: ArtistSeeAllDestination(
                artistName: artistName,
                sectionTitle: sectionTitle,
                endpoint: more
            )) {
                Text("See all").font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
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
