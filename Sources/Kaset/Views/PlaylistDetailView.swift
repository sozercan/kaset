import FoundationModels
import SwiftUI

@available(macOS 26.0, *)
struct PlaylistDetailView: View {
    let playlist: Playlist
    @State var viewModel: PlaylistDetailViewModel
    @Environment(PlayerService.self) var playerService
    @Environment(AuthService.self) private var authService
    @Environment(SidebarPinnedItemsManager.self) var sidebarPinnedItemsManager: SidebarPinnedItemsManager?
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(\.libraryViewModel) var libraryViewModel: LibraryViewModel?
    @Environment(\.dismiss) var dismiss
    @Environment(\.onPlaylistDeleted) var onPlaylistDeleted
    @State var showRefineSheet: Bool = false
    @State var libraryMutationActivity = PlaylistDetailLibraryMutationActivity()
    @State private var playlistChanges: PlaylistChanges?
    @State private var partialChanges: PlaylistChanges.PartiallyGenerated?
    @State private var isRefining: Bool = false
    @State private var refineError: String?
    var isInLibrary: Bool {
        if self.playlist.isAlbum {
            return self.libraryViewModel?.isInLibrary(
                albumId: self.playlist.id,
                targetPlaylistId: self.viewModel.playlistDetail?.libraryTargetId
            ) ?? false
        }
        return self.libraryViewModel?.isInLibrary(playlistId: self.playlist.id) ?? false
    }

    var isUpdatingLibrary: Bool {
        self.libraryMutationActivity.isActive
    }

    var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
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
                    .environment(
                        \.playerBarCurrentAlbumIDs,
                        PlayerBarCurrentRoute.albumIDs(for: self.playlist, detail: self.viewModel.playlistDetail)
                    )
            }
        }
        .task(id: self.viewModel.loadingState == .idle) {
            guard self.viewModel.loadingState == .idle else { return }
            await self.viewModel.ensureLoaded()
        }
        .refreshable {
            await self.viewModel.refresh()
        }
        .onChange(of: self.likeStatusManager.lastLikeEventBatch) { _, batch in
            guard let batch, batch.accountID == self.likeStatusManager.activeAccountID else { return }
            for event in batch.events {
                guard LikedMusicPlaylist.matches(id: self.playlist.id) else { return }
                self.viewModel.handleLikeStatusChange(event)
            }
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
                        self.showRefineSheet = false
                    }
                )
            }
        }
    }

    private func contentView(_ detail: PlaylistDetail) -> some View {
        let fallbackAlbum = Album(
            id: detail.id,
            title: detail.title,
            artists: detail.author.map { [$0] },
            thumbnailURL: detail.thumbnailURL,
            year: nil,
            trackCount: detail.trackCount ?? detail.tracks.count
        )
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                self.headerView(detail)
                    .padding(.bottom, 24)

                Divider()
                    .padding(.bottom, 24)

                self.trackRows(
                    detail.tracks, isAlbum: detail.isAlbum, author: detail.author?.name,
                    fallbackAlbum: fallbackAlbum
                )
            }
            .padding(.vertical, 24)
            .detailScrollContentInset()
        }
        .topFade(style: .contentMask)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func headerView(_ detail: PlaylistDetail) -> some View {
        HStack(alignment: .top, spacing: 20) {
            CachedAsyncImage(url: detail.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: 180, height: 180)) { image in
                image
                    .resizable()
                    .scaledToFill()
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
                    if artist.hasNavigableId {
                        NavigationLink(value: artist) {
                            HeaderArtistLinkLabel(name: artist.name)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(artist.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    if index < artists.count - 1 {
                        Text(verbatim: ", ")
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

    @ViewBuilder
    private func trackRows(
        _ tracks: [Song], isAlbum: Bool, author: String?, fallbackAlbum: Album? = nil
    ) -> some View {
        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
            VStack(spacing: 0) {
                self.trackRow(
                    track, index: index, tracks: tracks, isAlbum: isAlbum, author: author,
                    fallbackAlbum: fallbackAlbum
                )

                if index < tracks.count - 1 {
                    Divider()
                        .padding(.leading, isAlbum ? 40 : 96)
                }
            }
            .onAppear {
                self.viewModel.loadMoreIfNeeded(appearingAt: index)
            }
        }

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

    private func trackRow(
        _ track: Song, index: Int, tracks: [Song], isAlbum: Bool, author: String?,
        fallbackAlbum: Album? = nil
    ) -> some View {
        let play = {
            self.playTrackInQueue(
                tracks: tracks, startingAt: index, fallbackArtist: author,
                fallbackAlbum: fallbackAlbum
            )
        }
        return PlaylistTrackRow(
            track: track,
            index: index,
            isAlbum: isAlbum,
            subtitle: self.trackArtistsDisplay(for: track, fallbackAuthor: author),
            artists: self.trackArtists(for: track, fallbackAuthor: author),
            allowsLikeActions: self.hasPersonalAccount,
            onPlay: play,
            menu: {
                self.trackContextMenu(track, play: play)
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

    private func trackArtists(for track: Song, fallbackAuthor: String?) -> [Artist]? {
        let artists = self.uniqueArtists(from: track.artists)
        if !artists.isEmpty {
            return artists
        }

        guard let fallbackName = self.cleanedArtistName(fallbackAuthor),
              let author = self.cleanedArtist(self.viewModel.playlistDetail?.author),
              author.hasNavigableId,
              author.name == fallbackName
        else { return nil }

        return [author]
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

    @ViewBuilder
    private func trackContextMenu(_ track: Song, play: @escaping () -> Void) -> some View {
        if track.isPlayable {
            SongContextMenu(
                song: track,
                client: self.viewModel.client,
                play: play,
                showsGoToAlbum: self.viewModel.playlistDetail?.isAlbum != true
            )
        }

        if self.canRemoveTrack(track) {
            if track.isPlayable {
                Divider()
            }

            Button(role: .destructive) {
                Task {
                    await LibraryMutationActions.removeSongFromPlaylist(track, from: self.viewModel, client: self.viewModel.client)
                }
            } label: {
                Label(String(localized: "Remove from Playlist"), systemImage: "minus.circle")
            }
        }
    }

    private func canRemoveTrack(_ track: Song) -> Bool {
        guard let detail = self.viewModel.playlistDetail else { return false }
        return !self.viewModel.isRemovingTrack
            && detail.canDelete
            && !detail.isAlbum
            && !detail.isUploadedSongs
            && track.playlistSetVideoId != nil
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
        self.playAndLoadFullPlaylist(
            initial: cleanedTracks, startingAt: playableIndex,
            fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
    }

    func playAll(
        _ tracks: [Song], fallbackArtist: String? = nil, fallbackAlbum: Album? = nil
    ) {
        let cleanedTracks = self.playableTracks(
            tracks, fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
        guard !cleanedTracks.isEmpty else { return }
        self.playAndLoadFullPlaylist(
            initial: cleanedTracks, startingAt: 0,
            fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
        )
    }

    private func playAndLoadFullPlaylist(
        initial cleanedTracks: [Song], startingAt index: Int,
        fallbackArtist: String?, fallbackAlbum: Album?
    ) {
        let intent = self.playerService.beginMusicPlaybackIntent()
        Task { @MainActor in
            let willDeferLoad = self.viewModel.hasMore
            let loadGeneration = await self.playerService.playQueue(
                cleanedTracks,
                startingAt: index,
                deferringSmartShuffleFill: willDeferLoad,
                intent: intent
            )
            guard let loadGeneration else { return }

            await self.viewModel.loadAllRemaining()
            await self.viewModel.waitForTrackRemovalToFinish()

            guard self.playerService.isCurrentQueueLoad(loadGeneration) else { return }

            let fullTracks = self.playableTracks(
                self.viewModel.playlistDetail?.tracks ?? [],
                fallbackArtist: fallbackArtist, fallbackAlbum: fallbackAlbum
            )
            let remaining = PlaylistPlaybackActions.remainingTracks(
                after: cleanedTracks,
                in: fullTracks
            )
            self.playerService.appendOriginalTracks(remaining)
            await self.playerService.endQueueLoading(loadGeneration)
        }
    }

    func playableTracks(
        _ tracks: [Song], fallbackArtist: String?, fallbackAlbum: Album? = nil
    ) -> [Song] {
        QueueSongMetadata.songsForQueue(
            tracks.filter(\.isPlayable), fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum
        )
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

        guard let session = FoundationModelsService.shared.createAnalysisSession(
            instructions: instructions
        )
        else {
            self.refineError = "Apple Intelligence is not available"
            self.isRefining = false
            return
        }

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
            let stream = session.streamResponse(
                to: userPrompt,
                generating: PlaylistChanges.self
            )

            for try await snapshot in stream {
                self.partialChanges = snapshot.content
            }

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
            if let message = AIErrorHandler.handleAndMessage(error, context: "playlist refinement") {
                self.refineError = message
            }
        }

        self.partialChanges = nil
        self.isRefining = false
    }
}

private struct HeaderArtistLinkLabel: View {
    let name: String

    @State private var isHovering = false

    var body: some View {
        Text(self.name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(self.isHovering ? .primary : .secondary)
            .animation(.easeInOut(duration: 0.15), value: self.isHovering)
            .onHover { hovering in
                self.isHovering = hovering
            }
    }
}

@available(macOS 26.0, *)
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
