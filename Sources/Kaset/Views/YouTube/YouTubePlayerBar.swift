import SwiftUI

// MARK: - YouTubePlayerBar

/// The Liquid Glass player bar, adapted for YouTube video playback.
///
/// Same capsule, sizing, and interaction patterns as the music `PlayerBar`
/// (which is untouched); shown instead of it while a YouTube video is
/// loaded. Differences per the YouTube content model:
/// - No shuffle/repeat — previous/next skip between videos
///   (session history / the watch page's related list).
/// - Center shows the video thumbnail, title, and channel · views.
/// - No lyrics/queue buttons.
/// - The minimize button drives the video pop-out (picture in picture);
///   the TV button toggles fullscreen on the popped-out window.
struct YouTubePlayerBar: View {
    private static let brandAccent = PackageResourceLookup.brandAccent

    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Namespace for glass effect morphing.
    @Namespace private var playerNamespace

    @State private var isHoveringSeekBar = false
    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            HStack(spacing: 0) {
                self.playbackControls

                Spacer()

                self.centerSection

                Spacer()

                self.rightSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
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
            if !self.isSeeking, self.youtubePlayer.duration > 0 {
                self.seekValue = newValue / self.youtubePlayer.duration
            }
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
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.playerBar)
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

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 16) {
            // Previous video (session history; restarts when none)
            Button {
                HapticService.playback()
                self.youtubePlayer.skipBackward()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.pressable)
            .disabled(self.youtubePlayer.currentVideo == nil)
            .accessibilityLabel(String(localized: "Previous video"))

            // Play/Pause
            Button {
                HapticService.playback()
                self.youtubePlayer.playPause()
            } label: {
                Image(systemName: self.youtubePlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .compatGlassID("youtubePlayPause", in: self.playerNamespace)
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchPlayPause)
            .disabled(self.youtubePlayer.currentVideo == nil)
            .accessibilityLabel(
                self.youtubePlayer.isPlaying
                    ? String(localized: "Pause")
                    : String(localized: "Play")
            )

            // Next video (up next from the watch page)
            Button {
                HapticService.playback()
                Task {
                    await self.youtubePlayer.skipForward()
                }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.pressable)
            .disabled(self.youtubePlayer.currentVideo == nil)
            .accessibilityLabel(String(localized: "Next video"))
        }
    }

    // MARK: - Center Section (video info ⇄ full-width seek scrubber on hover)

    private var centerSection: some View {
        ZStack {
            // Video info — top-aligned so it lifts off the bottom progress line.
            VStack(spacing: 0) {
                self.videoInfoView
                Spacer(minLength: 0)
            }
            .blur(radius: self.showsSeekControls ? 8 : 0)
            .opacity(self.showsSeekControls ? 0 : 1)

            // Thin idle progress line ⇄ full-width hover scrubber.
            if self.youtubePlayer.currentVideo != nil {
                self.seekOverlay
            }
        }
        .frame(maxWidth: 540, minHeight: 38)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(self.hoverAnimation) {
                self.isHoveringSeekBar = hovering
            }
        }
    }

    private var showsSeekControls: Bool {
        self.isHoveringSeekBar && self.youtubePlayer.currentVideo != nil
    }

    /// Hover grow/shrink animation, honouring Reduce Motion.
    private var hoverAnimation: Animation {
        self.reduceMotion ? .easeInOut(duration: 0.12) : AppAnimation.snappy
    }

    /// Fraction (0...1) to render: the live drag value while seeking, otherwise actual progress.
    private var displayFraction: Double {
        if self.isSeeking {
            return min(max(0, self.seekValue), 1)
        }
        guard self.youtubePlayer.duration > 0 else { return 0 }
        return min(max(0, self.youtubePlayer.progress / self.youtubePlayer.duration), 1)
    }

    private var videoInfoView: some View {
        HStack(spacing: 8) {
            // 16:9 video thumbnail
            CachedAsyncImage(
                url: self.youtubePlayer.currentVideo?.thumbnailURL,
                targetSize: CGSize(width: 128, height: 72)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 57, height: 32)
            .clipShape(.rect(cornerRadius: 4))

            if let video = self.youtubePlayer.currentVideo {
                VStack(alignment: .leading, spacing: 0) {
                    Text(video.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if let channelName = video.channelName, !channelName.isEmpty {
                        Text(channelName)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 240, alignment: .leading)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Seek Overlay (full-width: thin idle line ⇄ hover scrubber)

    private var seekOverlay: some View {
        ZStack {
            // Full-width hover scrubber (elapsed · long bar · remaining).
            AppleMusicScrubber(
                fraction: self.displayFraction,
                accent: Self.brandAccent,
                elapsedText: Self.formatTime(self.isSeeking
                    ? self.seekValue * self.youtubePlayer.duration
                    : self.youtubePlayer.progress),
                remainingText: "-\(Self.formatTime(self.youtubePlayer.duration - (self.isSeeking ? self.seekValue * self.youtubePlayer.duration : self.youtubePlayer.progress)))",
                isInteractive: self.showsSeekControls && self.canSeek,
                onScrub: { fraction in
                    self.isSeeking = true
                    self.seekValue = fraction
                },
                onCommit: {
                    self.performSeek()
                }
            )
            .opacity(self.showsSeekControls ? 1 : 0)
            .allowsHitTesting(self.showsSeekControls && self.canSeek)

            // Thin idle progress line shown when not hovering.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                IdleProgressLine(fraction: self.displayFraction)
            }
            .opacity(self.showsSeekControls ? 0 : 1)
            .allowsHitTesting(false)
        }
    }

    /// Seeking is unavailable during ads or before a duration is known.
    private var canSeek: Bool {
        self.youtubePlayer.duration > 0 && !self.youtubePlayer.isShowingAd
    }

    private func performSeek() {
        guard self.isSeeking else { return }
        self.youtubePlayer.seek(to: self.seekValue * self.youtubePlayer.duration)
        self.isSeeking = false
    }

    // MARK: - Right Section (actions + volume)

    private var rightSection: some View {
        HStack(spacing: 8) {
            self.actionButtons

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            Image(systemName: self.volumeIcon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 18)

            self.volumeSlider
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Like
            Button {
                Task {
                    await self.youtubePlayer.toggleLike()
                }
            } label: {
                Image(systemName: self.youtubePlayer.currentRating == .like
                    ? "hand.thumbsup.fill"
                    : "hand.thumbsup")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.youtubePlayer.currentRating == .like ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .symbolEffect(.bounce, value: self.youtubePlayer.currentRating == .like)
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchLikeButton)
            .disabled(self.youtubePlayer.currentVideo == nil)
            .accessibilityLabel(String(localized: "Like"))

            // Dislike
            Button {
                Task {
                    await self.youtubePlayer.toggleDislike()
                }
            } label: {
                Image(systemName: self.youtubePlayer.currentRating == .dislike
                    ? "hand.thumbsdown.fill"
                    : "hand.thumbsdown")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.youtubePlayer.currentRating == .dislike ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .symbolEffect(.bounce, value: self.youtubePlayer.currentRating == .dislike)
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchDislikeButton)
            .disabled(self.youtubePlayer.currentVideo == nil)
            .accessibilityLabel(String(localized: "Dislike"))

            // Full view — expands the pop-out window to fullscreen
            Button {
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
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchFullView)
            .disabled(self.youtubePlayer.currentVideo == nil)
            .accessibilityLabel(String(localized: "Full view"))

            // Watch Later (in the TV button's old slot, ahead of AirPlay)
            Button {
                Task {
                    await self.youtubePlayer.toggleWatchLater()
                }
            } label: {
                Image(systemName: self.youtubePlayer.isInWatchLater
                    ? "checkmark.circle.fill"
                    : "clock.badge.plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.youtubePlayer.isInWatchLater ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .symbolEffect(.bounce, value: self.youtubePlayer.isInWatchLater)
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchLaterButton)
            .disabled(self.youtubePlayer.currentVideo == nil)
            .accessibilityLabel(String(localized: "Add to Watch Later"))

            // AirPlay
            Button {
                HapticService.toggle()
                self.youtubePlayer.showAirPlayPicker()
            } label: {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
            .buttonStyle(.pressable)
            .disabled(self.youtubePlayer.currentVideo == nil)
            .accessibilityLabel(String(localized: "AirPlay"))

            self.captionsMenu

            self.qualityMenu

            // Picture in picture (pop out / pop in) — hidden in fullscreen,
            // where popping in/out makes no sense.
            if !self.youtubePlayer.isWindowFullscreen {
                Button {
                    HapticService.toggle()
                    if self.youtubePlayer.surfaceLocation == .floating {
                        self.youtubePlayer.requestPopIn()
                    } else {
                        self.youtubePlayer.popOutToWindow()
                    }
                } label: {
                    Image(systemName: self.youtubePlayer.surfaceLocation == .floating
                        ? "pip.exit"
                        : "pip.enter")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(self.youtubePlayer.surfaceLocation == .floating ? .red : .primary.opacity(0.85))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchPictureInPicture)
                .disabled(self.youtubePlayer.currentVideo == nil)
                .accessibilityLabel(
                    self.youtubePlayer.surfaceLocation == .floating
                        ? String(localized: "Pop video back into Kaset")
                        : String(localized: "Picture in Picture")
                )
            }
        }
    }

    // MARK: - Captions & Quality Menus

    private var captionsMenu: some View {
        Menu {
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
        } label: {
            Image(systemName: self.youtubePlayer.activeCaptionLanguageCode == nil
                ? "captions.bubble"
                : "captions.bubble.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(self.youtubePlayer.activeCaptionLanguageCode != nil ? .red : .primary.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(self.youtubePlayer.currentVideo == nil)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.captionsButton)
        .accessibilityLabel(String(localized: "Closed captions"))
    }

    private var qualityMenu: some View {
        Menu {
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
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(self.youtubePlayer.qualityLevels.isEmpty)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.qualityButton)
        .accessibilityLabel(String(localized: "Video quality"))
    }

    private var volumeSlider: some View {
        Slider(value: self.$volumeValue, in: 0 ... 1) { editing in
            if editing {
                self.isAdjustingVolume = true
            } else {
                self.youtubePlayer.volume = self.volumeValue
                self.isAdjustingVolume = false
            }
        }
        .controlSize(.small)
        .frame(width: 80)
        .tint(Self.brandAccent)
        .accessibilityLabel(String(localized: "Volume"))
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
    static let playerBar = "youtubeContent.playerBar"
    static let watchPlayPause = "youtubeContent.watchPlayPause"
    static let watchLikeButton = "youtubeContent.watchLikeButton"
    static let watchDislikeButton = "youtubeContent.watchDislikeButton"
    static let watchLaterButton = "youtubeContent.watchLaterButton"
    static let watchPictureInPicture = "youtubeContent.watchPictureInPicture"
    static let watchFullView = "youtubeContent.watchFullView"
    static let captionsButton = "youtubeContent.captionsButton"
    static let qualityButton = "youtubeContent.qualityButton"
}
