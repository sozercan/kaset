import FoundationModels
import SwiftUI

// MARK: - PlaylistDetailView

/// Detail view for a playlist showing its tracks.
@available(macOS 26.0, *)
struct PlaylistDetailView: View {
    let playlist: Playlist
    @State var viewModel: PlaylistDetailViewModel
    @Environment(PlayerService.self) var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SidebarPinnedItemsManager.self) var sidebarPinnedItemsManager: SidebarPinnedItemsManager?
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(LibraryViewModel.self) var libraryViewModel: LibraryViewModel?
    @Environment(\.dismiss) var dismiss
    /// Tracks whether this playlist has been added to library in this session.
    @State var isAddedToLibrary: Bool = false
    /// Whether the refine playlist sheet is visible.
    @State var showRefineSheet: Bool = false
    /// AI-generated playlist changes.
    @State private var playlistChanges: PlaylistChanges?
    /// Partial playlist changes during streaming.
    @State private var partialChanges: PlaylistChanges.PartiallyGenerated?
    /// Whether AI is processing the refine request.
    @State private var isRefining: Bool = false
    /// Error message from refine operation.
    @State private var refineError: String?
    /// Computed property to check if playlist is in library.
    var isInLibrary: Bool {
        self.libraryViewModel?.isInLibrary(playlistId: self.playlist.id) ?? false
    }

    private let logger = DiagnosticsLogger.ai

    init(playlist: Playlist, viewModel: PlaylistDetailViewModel) {
        self.playlist = playlist
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView(String(localized: "Loading playlist..."))
            case .loaded, .loadingMore:
                if let detail = viewModel.playlistDetail {
                    self.contentView(detail)
                } else {
                    ErrorView(
                        title: String(localized: "Unable to load playlist"),
                        message: String(localized: "Playlist not found")
                    ) {
                        Task { await self.viewModel.load() }
                    }
                }
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .accentBackground(
            from: self.viewModel.playlistDetail?.thumbnailURL?.highQualityThumbnailURL
        )
        .navigationTitle(self.playlist.title)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {
            } else {
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
        .onChange(of: self.likeStatusManager.lastLikeEvent) { _, event in
            guard let event else { return }
            guard LikedMusicPlaylist.matches(id: self.playlist.id) else { return }
            self.viewModel.handleLikeStatusChange(event)
        }
        .sheet(isPresented: self.$showRefineSheet) {
            if let detail = viewModel.playlistDetail {
                RefinePlaylistSheet(
                    tracks: detail.tracks,
                    isProcessing: self.$isRefining,
                    changes: self.$playlistChanges,
                    partialChanges: self.$partialChanges,
                    errorMessage: self.$refineError,
                    onRefine: { prompt in
                        await self.refinePlaylist(tracks: detail.tracks, prompt: prompt)
                    },
                    onApply: {
                        // Playlist modification via API not yet implemented
                        // For now, just close the sheet
                        self.showRefineSheet = false
                    }
                )
            }
        }
    }

    // MARK: - Views

    private func contentView(_ detail: PlaylistDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                self.headerView(detail)

                Divider()

                // Tracks
                let fallbackAlbum = Album(
                    id: detail.id,
                    title: detail.title,
                    artists: detail.author.map { [$0] },
                    thumbnailURL: detail.thumbnailURL,
                    year: nil,
                    trackCount: detail.trackCount ?? detail.tracks.count
                )
                self.tracksView(
                    detail.tracks, isAlbum: detail.isAlbum, author: detail.author?.name,
                    fallbackAlbum: fallbackAlbum
                )
            }
            .padding(24)
        }
        .topFade(style: .contentMask)
    }

    private func headerView(_ detail: PlaylistDetail) -> some View {
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
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 180, height: 180)
            .clipShape(.rect(cornerRadius: 8))
            .fadeIn(duration: 0.3)

            // Info
            VStack(alignment: .leading, spacing: 8) {
                Text(self.contentKindText(for: detail))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(detail.title)
                    .font(.title)
                    .fontWeight(.bold)

                self.headerAuthorView(detail)

                Text(self.metadataText(for: detail))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Spacer(minLength: 24)

                self.headerButtons(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func headerAuthorView(_ detail: PlaylistDetail) -> some View {
        let artists = self.headerArtists(for: detail)

        if !artists.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                    Text(artist.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if index < artists.count - 1 {
                        Text(", ")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
        }
    }

    private func metadataText(for detail: PlaylistDetail) -> String {
        if let duration = detail.duration {
            return "\(detail.trackCountDisplay) • \(duration)"
        }

        return detail.trackCountDisplay
    }

    private func contentKindText(for detail: PlaylistDetail) -> String {
        if detail.isUploadedSongs {
            return String(localized: "Uploads")
        }
        return detail.isAlbum ? String(localized: "Album") : String(localized: "Playlist")
    }

    private func tracksView(
        _ tracks: [Song], isAlbum: Bool, author: String?, fallbackAlbum: Album? = nil
    ) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                self.trackRow(
                    track, index: index, tracks: tracks, isAlbum: isAlbum, author: author,
                    fallbackAlbum: fallbackAlbum
                )
                .onAppear {
                    // Load more when reaching the last few items
                    if index >= tracks.count - 3, self.viewModel.hasMore {
                        Task { await self.viewModel.loadMore() }
                    }
                }

                if index < tracks.count - 1 {
                    Divider()
                        // For albums: 28 (index) + 12 (spacing)
                        // For playlists: 28 (index) + 12 (spacing) + 40 (thumbnail) + 16 (spacing)
                        .padding(.leading, isAlbum ? 40 : 96)
                }
            }

            // Loading indicator for pagination
            if self.viewModel.loadingState == .loadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .padding()
                    Spacer()
                }
            }
        }
    }

    private func trackRow(
        _ track: Song, index: Int, tracks: [Song], isAlbum: Bool, author: String?,
        fallbackAlbum: Album? = nil
    ) -> some View {
        PlaylistTrackRow(
            track: track,
            index: index,
            isAlbum: isAlbum,
            subtitle: self.trackArtistsDisplay(for: track, fallbackAuthor: author),
            onPlay: {
                self.playTrackInQueue(
                    tracks: tracks, startingAt: index, fallbackArtist: author,
                    fallbackAlbum: fallbackAlbum
                )
            },
            menu: {
                self.trackContextMenu(
                    track,
                    index: index,
                    tracks: tracks,
                    author: author,
                    fallbackAlbum: fallbackAlbum
                )
            }
        )
        .staggeredAppearance(index: min(index, 10))
    }

    private func headerArtists(for detail: PlaylistDetail) -> [Artist] {
        if let author = self.cleanedArtist(detail.author) {
            return [author]
        }

        return self.uniqueArtists(from: detail.tracks.flatMap(\.artists))
    }

    private func trackArtistsDisplay(for track: Song, fallbackAuthor: String?) -> String? {
        let artists = self.uniqueArtists(from: track.artists)
        if !artists.isEmpty {
            return artists.map(\.name).joined(separator: ", ")
        }

        guard let fallbackArtist = self.cleanedArtistName(fallbackAuthor) else { return nil }
        return fallbackArtist
    }

    private func uniqueArtists(from artists: [Artist]) -> [Artist] {
        var seen = Set<String>()
        var uniqueArtists: [Artist] = []

        for artist in artists {
            guard let cleanedArtist = self.cleanedArtist(artist) else { continue }
            let key = cleanedArtist.hasNavigableId ? cleanedArtist.id : cleanedArtist.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            uniqueArtists.append(cleanedArtist)
        }

        return uniqueArtists
    }

    private func cleanedArtist(_ artist: Artist?) -> Artist? {
        guard let artist,
              let name = self.cleanedArtistName(artist.name)
        else { return nil }

        return Artist(
            id: artist.id,
            name: name,
            thumbnailURL: artist.thumbnailURL,
            subtitle: artist.subtitle,
            profileKind: artist.profileKind
        )
    }

    private func cleanedArtistName(_ name: String?) -> String? {
        guard var cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleanName.isEmpty
        else { return nil }

        if cleanName == "Album" {
            return nil
        }

        if cleanName.hasPrefix("Album, ") {
            cleanName = String(cleanName.dropFirst(7))
        } else if cleanName.contains("Album,") {
            let parts = cleanName.split(separator: ",", maxSplits: 1)
            if parts.count > 1 {
                cleanName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return cleanName.isEmpty ? nil : cleanName
    }

    // MARK: - Actions

    @ViewBuilder
    private func trackContextMenu(
        _ track: Song,
        index: Int,
        tracks: [Song],
        author: String?,
        fallbackAlbum: Album?
    ) -> some View {
        if track.isPlayable {
            Button {
                self.playTrackInQueue(
                    tracks: tracks,
                    startingAt: index,
                    fallbackArtist: author,
                    fallbackAlbum: fallbackAlbum
                )
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: track, manager: self.favoritesManager)

            Divider()

            LikeDislikeContextMenu(song: track, likeStatusManager: self.likeStatusManager)

            Divider()

            StartRadioContextMenu.menuItem(for: track, playerService: self.playerService)

            Divider()

            Button {
                SongActionsHelper.addToLibrary(track, playerService: self.playerService)
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }

            Divider()

            ShareContextMenu.menuItem(for: track)

            Divider()

            AddToQueueContextMenu(song: track, playerService: self.playerService)

            Divider()

            AddToPlaylistContextMenu(song: track, client: self.viewModel.client)

            Divider()

            if let artist = track.artists.first(where: { $0.hasNavigableId }) {
                NavigationLink(value: artist) {
                    Label("Go to Artist", systemImage: "person")
                }
            }

            if let album = track.album, album.hasNavigableId {
                let playlist = Playlist(
                    id: album.id,
                    title: album.title,
                    description: nil,
                    thumbnailURL: album.thumbnailURL ?? track.thumbnailURL,
                    trackCount: album.trackCount,
                    author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
                )
                NavigationLink(value: playlist) {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
        }
    }

    private func playTrackInQueue(
        tracks: [Song], startingAt index: Int, fallbackArtist: String? = nil,
        fallbackAlbum: Album? = nil
    ) {
        guard tracks.indices.contains(index), tracks[index].isPlayable else { return }

        let playableIndex = tracks[...index].filter(\.isPlayable).count - 1
        let cleanedTracks = self.playableTracks(
            tracks, fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
        Task {
            await self.playerService.playQueue(cleanedTracks, startingAt: playableIndex)
        }
    }

    func playAll(
        _ tracks: [Song], fallbackArtist: String? = nil, fallbackAlbum: Album? = nil
    ) {
        let cleanedTracks = self.playableTracks(
            tracks, fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
        guard !cleanedTracks.isEmpty else { return }
        Task {
            await self.playerService.playQueue(cleanedTracks, startingAt: 0)
        }
    }

    func playableTracks(
        _ tracks: [Song], fallbackArtist: String?, fallbackAlbum: Album? = nil
    ) -> [Song] {
        self.cleanTracks(
            tracks.filter(\.isPlayable), fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum
        )
    }

    /// Cleans track artists and applies fallback artist/album when needed.
    private func cleanTracks(_ tracks: [Song], fallbackArtist: String?, fallbackAlbum: Album? = nil)
        -> [Song]
    {
        tracks.map { song in
            var cleanedArtists = song.artists.compactMap { artist -> Artist? in
                if artist.name == "Album" { return nil }
                var cleanName = artist.name
                if cleanName.hasPrefix("Album, ") {
                    cleanName = String(cleanName.dropFirst(7))
                }
                return Artist(
                    id: artist.id,
                    name: cleanName,
                    thumbnailURL: artist.thumbnailURL,
                    subtitle: artist.subtitle,
                    profileKind: artist.profileKind
                )
            }

            // Use fallback artist if artists are empty (and clean the fallback too)
            if cleanedArtists.isEmpty, let fallback = fallbackArtist, !fallback.isEmpty {
                var cleanFallback = fallback
                if cleanFallback == "Album" {
                    cleanFallback = "Unknown Artist"
                } else if cleanFallback.hasPrefix("Album, ") {
                    cleanFallback = String(cleanFallback.dropFirst(7))
                }
                // Also handle case where it's "Album, Artist" but we got it as a combined string
                if cleanFallback.contains("Album,") {
                    let parts = cleanFallback.split(separator: ",", maxSplits: 1)
                    if parts.count > 1 {
                        cleanFallback = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
                cleanedArtists = [Artist(id: "unknown", name: cleanFallback)]
            }

            // Use fallback album if song doesn't have album info
            let finalAlbum = song.album ?? fallbackAlbum
            // Use fallback thumbnail if song doesn't have one
            let finalThumbnail = song.thumbnailURL ?? fallbackAlbum?.thumbnailURL

            return Song(
                id: song.id,
                title: song.title,
                artists: cleanedArtists,
                album: finalAlbum,
                duration: song.duration,
                thumbnailURL: finalThumbnail,
                videoId: song.videoId,
                isPlayable: song.isPlayable
            )
        }
    }

    func toggleLibrary() {
        let currentlyInLibrary = self.isInLibrary || self.isAddedToLibrary
        HapticService.success()
        Task {
            if currentlyInLibrary {
                await SongActionsHelper.removePlaylistFromLibrary(
                    self.playlist,
                    client: self.viewModel.client,
                    libraryViewModel: self.libraryViewModel
                )
                self.isAddedToLibrary = false
            } else {
                await SongActionsHelper.addPlaylistToLibrary(
                    self.playlist,
                    client: self.viewModel.client,
                    libraryViewModel: self.libraryViewModel
                )
                self.isAddedToLibrary = true
            }
        }
    }

    private func refinePlaylist(tracks: [Song], prompt: String) async {
        self.isRefining = true
        self.refineError = nil
        self.playlistChanges = nil
        self.partialChanges = nil

        self.logger.info("Refining playlist with prompt: \(prompt)")

        let promptVersion = FoundationModelsPromptVersion.current
        let instructions = FoundationModelsPromptLibrary.playlistRefinementInstructions(
            version: promptVersion
        )
        self.logger.debug("Using Foundation Models playlist prompt version \(promptVersion.logDescription)")

        // Use analysis session for creative playlist curation
        guard let session = FoundationModelsService.shared.createAnalysisSession(
            instructions: instructions
        )
        else {
            self.refineError = "Apple Intelligence is not available"
            self.isRefining = false
            return
        }

        // Build track list - start with 25 and trim further on 26.4+ if token budget requires it.
        let initialTrackLimit = min(tracks.count, 25)
        let trackLines = FoundationModelsPromptLibrary.playlistTrackLines(
            from: tracks,
            limit: initialTrackLimit
        )
        let trackLimit = await FoundationModelsService.shared.fittedLineCount(
            context: "playlist refinement",
            instructions: instructions,
            lines: trackLines,
            generationSchema: PlaylistChanges.generationSchema
        ) { candidateLines in
            FoundationModelsPromptLibrary.playlistRefinementPrompt(
                trackList: candidateLines.joined(separator: "\n"),
                totalTracks: tracks.count,
                shownTracks: candidateLines.count,
                request: prompt,
                version: promptVersion
            )
        }
        let trackList = Array(trackLines.prefix(trackLimit)).joined(separator: "\n")
        let fittedRequest = await FoundationModelsService.shared.fittedPromptContent(
            context: "playlist refinement request",
            instructions: instructions,
            content: prompt,
            generationSchema: PlaylistChanges.generationSchema
        ) { candidateRequest in
            FoundationModelsPromptLibrary.playlistRefinementPrompt(
                trackList: trackList,
                totalTracks: tracks.count,
                shownTracks: trackLimit,
                request: candidateRequest,
                version: promptVersion
            )
        }

        let userPrompt = FoundationModelsPromptLibrary.playlistRefinementPrompt(
            trackList: trackList,
            totalTracks: tracks.count,
            shownTracks: trackLimit,
            request: fittedRequest,
            version: promptVersion
        )

        do {
            // Use streaming for progressive UI updates
            let stream = session.streamResponse(
                to: userPrompt,
                generating: PlaylistChanges.self
            )

            for try await snapshot in stream {
                // Update partial content for streaming UI
                self.partialChanges = snapshot.content
            }

            // Stream complete - convert final partial to complete changes
            if let final = self.partialChanges,
               let removals = final.removals,
               let reasoning = final.reasoning
            {
                let normalizedChanges = PlaylistChanges(
                    removals: removals,
                    reorderedIds: final.reorderedIds,
                    reasoning: reasoning
                )
                .normalized(forOriginalTrackIds: tracks.map(\.videoId))
                self.playlistChanges = normalizedChanges
                self.logger.info(
                    """
                    Got playlist changes: \(removals.count) removals, \
                    reordered=\(normalizedChanges.reorderedIds != nil)
                    """
                )
            }
        } catch {
            // Use centralized error handler for consistent messaging
            if let message = AIErrorHandler.handleAndMessage(error, context: "playlist refinement") {
                self.refineError = message
            }
        }

        self.partialChanges = nil
        self.isRefining = false
    }
}

// MARK: - PlaylistTrackRow

@available(macOS 26.0, *)
private struct PlaylistTrackRow<Menu: View>: View {
    let track: Song
    let index: Int
    let isAlbum: Bool
    let subtitle: String?
    let onPlay: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovered: Bool = false
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        let isCurrent = self.playerService.currentTrack?.videoId == self.track.videoId

        Button(action: self.onPlay) {
            HStack(spacing: 12) {
                Group {
                    if isCurrent {
                        NowPlayingIndicator(isPlaying: self.playerService.isPlaying, size: 14)
                    } else {
                        Text("\(self.index + 1)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28, alignment: .trailing)

                if !self.isAlbum {
                    CachedAsyncImage(url: self.track.thumbnailURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(self.track.title)
                            .font(.system(size: 14))
                            .foregroundStyle(isCurrent ? .red : .primary)
                            .lineLimit(1)
                        if self.track.isExplicit == true {
                            ExplicitBadge()
                        }
                    }
                    if let subtitle = self.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                LikeButton(song: self.track, isRowHovered: self.isHovered)

                Text(self.track.durationDisplay)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 45, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .opacity(self.track.isPlayable ? 1 : 0.5)
        }
        .buttonStyle(.interactiveRow(cornerRadius: 6))
        .disabled(!self.track.isPlayable)
        .onHover { hovering in self.isHovered = hovering }
        .contextMenu { self.menu() }
    }
}

// MARK: - HoverUnderlineNavigationLink

private struct HoverUnderlineNavigationLink<Value: Hashable>: View {
    let value: Value
    let title: String

    @State private var isHovering = false

    var body: some View {
        NavigationLink(value: self.value) {
            Text(self.title)
                .font(.subheadline)
                .underline(self.isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.isHovering = hovering
        }
    }
}

#Preview {
    let playlist = Playlist(
        id: "test",
        title: "Test Playlist",
        description: nil,
        thumbnailURL: nil,
        trackCount: 10,
        author: Artist.inline(name: "Test Author", namespace: "playlist-author")
    )
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    PlaylistDetailView(
        playlist: playlist,
        viewModel: PlaylistDetailViewModel(
            playlist: playlist,
            client: client
        )
    )
    .environment(PlayerService())
    .environment(FavoritesManager(skipLoad: true))
    .environment(SidebarPinnedItemsManager(skipLoad: true))
}
