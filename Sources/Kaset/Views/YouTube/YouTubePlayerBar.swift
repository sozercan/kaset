import SwiftUI

// MARK: - YouTubePlayerBar

/// The Liquid Glass player bar, adapted for YouTube video playback.
///
/// Same capsule, sizing, and interaction patterns as the music `PlayerBar`
/// (which is untouched); shown instead of it while a YouTube video is
/// loaded. Differences per the YouTube content model:
/// - No shuffle/repeat — left/right transport controls seek 30 seconds
///   back/forward within the current video.
/// - Center shows the video thumbnail, title, and channel · views.
/// - No lyrics/queue buttons.
/// - The minimize button drives the video pop-out (picture in picture);
///   the TV button toggles fullscreen on the popped-out window.
struct YouTubePlayerBar: View {
    private static let brandAccent = PackageResourceLookup.brandAccent
    private static let fullVideoDetailsWidth: CGFloat = 294
    private static let compactVideoDetailsWidth: CGFloat = 141

    @Environment(AuthService.self) private var authService
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(YouTubeViewModelStore.self) private var youtubeStore: YouTubeViewModelStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Namespace for glass effect morphing.
    @Namespace private var playerNamespace

    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var seekHold = PlayerBarSeekHold()
    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false
    @State private var showsVolumeOverlay = false

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            GeometryReader { proxy in
                let usesCompactDetails = proxy.size.width <= PlayerBarLayout.compactDetailsBreakpoint

                HStack(spacing: 10) {
                    self.videoDetailsSection(usesCompactDetails: usesCompactDetails)
                        .frame(
                            width: usesCompactDetails ? Self.compactVideoDetailsWidth : Self.fullVideoDetailsWidth,
                            height: 52
                        )

                    self.youtubeProgressSection
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)

                    self.youtubeOptionsSection
                        .frame(width: self.youtubeOptionsWidth, height: 52)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .compatGlass(interactive: true, in: .capsule)
            .compatGlassID("youtubePlayerBar", in: self.playerNamespace)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(alignment: .bottom) {
            self.playerAreaFade
        }
        .onChange(of: self.youtubePlayer.progress) { _, newValue in
            self.seekHold.reconcile(observedProgress: newValue)
            if !self.isSeeking, !self.seekHold.isActive, self.youtubePlayer.duration > 0 {
                self.seekValue = self.displayedPlaybackProgress / self.youtubePlayer.duration
            }
        }
        .onChange(of: self.youtubePlayer.duration) { _, newValue in
            self.seekHold.reconcile(observedProgress: self.youtubePlayer.progress)
            if !self.isSeeking, !self.seekHold.isActive, newValue > 0 {
                self.seekValue = self.displayedPlaybackProgress / newValue
            }
        }
        .onChange(of: self.currentSeekIdentity) { _, _ in
            self.clearSeekHold()
        }
        .onChange(of: self.youtubePlayer.volume) { _, newValue in
            if !self.isAdjustingVolume {
                self.volumeValue = newValue
            }
        }
        .onAppear {
            self.volumeValue = self.youtubePlayer.volume
            if self.youtubePlayer.duration > 0 {
                self.seekValue = self.youtubePlayer.progress / self.youtubePlayer.duration
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

    // MARK: - Updated Player Layout

    private func videoDetailsSection(usesCompactDetails: Bool) -> some View {
        HStack(spacing: 8) {
            PlayerBarArtworkView(
                width: 57,
                height: 32,
                cornerRadius: 6,
                glowSources: self.currentVideoGlowSources,
                glowIdentity: self.currentVideoGlowIdentity,
                glowTargetSize: CGSize(width: 128, height: 72),
                showsHoverOverlay: false
            ) {
                CachedAsyncImage(
                    url: self.youtubePlayer.currentVideo?.thumbnailURL,
                    targetSize: CGSize(width: 128, height: 72)
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 57, height: 32)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
            }
            .accessibilityHidden(self.youtubePlayer.currentVideo == nil)

            if !usesCompactDetails {
                VStack(alignment: .leading, spacing: 4) {
                    PlayerBarMarqueeText(
                        text: self.youtubePlayer.currentVideo?.title ?? String(localized: "Not Playing"),
                        font: .system(size: 13),
                        color: .primary,
                        height: 13,
                        reduceMotion: self.reduceMotion
                    )
                    .id(self.currentTitleIdentity)

                    PlayerBarMetadataButton(
                        text: self.youtubePlayer.currentVideo?.channelName ?? String(localized: "YouTube"),
                        isEnabled: self.canNavigateToCurrentChannel,
                        action: self.openCurrentChannel
                    )
                }
                .frame(width: 129, height: 29, alignment: .leading)
            }

            if self.hasPersonalAccount {
                HStack(spacing: 6) {
                    PlayerBarIconButton(
                        action: {
                            Task {
                                await self.youtubePlayer.toggleLike()
                            }
                        },
                        isSelected: self.youtubePlayer.currentRating == .like,
                        accessibilityID: AccessibilityID.YouTubeContent.watchLikeButton,
                        accessibilityLabel: String(localized: "Like"),
                        icon: {
                            Image(systemName: self.youtubePlayer.currentRating == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.system(size: 16, weight: .regular))
                                .frame(width: 10, height: 16)
                                .foregroundStyle(self.youtubePlayer.currentRating == .like ? Self.brandAccent : .primary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    )
                    .symbolEffect(.bounce, value: self.youtubePlayer.currentRating == .like)
                    .disabled(self.youtubePlayer.currentVideo == nil)

                    PlayerBarIconButton(
                        action: {
                            Task {
                                await self.youtubePlayer.toggleDislike()
                            }
                        },
                        isSelected: self.youtubePlayer.currentRating == .dislike,
                        accessibilityID: AccessibilityID.YouTubeContent.watchDislikeButton,
                        accessibilityLabel: String(localized: "Dislike"),
                        icon: {
                            Image(systemName: self.youtubePlayer.currentRating == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .font(.system(size: 16, weight: .regular))
                                .frame(width: 10, height: 16)
                                .foregroundStyle(self.youtubePlayer.currentRating == .dislike ? Self.brandAccent : .primary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    )
                    .symbolEffect(.bounce, value: self.youtubePlayer.currentRating == .dislike)
                    .disabled(self.youtubePlayer.currentVideo == nil)
                }
            }
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private var currentVideoGlowSources: [URL] {
        guard let video = self.youtubePlayer.currentVideo else { return [] }
        return self.uniqueURLs([
            self.fallbackThumbnailURL(for: video.videoId),
            video.thumbnailURL,
        ])
    }

    private var currentVideoGlowIdentity: String? {
        guard let video = self.youtubePlayer.currentVideo else { return nil }
        return video.videoId
    }

    private func fallbackThumbnailURL(for videoId: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")
    }

    private func uniqueURLs(_ urls: [URL?]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { url in
            guard let url, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    private var currentTitleIdentity: String {
        [
            self.youtubePlayer.currentVideo?.id ?? "none",
            self.youtubePlayer.currentVideo?.title ?? "none",
        ].joined(separator: "|")
    }

    private var youtubeProgressSection: some View {
        ZStack(alignment: .top) {
            PlayerBarProgressLane(
                fraction: self.displayFraction,
                accent: Self.brandAccent,
                elapsedText: Self.formatTime(self.progressTextValue),
                remainingText: "-\(Self.formatTime(max(0, self.youtubePlayer.duration - self.progressTextValue)))",
                isLive: false,
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

            self.youtubeTransportControls
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var youtubeTransportControls: some View {
        HStack(spacing: 6) {
            PlayerBarIconButton(
                action: {
                    HapticService.playback()
                    self.youtubePlayer.seekBackward()
                },
                accessibilityLabel: String(localized: "Back 30 seconds"),
                icon: {
                    Image(systemName: "gobackward.30")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.primary)
                }
            )
            .disabled(!self.canSeek)

            PlayerBarIconButton(
                action: {
                    HapticService.playback()
                    self.youtubePlayer.playPause()
                },
                accessibilityID: AccessibilityID.YouTubeContent.watchPlayPause,
                accessibilityLabel: self.youtubePlayer.isPlaying ? String(localized: "Pause") : String(localized: "Play"),
                icon: {
                    Image(systemName: self.youtubePlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 12, height: 20)
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
            )
            .compatGlassID("youtubePlayPause", in: self.playerNamespace)
            .disabled(self.youtubePlayer.currentVideo == nil)

            PlayerBarIconButton(
                action: {
                    HapticService.playback()
                    self.youtubePlayer.seekForward()
                },
                accessibilityLabel: String(localized: "Forward 30 seconds"),
                icon: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.primary)
                }
            )
            .disabled(!self.canSeek)

            PlayerBarIconButton(
                action: self.toggleYouTubeVolumeOverlay,
                accessibilityLabel: String(localized: "Volume"),
                icon: {
                    Image(systemName: self.volumeIcon)
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 10, height: 15)
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
            )
            .overlay(alignment: .top) {
                if self.showsVolumeOverlay {
                    self.youtubeVolumeOverlay
                        .offset(y: -176)
                        .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
            }
        }
    }

    private var youtubeOptionsSection: some View {
        HStack(spacing: 6) {
            PlayerBarIconButton(
                action: self.openYouTubeFullView,
                accessibilityID: AccessibilityID.YouTubeContent.watchFullView,
                accessibilityLabel: String(localized: "Full view"),
                icon: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.primary)
                }
            )
            .disabled(self.youtubePlayer.currentVideo == nil)

            if self.hasPersonalAccount {
                PlayerBarIconButton(
                    action: {
                        Task {
                            await self.youtubePlayer.toggleWatchLater()
                        }
                    },
                    isSelected: self.youtubePlayer.isInWatchLater,
                    accessibilityID: AccessibilityID.YouTubeContent.watchLaterButton,
                    accessibilityLabel: String(localized: "Add to Watch Later"),
                    icon: {
                        Image(systemName: self.youtubePlayer.isInWatchLater ? "clock.fill" : "clock")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 16, height: 16)
                            .foregroundStyle(self.youtubePlayer.isInWatchLater ? Self.brandAccent : .primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                )
                .symbolEffect(.bounce, value: self.youtubePlayer.isInWatchLater)
                .disabled(self.youtubePlayer.currentVideo == nil)
            }

            PlayerBarIconButton(
                action: {
                    HapticService.toggle()
                    self.youtubePlayer.showAirPlayPicker()
                },
                accessibilityLabel: String(localized: "AirPlay"),
                icon: {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 10, height: 16)
                        .foregroundStyle(.primary)
                }
            )
            .disabled(self.youtubePlayer.currentVideo == nil)

            self.compactCaptionsMenu
            self.compactQualityMenu

            PlayerBarIconButton(
                action: self.toggleYouTubePictureInPicture,
                isSelected: self.youtubePlayer.surfaceLocation == .floating,
                accessibilityID: AccessibilityID.YouTubeContent.watchPictureInPicture,
                accessibilityLabel: self.youtubePlayer.surfaceLocation == .floating
                    ? String(localized: "Pop video back into Kaset")
                    : String(localized: "Picture in Picture")
            ) {
                Image(systemName: self.youtubePlayer.surfaceLocation == .floating ? "pip.exit" : "pip.enter")
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 13, height: 14)
                    .foregroundStyle(self.youtubePlayer.surfaceLocation == .floating ? Self.brandAccent : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(self.youtubePlayer.currentVideo == nil || self.youtubePlayer.isWindowFullscreen)
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private var compactCaptionsMenu: some View {
        PlayerBarIconMenu(
            isSelected: self.youtubePlayer.activeCaptionLanguageCode != nil,
            accessibilityID: AccessibilityID.YouTubeContent.captionsButton,
            accessibilityLabel: String(localized: "Closed captions")
        ) {
            Button {
                self.youtubePlayer.selectCaptionTrack(languageCode: nil)
            } label: {
                if self.youtubePlayer.activeCaptionLanguageCode == nil {
                    Label(String(localized: "Off"), systemImage: "checkmark")
                } else {
                    Text("Off", comment: "Captions off menu item")
                }
            }

            ForEach(self.youtubePlayer.captionTracks) { track in
                Button {
                    self.youtubePlayer.selectCaptionTrack(languageCode: track.languageCode)
                } label: {
                    if self.youtubePlayer.activeCaptionLanguageCode == track.languageCode {
                        Label(track.displayName, systemImage: "checkmark")
                    } else {
                        Text(track.displayName)
                    }
                }
            }
        } icon: {
            Image(systemName: self.youtubePlayer.activeCaptionLanguageCode == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 16, height: 16)
                .foregroundStyle(self.youtubePlayer.activeCaptionLanguageCode == nil ? .primary : Self.brandAccent)
        }
        .disabled(self.youtubePlayer.currentVideo == nil)
    }

    private var compactQualityMenu: some View {
        PlayerBarIconMenu(
            accessibilityID: AccessibilityID.YouTubeContent.qualityButton,
            accessibilityLabel: String(localized: "Video quality")
        ) {
            ForEach(self.youtubePlayer.qualityLevels, id: \.self) { level in
                Button {
                    self.youtubePlayer.selectQuality(level)
                } label: {
                    if self.youtubePlayer.currentQuality == level {
                        Label(YouTubeQuality.displayName(for: level), systemImage: "checkmark")
                    } else {
                        Text(YouTubeQuality.displayName(for: level))
                    }
                }
            }
        } icon: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary)
        }
        .disabled(self.youtubePlayer.qualityLevels.isEmpty)
    }

    private var youtubeVolumeOverlay: some View {
        CompatGlassContainer(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: self.volumeIcon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)

                PlayerBarVerticalSlider(
                    value: self.$volumeValue,
                    accent: Self.brandAccent,
                    accessibilityIdentifier: nil,
                    accessibilityLabel: String(localized: "Volume"),
                    onEditingChanged: { editing in
                        self.isAdjustingVolume = editing
                        if !editing {
                            self.youtubePlayer.volume = self.volumeValue
                        }
                    },
                    onValueChanged: { oldValue, newValue in
                        if self.isAdjustingVolume {
                            if (oldValue > 0 && newValue == 0) || (oldValue < 1 && newValue == 1) {
                                HapticService.sliderBoundary()
                            }
                            self.youtubePlayer.volume = newValue
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

    private var youtubeOptionsWidth: CGFloat {
        210
    }

    /// Fraction (0...1) to render: the live drag value while seeking, otherwise actual progress.
    private var displayFraction: Double {
        if self.isSeeking {
            return min(max(0, self.seekValue), 1)
        }
        guard self.youtubePlayer.duration > 0 else { return 0 }
        return min(max(0, self.displayedPlaybackProgress / self.youtubePlayer.duration), 1)
    }

    private var progressTextValue: TimeInterval {
        self.isSeeking ? self.seekValue * self.youtubePlayer.duration : self.displayedPlaybackProgress
    }

    private var displayedPlaybackProgress: TimeInterval {
        self.seekHold.displayProgress(observedProgress: self.youtubePlayer.progress)
    }

    private var currentSeekIdentity: String {
        self.youtubePlayer.currentVideo?.videoId ?? "none"
    }

    /// Seeking is unavailable during ads or before a duration is known.
    private var canSeek: Bool {
        self.youtubePlayer.duration > 0 && !self.youtubePlayer.isShowingAd
    }

    private var isProgressLoading: Bool {
        self.youtubePlayer.isPlaybackLoading
    }

    private var canNavigateToCurrentChannel: Bool {
        self.youtubeStore != nil && self.currentChannelId != nil
    }

    private var currentChannelId: String? {
        guard let channelId = self.youtubePlayer.currentVideo?.channelId, !channelId.isEmpty else {
            return nil
        }
        return channelId
    }

    private func openCurrentChannel() {
        guard let channelId = self.currentChannelId else { return }
        self.youtubeStore?.navigationPath.append(YouTubeRoute.channel(channelId: channelId))
    }

    private func performSeek() {
        guard self.isSeeking else { return }
        let seekTime = self.seekValue * self.youtubePlayer.duration
        let holdID = self.seekHold.begin(target: seekTime)
        self.isSeeking = false
        self.youtubePlayer.seek(to: seekTime)

        Task { @MainActor in
            try? await Task.sleep(for: PlayerBarSeekHold.timeout)
            if self.seekHold.clearIfCurrent(holdID) {
                self.syncSeekValueFromDisplayedProgress()
            }
        }
    }

    private func clearSeekHold() {
        self.seekHold.clear()
        self.isSeeking = false
        self.syncSeekValueFromDisplayedProgress()
    }

    private func syncSeekValueFromDisplayedProgress() {
        if self.youtubePlayer.duration > 0 {
            self.seekValue = self.displayedPlaybackProgress / self.youtubePlayer.duration
        } else {
            self.seekValue = 0
        }
    }

    private var volumeIcon: String {
        let currentVolume = self.isAdjustingVolume ? self.volumeValue : self.youtubePlayer.volume
        if currentVolume == 0 {
            return "speaker.slash.fill"
        } else if currentVolume < 0.5 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }

    private func toggleYouTubeVolumeOverlay() {
        HapticService.toggle()
        withAnimation(AppAnimation.quick) {
            self.showsVolumeOverlay.toggle()
        }
    }

    private func openYouTubeFullView() {
        HapticService.toggle()
        if self.youtubePlayer.surfaceLocation == .inline {
            self.youtubePlayer.popOutToWindow()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                YouTubeVideoWindowController.shared.toggleFullscreen(returnInlineOnExit: true)
            }
        } else {
            YouTubeVideoWindowController.shared.toggleFullscreen()
        }
    }

    private func toggleYouTubePictureInPicture() {
        guard !self.youtubePlayer.isWindowFullscreen else { return }
        HapticService.toggle()
        if self.youtubePlayer.surfaceLocation == .floating {
            self.youtubePlayer.requestPopIn()
        } else {
            self.youtubePlayer.popOutToWindow()
        }
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Per-View Inset

extension View {
    /// Attaches the YouTube player bar to the bottom of a navigable view.
    ///
    /// Applied to EVERY YouTube view (roots and pushed destinations) —
    /// views pushed onto a `NavigationStack` do not inherit a parent's
    /// `safeAreaInset`, the same rule the music side follows with
    /// `PlayerBar` (see docs/architecture.md).
    func youtubePlayerBarInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            YouTubePlayerBar()
        }
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let watchPlayPause = "youtubeContent.watchPlayPause"
    static let watchLikeButton = "youtubeContent.watchLikeButton"
    static let watchDislikeButton = "youtubeContent.watchDislikeButton"
    static let watchLaterButton = "youtubeContent.watchLaterButton"
    static let watchPictureInPicture = "youtubeContent.watchPictureInPicture"
    static let watchFullView = "youtubeContent.watchFullView"
    static let captionsButton = "youtubeContent.captionsButton"
    static let qualityButton = "youtubeContent.qualityButton"
}
