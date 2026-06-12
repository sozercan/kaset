import SwiftUI

// MARK: - WatchControlsBar

/// Native playback control strip overlaid INSIDE the video surface:
/// play/pause, scrubber with time labels, volume, like/dislike,
/// pop-out (or pop-in when floating), and fullscreen.
struct WatchControlsBar: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    /// Local seek value for smooth dragging without a JS call per tick.
    @State private var seekValue: Double = 0
    @State private var isSeeking = false

    var body: some View {
        self.controls
            .background(.black.opacity(0.55), in: Capsule())
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchControls)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                self.youtubePlayer.playPause()
                HapticService.playback()
            } label: {
                Image(systemName: self.youtubePlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                self.youtubePlayer.isPlaying
                    ? String(localized: "Pause")
                    : String(localized: "Play")
            )
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchPlayPause)

            Text(Self.timeText(self.isSeeking ? self.seekValue : self.youtubePlayer.progress))
                .font(.system(size: 11).monospacedDigit())

            Slider(
                value: Binding(
                    get: {
                        self.isSeeking ? self.seekValue : self.youtubePlayer.progress
                    },
                    set: { newValue in
                        self.seekValue = newValue
                    }
                ),
                in: 0 ... max(self.youtubePlayer.duration, 1)
            ) { editing in
                if editing {
                    self.isSeeking = true
                } else {
                    self.isSeeking = false
                    self.youtubePlayer.seek(to: self.seekValue)
                }
            }
            .controlSize(.small)
            .disabled(self.youtubePlayer.duration <= 0 || self.youtubePlayer.isShowingAd)
            .accessibilityLabel(String(localized: "Seek"))

            Text(Self.timeText(self.youtubePlayer.duration))
                .font(.system(size: 11).monospacedDigit())

            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))

                Slider(
                    value: Binding(
                        get: { self.youtubePlayer.volume },
                        set: { self.youtubePlayer.volume = $0 }
                    ),
                    in: 0 ... 1
                )
                .controlSize(.mini)
                .frame(width: 56)
                .accessibilityLabel(String(localized: "Volume"))
            }

            Divider()
                .frame(height: 16)

            self.likeDislikeButtons

            Divider()
                .frame(height: 16)

            self.popButton

            self.fullscreenButton
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Like / Dislike

    private var likeDislikeButtons: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await self.youtubePlayer.toggleLike()
                }
            } label: {
                Image(
                    systemName: self.youtubePlayer.currentRating == .like
                        ? "hand.thumbsup.fill"
                        : "hand.thumbsup"
                )
                .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Like"))
            .accessibilityLabel(String(localized: "Like video"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchLikeButton)

            Button {
                Task {
                    await self.youtubePlayer.toggleDislike()
                }
            } label: {
                Image(
                    systemName: self.youtubePlayer.currentRating == .dislike
                        ? "hand.thumbsdown.fill"
                        : "hand.thumbsdown"
                )
                .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Dislike"))
            .accessibilityLabel(String(localized: "Dislike video"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchDislikeButton)
        }
    }

    // MARK: - Pop Out / Pop In

    @ViewBuilder
    private var popButton: some View {
        if self.youtubePlayer.surfaceLocation == .floating {
            Button {
                self.youtubePlayer.requestPopIn()
                HapticService.toggle()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Pop video back into Kaset"))
            .accessibilityLabel(String(localized: "Pop video back into Kaset"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchPopIn)
        } else {
            Button {
                self.youtubePlayer.popOutToWindow()
                HapticService.toggle()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Pop out video"))
            .accessibilityLabel(String(localized: "Pop out video"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchPopOut)
        }
    }

    // MARK: - Fullscreen

    private var fullscreenButton: some View {
        Button {
            if self.youtubePlayer.surfaceLocation == .inline {
                // Fullscreen plays in the floating window: pop out first,
                // then expand it once it exists.
                self.youtubePlayer.popOutToWindow()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    YouTubeVideoWindowController.shared.toggleFullscreen()
                }
            } else {
                YouTubeVideoWindowController.shared.toggleFullscreen()
            }
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Fullscreen"))
        .accessibilityLabel(String(localized: "Fullscreen"))
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchFullscreen)
    }

    /// Formats seconds as m:ss or h:mm:ss.
    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let watchControls = "youtubeContent.watchControls"
    static let watchPlayPause = "youtubeContent.watchPlayPause"
    static let watchPopOut = "youtubeContent.watchPopOut"
    static let watchPopIn = "youtubeContent.watchPopIn"
    static let watchLikeButton = "youtubeContent.watchLikeButton"
    static let watchDislikeButton = "youtubeContent.watchDislikeButton"
    static let watchFullscreen = "youtubeContent.watchFullscreen"
}
