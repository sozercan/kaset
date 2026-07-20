import SwiftUI

// swiftlint:disable file_length

// MARK: - PlayerBar

/// Player bar shown at the bottom of the content area, styled like Apple Music with Liquid Glass.
struct PlayerBar: View { // swiftlint:disable:this type_body_length
    private static let brandAccent = PackageResourceLookup.brandAccent
    private static let fullSongInfoWidth: CGFloat = 234
    private static let compactSongInfoWidth: CGFloat = 116

    @Environment(AuthService.self) private var authService
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.playerBarNavigationAction) private var navigationAction
    @Environment(\.playerBarCurrentAlbumID) private var currentRouteAlbumID
    @Environment(\.playerBarCurrentArtistID) private var currentRouteArtistID
    @Environment(NowPlayingTracklistProvider.self) private var tracklistProvider: NowPlayingTracklistProvider?

    /// Namespace for glass effect morphing and unioning.
    @Namespace private var playerNamespace

    /// Local normalized seek fraction (0...1) for smooth dragging; `performSeek` converts to seconds.
    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var seekHold = PlayerBarSeekHold()

    /// Local volume value for smooth slider dragging.
    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false
    @State private var showsVolumeOverlay = false
    @State private var resolvedArtist: Artist?
    @State private var resolvedAlbum: Playlist?
    @State private var isResolvingArtist = false
    @State private var isResolvingAlbum = false

    /// Cached formatted progress string to avoid repeated formatting.
    @State private var formattedProgress: String = "0:00"
    @State private var formattedRemaining: String = "-0:00"
    /// Last integer second of progress to reduce string formatting frequency.
    @State private var lastProgressSecond: Int = -1

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            GeometryReader { proxy in
                let usesCompactDetails = proxy.size.width <= PlayerBarLayout.compactDetailsBreakpoint

                HStack(spacing: 10) {
                    self.songInfoSection(usesCompactDetails: usesCompactDetails)
                        .frame(
                            width: usesCompactDetails ? Self.compactSongInfoWidth : Self.fullSongInfoWidth,
                            height: 52
                        )

                    self.progressSection
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)

                    self.playbackOptionsSection
                        .frame(width: 142, height: 52)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .compatGlass(interactive: true, in: .capsule)
            .compatGlassID("playerBar", in: self.playerNamespace)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(alignment: .bottom) {
            self.playerAreaFade
        }
        .background {
            self.keyboardShortcuts
        }
        .zIndex(1)
        .task(id: self.currentTitleIdentity) {
            await self.prepareCurrentNavigationTargets()
        }
        .onChange(of: self.playerService.progress) { _, newValue in
            self.seekHold.reconcile(observedProgress: newValue)
            let displayProgress = self.displayProgress(observedProgress: newValue)

            if !self.isSeeking, !self.seekHold.isActive, self.playerService.duration > 0 {
                self.seekValue = displayProgress / self.playerService.duration
            }

            let currentSecond = Int(displayProgress)
            if currentSecond != self.lastProgressSecond {
                self.lastProgressSecond = currentSecond
                self.updateFormattedTimes(progress: displayProgress, duration: self.playerService.duration)
            }
        }
        .onChange(of: self.playerService.duration) { _, newValue in
            self.seekHold.reconcile(observedProgress: self.playerService.progress)
            let displayProgress = self.displayedPlaybackProgress
            if !self.isSeeking, !self.seekHold.isActive, newValue > 0 {
                self.seekValue = displayProgress / newValue
            }
            self.updateFormattedTimes(progress: displayProgress, duration: newValue)
        }
        .onChange(of: self.currentSeekIdentity) { _, _ in
            self.clearSeekHold()
        }
        .onChange(of: self.playerService.volume) { _, newValue in
            if !self.isAdjustingVolume {
                self.volumeValue = newValue
            }
        }
        .onAppear {
            self.volumeValue = self.playerService.volume
            if self.playerService.duration > 0 {
                self.seekValue = self.playerService.progress / self.playerService.duration
            }
        }
    }

    private var playerAreaFade: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor).opacity(0),
                Color(nsColor: .windowBackgroundColor).opacity(0.22),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .padding(.bottom, -8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var keyboardShortcuts: some View {
        Button(String(localized: "")) {
            Task { await self.playerService.playPause() }
        }
        .keyboardShortcut(.space, modifiers: [])
        .opacity(0)

        Button(String(localized: "")) {
            Task { await self.playerService.next() }
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(self.playerService.currentEpisode != nil)
        .opacity(0)

        Button(String(localized: "")) {
            Task { await self.playerService.previous() }
        }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(self.playerService.currentEpisode != nil)
        .opacity(0)

        Button(String(localized: "")) {
            Task { await self.playerService.setVolume(min(1.0, self.playerService.volume + 0.1)) }
        }
        .keyboardShortcut(.upArrow, modifiers: .command)
        .opacity(0)

        Button(String(localized: "")) {
            Task { await self.playerService.setVolume(max(0.0, self.playerService.volume - 0.1)) }
        }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .opacity(0)
    }

    // MARK: - Song Info

    private func songInfoSection(usesCompactDetails: Bool) -> some View {
        HStack(spacing: 8) {
            self.thumbnailView

            if !usesCompactDetails {
                self.songDetailsView
                    .frame(width: 110, alignment: .leading)
            }

            self.songActionButtons
        }
        .padding(.leading, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contextMenu {
            if let track = self.playerService.currentTrack {
                self.currentSongContextMenu(for: track)
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let track = self.playerService.currentTrack {
            if self.canOpenCurrentAlbum {
                Button {
                    self.openCurrentAlbum()
                } label: {
                    self.trackArtwork(for: track)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.PlayerBar.thumbnail)
                .accessibilityLabel(Text(String(localized: "Go to Album")))
            } else {
                self.trackArtwork(for: track)
                    .accessibilityIdentifier(AccessibilityID.PlayerBar.thumbnail)
            }
        } else {
            PlayerBarArtworkView(
                width: 32,
                height: 32,
                cornerRadius: 6,
                showsHoverOverlay: false
            ) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        CassetteIcon(size: 18)
                            .foregroundStyle(.secondary)
                    }
            }
            .accessibilityIdentifier(AccessibilityID.PlayerBar.thumbnail)
        }
    }

    private func trackArtwork(for track: Song) -> some View {
        PlayerBarArtworkView(
            width: 32,
            height: 32,
            cornerRadius: 6,
            glowSources: self.artworkGlowSources(for: track),
            glowIdentity: self.artworkGlowIdentity(for: track),
            glowTargetSize: CGSize(width: 64, height: 64),
            showsHoverOverlay: self.canOpenCurrentAlbum || self.showsCurrentAlbumHoverOnly,
            isLoading: self.isResolvingAlbum
        ) {
            SongThumbnailView(song: track, size: 32, cornerRadius: 6)
        }
    }

    private func artworkGlowSources(for track: Song) -> [URL] {
        self.uniqueURLs([
            track.fallbackThumbnailURL,
            track.thumbnailURL?.highQualityThumbnailURL,
        ])
    }

    private func artworkGlowIdentity(for track: Song) -> String {
        track.videoId
    }

    private func uniqueURLs(_ urls: [URL?]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { url in
            guard let url, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    private var songDetailsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            PlayerBarMarqueeText(
                text: self.playerService.currentTrack?.title ?? String(localized: "Not Playing"),
                font: .system(size: 13),
                color: .primary,
                height: 13,
                reduceMotion: self.reduceMotion
            )
            .id(self.currentTitleIdentity)
            .accessibilityIdentifier(AccessibilityID.PlayerBar.trackTitle)

            PlayerBarMetadataButton(
                text: self.artistName,
                isEnabled: self.canOpenCurrentArtist,
                isLoading: self.isResolvingArtist,
                accessibilityIdentifier: AccessibilityID.PlayerBar.trackArtist,
                action: self.openCurrentArtist
            )
        }
        .frame(height: 29, alignment: .leading)
    }

    private var currentTitleIdentity: String {
        [
            self.playerService.currentTrack?.videoId ?? "none",
            self.playerService.currentTrack?.title ?? "none",
        ].joined(separator: "|")
    }

    private var canOpenCurrentArtist: Bool {
        self.playerService.currentTrack != nil
            && self.navigationAction.openArtist != nil
            && (self.currentArtistTarget != nil || (self.currentArtistSearchName != nil && self.playerService.ytMusicClient != nil))
            && !self.isCurrentArtistTarget
    }

    private var canOpenCurrentAlbum: Bool {
        self.playerService.currentTrack != nil
            && self.navigationAction.openAlbum != nil
            && (self.currentAlbumTarget != nil || (self.currentArtistSearchName != nil && self.playerService.ytMusicClient != nil))
            && !self.isCurrentAlbumTarget
            && !self.isResolvingCurrentRouteAlbum
    }

    private var currentArtistTarget: Artist? {
        self.primaryNavigableArtist ?? self.resolvedArtist
    }

    private var currentAlbumTarget: Playlist? {
        self.currentAlbumPlaylist ?? self.resolvedAlbum
    }

    private var isCurrentAlbumTarget: Bool {
        guard let currentRouteAlbumID,
              let album = self.currentAlbumTarget
        else { return false }

        return album.id == currentRouteAlbumID
    }

    private var showsCurrentAlbumHoverOnly: Bool {
        self.isCurrentAlbumTarget || self.isResolvingCurrentRouteAlbum
    }

    private var isResolvingCurrentRouteAlbum: Bool {
        self.currentRouteAlbumID != nil && self.currentAlbumTarget == nil
    }

    private var isCurrentArtistTarget: Bool {
        guard let currentRouteArtistID,
              let artist = self.currentArtistTarget
        else { return false }

        return artist.id == currentRouteArtistID || artist.publicChannelId == currentRouteArtistID
    }

    private var currentAlbumPlaylist: Playlist? {
        guard let track = self.playerService.currentTrack,
              let album = track.album,
              album.hasNavigableId
        else { return nil }

        return self.playlist(from: album, track: track)
    }

    private var primaryNavigableArtist: Artist? {
        self.playerService.currentTrack?.artists.first(where: { $0.hasNavigableId })
    }

    private var currentArtistSearchName: String? {
        guard let track = self.playerService.currentTrack else { return nil }
        return self.primaryArtistName(in: track)
    }

    private var artistName: String {
        guard let track = self.playerService.currentTrack else {
            return String(localized: "Kaset")
        }
        return track.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : track.artistsDisplay
    }

    private func playlist(from album: Album, track: Song) -> Playlist {
        Playlist(
            id: album.id,
            title: album.title,
            description: nil,
            thumbnailURL: album.thumbnailURL ?? track.thumbnailURL,
            trackCount: album.trackCount,
            author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
        )
    }

    @ViewBuilder
    private var songActionButtons: some View {
        if self.hasPersonalAccount {
            HStack(spacing: 6) {
                PlayerBarIconButton(
                    action: self.likeCurrentTrack,
                    isSelected: self.playerService.currentTrackLikeStatus == .like,
                    accessibilityID: AccessibilityID.PlayerBar.likeButton,
                    accessibilityLabel: String(localized: "Like"),
                    accessibilityValue: self.playerService.currentTrackLikeStatus == .like ? String(localized: "Liked") : String(localized: "Not liked")
                ) {
                    Image(systemName: self.playerService.currentTrackLikeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 10, height: 16)
                        .foregroundStyle(self.playerService.currentTrackLikeStatus == .like ? Self.brandAccent : .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .symbolEffect(.bounce, value: self.playerService.currentTrackLikeStatus == .like)
                .disabled(self.playerService.currentTrack == nil)

                PlayerBarIconButton(
                    action: self.dislikeCurrentTrack,
                    isSelected: self.playerService.currentTrackLikeStatus == .dislike,
                    accessibilityID: AccessibilityID.PlayerBar.dislikeButton,
                    accessibilityLabel: String(localized: "Dislike"),
                    accessibilityValue: self.playerService.currentTrackLikeStatus == .dislike ? String(localized: "Disliked") : String(localized: "Not disliked")
                ) {
                    Image(systemName: self.playerService.currentTrackLikeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 10, height: 16)
                        .foregroundStyle(self.playerService.currentTrackLikeStatus == .dislike ? Self.brandAccent : .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .symbolEffect(.bounce, value: self.playerService.currentTrackLikeStatus == .dislike)
                .disabled(self.playerService.currentTrack == nil)
            }
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        ZStack(alignment: .top) {
            if case let .error(message) = playerService.state {
                self.errorView(message: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlayerBarProgressLane(
                    fraction: self.displayFraction,
                    accent: Self.brandAccent,
                    elapsedText: self.isSeeking
                        ? self.formatTime(self.seekValue * self.playerService.duration)
                        : self.formattedProgress,
                    remainingText: self.isSeeking
                        ? "-\(self.formatTime(max(0, self.playerService.duration - self.seekValue * self.playerService.duration)))"
                        : self.formattedRemaining,
                    segments: self.progressSegments,
                    isLive: self.playerService.isCurrentItemLive,
                    canSeek: self.canSeek,
                    isLoading: self.isProgressLoading,
                    onScrub: { fraction in
                        self.isSeeking = true
                        self.seekValue = fraction
                    },
                    onCommit: {
                        self.performSeek()
                    }
                )
                .padding(.top, 18)
                // Keeps the segment tooltip above the transport buttons; the tooltip
                // itself is non-hit-testable so the buttons stay clickable.
                .zIndex(1)
            }

            self.progressActionButtons
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Sub-track segments for the seek bar, derived from the now-playing tracklist.
    /// Empty for regular songs and live streams, which renders the standard single-track lane.
    private var progressSegments: [PlayerBarProgressSegment] {
        guard let tracklist = self.tracklistProvider?.tracklist,
              self.playerService.duration > 0,
              !self.playerService.isCurrentItemLive
        else { return [] }

        let duration = self.playerService.duration
        let entries = tracklist.entries
        let count = entries.count
        return entries.enumerated().map { index, entry in
            let end = entry.endTime ?? duration
            return PlayerBarProgressSegment(
                id: entry.id.uuidString,
                start: entry.startTime / duration,
                end: end / duration,
                index: index,
                count: count,
                title: entry.title,
                subtitle: entry.artist,
                rangeText: "\(self.formatTime(entry.startTime)) – \(self.formatTime(end))"
            )
        }
    }

    private var progressActionButtons: some View {
        HStack(spacing: 6) {
            if !self.progressSegments.isEmpty {
                self.mixTracksMenu
            }

            PlayerBarIconButton(
                action: self.showAirPlayPicker,
                isSelected: self.playerService.isAirPlayConnected,
                accessibilityID: AccessibilityID.PlayerBar.airplayButton,
                accessibilityLabel: self.playerService.isAirPlayConnected ? String(localized: "AirPlay Connected") : String(localized: "AirPlay")
            ) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 10, height: 16)
                    .foregroundStyle(self.playerService.isAirPlayConnected ? Self.brandAccent : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(self.playerService.currentTrack == nil)

            PlayerBarIconButton(
                action: self.cycleShuffle,
                isSelected: self.playerService.shuffleEnabled,
                accessibilityID: AccessibilityID.PlayerBar.shuffleButton,
                accessibilityLabel: String(localized: "Shuffle"),
                accessibilityValue: self.shuffleAccessibilityValue
            ) {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 10, height: 16)
                    .foregroundStyle(self.shuffleTint)
                    .overlay(alignment: .topTrailing) {
                        if self.playerService.shuffleMode == .smart {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Self.brandAccent)
                                .offset(x: 5, y: -5)
                        }
                    }
                    .opacity(self.playerService.isApplyingSmartShuffle ? 0.5 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(self.playerService.currentTrack == nil)

            HStack(spacing: 6) {
                PlayerBarIconButton(
                    action: self.previousTrack,
                    accessibilityID: AccessibilityID.PlayerBar.previousButton,
                    accessibilityLabel: String(localized: "Previous track")
                ) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 8, height: 13)
                        .foregroundStyle(.primary)
                }
                .disabled(self.playerService.currentEpisode != nil)

                PlayerBarIconButton(
                    action: self.playPause,
                    accessibilityID: AccessibilityID.PlayerBar.playPauseButton,
                    accessibilityLabel: self.playerService.isPlaying ? String(localized: "Pause") : String(localized: "Play")
                ) {
                    Image(systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 12, height: 20)
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .compatGlassID("playPause", in: self.playerNamespace)

                PlayerBarIconButton(
                    action: self.nextTrack,
                    accessibilityID: AccessibilityID.PlayerBar.nextButton,
                    accessibilityLabel: String(localized: "Next track")
                ) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 8, height: 13)
                        .foregroundStyle(.primary)
                }
                .disabled(self.playerService.currentEpisode != nil)
            }

            PlayerBarIconButton(
                action: self.cycleRepeatMode,
                isSelected: self.playerService.repeatMode != .off,
                accessibilityID: AccessibilityID.PlayerBar.repeatButton,
                accessibilityLabel: String(localized: "Repeat"),
                accessibilityValue: self.repeatAccessibilityValue
            ) {
                Image(systemName: self.repeatIconName)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 12, height: 16)
                    .foregroundStyle(self.playerService.repeatMode == .off ? .primary : Self.brandAccent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(self.playerService.currentTrack == nil)

            PlayerBarIconButton(
                action: self.toggleVolumePopover,
                accessibilityLabel: String(localized: "Volume")
            ) {
                Image(systemName: self.volumeIcon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 10, height: 15)
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .overlay(alignment: .top) {
                if self.showsVolumeOverlay {
                    self.volumeOverlay
                        .offset(y: -176)
                        .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
            }
        }
    }

    private var mixTracksMenu: some View {
        PlayerBarIconMenu(
            accessibilityID: AccessibilityID.PlayerBar.mixTracksButton,
            accessibilityLabel: String(localized: "Mix tracks")
        ) {
            ForEach(self.progressSegments) { segment in
                Button {
                    self.seek(to: segment)
                } label: {
                    if segment.id == self.currentProgressSegment?.id {
                        Label(segment.accessibilityDescription, systemImage: "checkmark")
                    } else {
                        Text(segment.accessibilityDescription)
                    }
                }
                .disabled(!self.canSeek)
            }
        } icon: {
            Image(systemName: "list.number")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary)
        }
    }

    private var volumeOverlay: some View {
        CompatGlassContainer(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: self.volumeIcon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)

                PlayerBarVerticalSlider(
                    value: self.$volumeValue,
                    accent: Self.brandAccent,
                    accessibilityIdentifier: AccessibilityID.PlayerBar.volumeSlider,
                    accessibilityLabel: String(localized: "Volume"),
                    onEditingChanged: { editing in
                        self.isAdjustingVolume = editing
                        if !editing {
                            Task {
                                await self.playerService.setVolume(self.volumeValue)
                            }
                        }
                    },
                    onValueChanged: { oldValue, newValue in
                        if self.isAdjustingVolume {
                            if (oldValue > 0 && newValue == 0) || (oldValue < 1 && newValue == 1) {
                                HapticService.sliderBoundary()
                            }
                            Task {
                                await self.playerService.setVolume(newValue)
                            }
                        }
                    }
                )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 16)
            .frame(width: 46, height: 168)
            .background {
                Capsule()
                    .fill(self.volumeOverlayFill)
            }
            .compatGlass(interactive: true, tint: self.volumeOverlayTint, in: .capsule)
            .shadow(color: self.volumeOverlayShadow, radius: 14, y: 5)
        }
    }

    private var volumeOverlayFill: Color {
        self.colorScheme == .dark ? .black.opacity(0.22) : .white.opacity(0.72)
    }

    private var volumeOverlayTint: Color {
        self.colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.06)
    }

    private var volumeOverlayShadow: Color {
        self.colorScheme == .dark ? .black.opacity(0.36) : .black.opacity(0.18)
    }

    private var canSeek: Bool {
        self.playerService.currentTrack != nil
            && self.playerService.duration > 0
            && !self.playerService.isCurrentItemLive
    }

    private var isProgressLoading: Bool {
        switch self.playerService.state {
        case .loading, .buffering:
            self.playerService.currentTrack != nil
        case .idle, .playing, .paused, .ended, .error:
            false
        }
    }

    private var canShowCurrentTrackVideo: Bool {
        guard let track = self.playerService.currentTrack else { return false }
        if UITestConfig.isUITestMode,
           UITestConfig.environmentValue(for: UITestConfig.mockHasVideoKey) == "true"
        {
            return true
        }
        return self.playerService.currentTrackHasVideo
            || track.musicVideoType?.hasVideoContent == true
            || track.hasVideo == true
    }

    /// Fraction (0...1) to render: the live drag value while seeking, otherwise actual progress.
    private var displayFraction: Double {
        if self.isSeeking {
            return min(max(0, self.seekValue), 1)
        }
        guard self.playerService.duration > 0 else { return 0 }
        return min(max(0, self.displayedPlaybackProgress / self.playerService.duration), 1)
    }

    private var currentProgressSegment: PlayerBarProgressSegment? {
        PlayerBarProgressLane.segment(at: self.displayFraction, in: self.progressSegments)
    }

    private var displayedPlaybackProgress: TimeInterval {
        self.displayProgress(observedProgress: self.playerService.progress)
    }

    private func displayProgress(observedProgress: TimeInterval) -> TimeInterval {
        self.seekHold.displayProgress(observedProgress: observedProgress)
    }

    private var currentSeekIdentity: String {
        self.playerService.currentTrack?.videoId ?? "none"
    }

    // MARK: - Playback Options

    private var playbackOptionsSection: some View {
        HStack(spacing: 6) {
            self.lyricsButton
            self.queueButton
            self.pictureButton
            self.miniPlayerButton
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private var lyricsButton: some View {
        @Bindable var player = self.playerService

        return PlayerBarIconButton(
            action: {
                HapticService.toggle()
                withAnimation(AppAnimation.standard) {
                    player.showLyrics.toggle()
                }
            },
            isSelected: self.playerService.showLyrics,
            accessibilityID: AccessibilityID.PlayerBar.lyricsButton,
            accessibilityLabel: String(localized: "Lyrics"),
            accessibilityValue: self.playerService.showLyrics ? String(localized: "Showing") : String(localized: "Hidden"),
            icon: {
                Image(systemName: self.playerService.showLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 10, height: 16)
                    .foregroundStyle(self.playerService.showLyrics ? Self.brandAccent : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        )
        .compatGlassID("lyrics", in: self.playerNamespace)
    }

    private var queueButton: some View {
        @Bindable var player = self.playerService

        return PlayerBarIconButton(
            action: {
                HapticService.toggle()
                withAnimation(AppAnimation.standard) {
                    player.showQueue.toggle()
                }
            },
            isSelected: self.playerService.showQueue,
            accessibilityID: AccessibilityID.PlayerBar.queueButton,
            accessibilityLabel: String(localized: "Queue"),
            accessibilityValue: self.playerService.showQueue ? String(localized: "Showing") : String(localized: "Hidden"),
            icon: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 10, height: 16)
                    .foregroundStyle(self.playerService.showQueue ? Self.brandAccent : .primary)
            }
        )
        .compatGlassID("queue", in: self.playerNamespace)
    }

    private var pictureButton: some View {
        PlayerBarIconButton(
            action: {
                self.toggleVideo()
            },
            isSelected: self.playerService.showVideo,
            accessibilityID: AccessibilityID.PlayerBar.videoButton,
            accessibilityLabel: String(localized: "Video"),
            accessibilityValue: self.playerService.showVideo ? String(localized: "Playing") : String(localized: "Off"),
            icon: {
                Image(systemName: self.pictureButtonIcon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 13, height: 14)
                    .foregroundStyle(self.playerService.showVideo ? Self.brandAccent : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        )
        .compatGlassID("picture", in: self.playerNamespace)
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!self.canShowCurrentTrackVideo)
    }

    private var miniPlayerButton: some View {
        @Bindable var player = self.playerService

        return PlayerBarIconButton(
            action: {
                HapticService.toggle()
                _ = player.toggleMiniPlayer(mode: .switchFromMainWindow)
            },
            isSelected: self.playerService.isMiniPlayerVisible,
            accessibilityID: AccessibilityID.PlayerBar.miniPlayerButton,
            accessibilityLabel: self.playerService.isMiniPlayerVisible ? String(localized: "Return to Kaset") : String(localized: "Switch to Mini Player"),
            accessibilityValue: self.playerService.isMiniPlayerVisible ? String(localized: "Showing") : String(localized: "Hidden"),
            icon: {
                Image(systemName: self.playerService.isMiniPlayerVisible ? "macwindow" : "rectangle.inset.bottomright.filled")
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 15, height: 15)
                    .foregroundStyle(self.playerService.isMiniPlayerVisible ? Self.brandAccent : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        )
        .compatGlassID("miniPlayer", in: self.playerNamespace)
    }

    private var pictureButtonIcon: String {
        self.playerService.showVideo ? "pip.exit" : "pip.enter"
    }

    private func toggleVideo() {
        guard self.canShowCurrentTrackVideo else { return }
        HapticService.toggle()
        DiagnosticsLogger.player.debug(
            "Video button clicked, toggling showVideo from \(self.playerService.showVideo)"
        )
        withAnimation(AppAnimation.standard) {
            self.playerService.showVideo.toggle()
        }
    }

    // MARK: - Current Song Context Menu

    @ViewBuilder
    private func currentSongContextMenu(for track: Song) -> some View {
        FavoritesContextMenu.menuItem(for: track, manager: self.favoritesManager)

        if self.hasPersonalAccount {
            Divider()

            LikeDislikeContextMenu(song: track, likeStatusManager: self.likeStatusManager)
        }

        Divider()

        StartRadioContextMenu.menuItem(for: track, playerService: self.playerService)

        if self.hasPersonalAccount {
            Divider()

            Button {
                self.playerService.toggleLibraryStatus()
            } label: {
                Label(
                    self.playerService.currentTrackInLibrary ? "Remove from Library" : "Add to Library",
                    systemImage: self.playerService.currentTrackInLibrary ? "minus.circle" : "plus.circle"
                )
            }
        }

        Divider()

        ShareContextMenu.menuItem(for: track)

        Divider()

        AddToQueueContextMenu(song: track, playerService: self.playerService)

        if self.hasPersonalAccount, let client = self.playerService.ytMusicClient {
            Divider()

            AddToPlaylistContextMenu(song: track, client: client)
        }

        let artist = track.artists.first(where: { $0.hasNavigableId })
        let album = track.album
        if artist != nil || album?.hasNavigableId == true {
            Divider()
        }

        if let artist, self.navigationAction.openArtist != nil {
            Button {
                self.openArtist(artist)
            } label: {
                Label(String(localized: "Go to Artist"), systemImage: "person")
            }
        }

        if let album, album.hasNavigableId, self.navigationAction.openAlbum != nil {
            Button {
                self.openAlbum(self.playlist(from: album, track: track))
            } label: {
                Label(String(localized: "Go to Album"), systemImage: "square.stack")
            }
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))

            Text(message)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    if let track = playerService.currentTrack {
                        await self.playerService.play(song: track)
                    }
                }
            } label: {
                Text("Retry", comment: "Button to retry failed playback")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary)
            .clipShape(.capsule)
        }
    }

    // MARK: - Actions

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private func likeCurrentTrack() {
        guard self.hasPersonalAccount else { return }
        HapticService.toggle()
        self.playerService.likeCurrentTrack()
    }

    private func prepareCurrentNavigationTargets() async {
        self.resolvedArtist = nil
        self.resolvedAlbum = nil
        self.isResolvingArtist = false
        self.isResolvingAlbum = false

        guard self.playerService.currentTrack != nil,
              let client = self.playerService.ytMusicClient
        else { return }

        let identity = self.currentTitleIdentity

        if self.navigationAction.openArtist != nil,
           self.primaryNavigableArtist == nil,
           let artistName = self.currentArtistSearchName
        {
            let artist = await self.resolveArtist(named: artistName, client: client)
            guard !Task.isCancelled, self.currentTitleIdentity == identity else { return }
            self.resolvedArtist = artist
        }

        if self.navigationAction.openAlbum != nil,
           self.currentAlbumPlaylist == nil,
           self.currentArtistSearchName != nil,
           let track = self.playerService.currentTrack
        {
            let album = await self.resolveAlbum(for: track, client: client)
            guard !Task.isCancelled, self.currentTitleIdentity == identity else { return }
            self.resolvedAlbum = album
        }
    }

    private func openCurrentArtist() {
        guard self.canOpenCurrentArtist else { return }
        guard !self.isResolvingArtist else { return }
        HapticService.toggle()

        if let artist = self.currentArtistTarget {
            self.openArtist(artist, playsHaptic: false)
            return
        }

        guard let query = self.currentArtistSearchName else { return }
        guard let client = self.playerService.ytMusicClient else { return }
        let identity = self.currentTitleIdentity

        self.isResolvingArtist = true

        Task {
            let artist = await self.resolveArtist(named: query, client: client)
            guard !Task.isCancelled, self.currentTitleIdentity == identity else { return }
            self.resolvedArtist = artist
            self.isResolvingArtist = false

            guard let artist, !self.isCurrentArtistTarget else { return }
            self.openArtist(artist, playsHaptic: false)
        }
    }

    private func openCurrentAlbum() {
        guard self.canOpenCurrentAlbum else { return }
        guard !self.isResolvingAlbum else { return }
        HapticService.toggle()

        if let album = self.currentAlbumTarget {
            self.openAlbum(album, playsHaptic: false)
            return
        }

        guard let track = self.playerService.currentTrack,
              let client = self.playerService.ytMusicClient
        else { return }

        let identity = self.currentTitleIdentity
        self.isResolvingAlbum = true

        Task {
            let album = await self.resolveAlbum(for: track, client: client)
            guard !Task.isCancelled, self.currentTitleIdentity == identity else { return }
            self.resolvedAlbum = album
            self.isResolvingAlbum = false

            guard let album else { return }
            self.openAlbum(album, playsHaptic: false)
        }
    }

    private func openArtist(_ artist: Artist, playsHaptic: Bool = true) {
        if playsHaptic {
            HapticService.toggle()
        }
        self.navigationAction.openArtist?(artist)
    }

    private func openAlbum(_ album: Playlist, playsHaptic: Bool = true) {
        if playsHaptic {
            HapticService.toggle()
        }
        self.navigationAction.openAlbum?(album)
    }

    private func resolveArtist(named name: String, client: any YTMusicClientProtocol) async -> Artist? {
        guard let query = self.trimmedNonEmpty(name) else { return nil }

        do {
            let response = try await client.searchArtists(query: query)
            return response.artists.first { artist in
                artist.hasNavigableId && self.matchesSearchResultTitle(artist.name, query: query)
            }
        } catch {
            DiagnosticsLogger.ui.error("Failed to resolve player bar artist: \(error.localizedDescription)")
            return nil
        }
    }

    private func resolveAlbum(for track: Song, client: any YTMusicClientProtocol) async -> Playlist? {
        if let album = track.album,
           let playlist = await self.resolveAlbum(named: album.title, fallbackTrack: track, client: client)
        {
            return playlist
        }

        do {
            guard let query = self.searchQuery(parts: [track.title, self.primaryArtistName(in: track)]) else { return nil }

            let response = try await client.searchSongsWithPagination(query: query)
            let matchedSong = response.songs.first { $0.videoId == track.videoId }
                ?? response.songs.first { song in
                    self.matchesSearchResultTitle(song.title, query: track.title)
                        && self.matchesTrackArtist(song, fallbackTrack: track)
                }

            guard let album = matchedSong?.album, album.hasNavigableId else { return nil }
            return self.playlist(from: album, track: matchedSong ?? track)
        } catch {
            DiagnosticsLogger.ui.error("Failed to resolve player bar album from song search: \(error.localizedDescription)")
            return nil
        }
    }

    private func resolveAlbum(
        named title: String,
        fallbackTrack track: Song,
        client: any YTMusicClientProtocol
    ) async -> Playlist? {
        guard let query = self.searchQuery(parts: [title, self.primaryArtistName(in: track)]),
              let artistName = self.primaryArtistName(in: track)
        else { return nil }

        do {
            let response = try await client.searchAlbums(query: query)
            guard let album = response.albums.first(where: { album in
                album.hasNavigableId
                    && self.matchesSearchResultTitle(album.title, query: title)
                    && self.matchesAlbumArtist(album, artistName: artistName)
            }) else {
                return nil
            }

            return self.playlist(from: album, track: track)
        } catch {
            DiagnosticsLogger.ui.error("Failed to resolve player bar album: \(error.localizedDescription)")
            return nil
        }
    }

    private func primaryArtistName(in track: Song) -> String? {
        track.artists.lazy.compactMap { self.trimmedNonEmpty($0.name) }.first
    }

    private func searchQuery(parts: [String?]) -> String? {
        let query = parts.compactMap { part in
            part.flatMap(self.trimmedNonEmpty)
        }.joined(separator: " ")

        return self.trimmedNonEmpty(query)
    }

    private func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func matchesTrackArtist(_ song: Song, fallbackTrack track: Song) -> Bool {
        guard let artistName = self.primaryArtistName(in: track) else { return false }
        return song.artists.contains { self.matchesSearchResultTitle($0.name, query: artistName) }
    }

    private func matchesAlbumArtist(_ album: Album, artistName: String) -> Bool {
        guard let artists = album.artists else { return false }
        return artists.contains { self.matchesSearchResultTitle($0.name, query: artistName) }
    }

    private func matchesSearchResultTitle(_ title: String, query: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(query)
        return normalizedTitle == .orderedSame
    }

    private func dislikeCurrentTrack() {
        guard self.hasPersonalAccount else { return }
        HapticService.toggle()
        self.playerService.dislikeCurrentTrack()
    }

    private func showAirPlayPicker() {
        HapticService.toggle()
        self.playerService.showAirPlayPicker()
    }

    private func previousTrack() {
        HapticService.playback()
        Task {
            await self.playerService.previous()
        }
    }

    private func playPause() {
        HapticService.playback()
        Task {
            await self.playerService.playPause()
        }
    }

    private func nextTrack() {
        HapticService.playback()
        Task {
            await self.playerService.next()
        }
    }

    private var shuffleTint: Color {
        switch self.playerService.shuffleMode {
        case .off: .primary
        case .on, .smart: Self.brandAccent
        }
    }

    private var shuffleAccessibilityValue: String {
        switch self.playerService.shuffleMode {
        case .off: String(localized: "Off")
        case .on: String(localized: "On")
        case .smart: String(localized: "Smart")
        }
    }

    private func cycleShuffle() {
        HapticService.toggle()
        self.playerService.cycleShuffleMode()
    }

    private func cycleRepeatMode() {
        HapticService.toggle()
        self.playerService.cycleRepeatMode()
    }

    private func toggleVolumePopover() {
        HapticService.toggle()
        withAnimation(AppAnimation.quick) {
            self.showsVolumeOverlay.toggle()
        }
    }

    /// Performs the actual seek operation after slider interaction ends.
    private func performSeek() {
        guard self.isSeeking, self.playerService.duration > 0 else { return }
        let seekTime = self.seekValue * self.playerService.duration
        let holdID = self.seekHold.begin(target: seekTime)
        self.updateFormattedTimes(progress: seekTime, duration: self.playerService.duration)
        self.isSeeking = false

        Task {
            await self.playerService.seek(to: seekTime)
        }
        Task { @MainActor in
            try? await Task.sleep(for: PlayerBarSeekHold.timeout)
            if self.seekHold.clearIfCurrent(holdID) {
                self.syncSeekValueFromDisplayedProgress()
                self.updateFormattedTimes(
                    progress: self.displayedPlaybackProgress,
                    duration: self.playerService.duration
                )
            }
        }
    }

    private func seek(to segment: PlayerBarProgressSegment) {
        guard self.canSeek else { return }
        self.isSeeking = true
        // Segment boundaries and `seekValue` use the same normalized 0...1 coordinate space.
        self.seekValue = segment.start
        self.performSeek()
    }

    private func clearSeekHold() {
        self.seekHold.clear()
        self.isSeeking = false
        self.syncSeekValueFromDisplayedProgress()
        self.updateFormattedTimes(
            progress: self.displayedPlaybackProgress,
            duration: self.playerService.duration
        )
    }

    private func syncSeekValueFromDisplayedProgress() {
        if self.playerService.duration > 0 {
            self.seekValue = self.displayedPlaybackProgress / self.playerService.duration
        } else {
            self.seekValue = 0
        }
    }

    private func updateFormattedTimes(progress: TimeInterval, duration: TimeInterval) {
        self.formattedProgress = self.formatTime(progress)
        self.formattedRemaining = "-\(self.formatTime(max(0, duration - progress)))"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        } else {
            return String(format: "%d:%02d", mins, secs)
        }
    }

    private var volumeIcon: String {
        let currentVolume = self.isAdjustingVolume ? self.volumeValue : self.playerService.volume
        if currentVolume == 0 {
            return "speaker.slash.fill"
        } else if currentVolume < 0.5 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }

    private var repeatIconName: String {
        self.playerService.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var repeatAccessibilityValue: String {
        switch self.playerService.repeatMode {
        case .off:
            String(localized: "Off")
        case .all:
            String(localized: "All")
        case .one:
            String(localized: "One")
        }
    }
}

#Preview {
    PlayerBar()
        .environment(PlayerService())
        .environment(AuthService())
        .environment(FavoritesManager.shared)
        .environment(SongLikeStatusManager.shared)
        .frame(width: 810)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}
