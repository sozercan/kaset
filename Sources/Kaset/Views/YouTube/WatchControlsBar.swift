import SwiftUI

// MARK: - WatchControlsBar

/// Native Liquid Glass control strip for YouTube video playback:
/// play/pause, scrubber with time labels, volume, and pop-out.
struct WatchControlsBar: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    /// Local seek value for smooth dragging without a JS call per tick.
    @State private var seekValue: Double = 0
    @State private var isSeeking = false

    var body: some View {
        Group {
            if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                self.controls
                    .glassEffect(.regular.interactive(), in: .capsule)
            } else {
                self.controls
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchControls)
    }

    private var controls: some View {
        HStack(spacing: 12) {
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
                .foregroundStyle(.secondary)

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
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { self.youtubePlayer.volume },
                        set: { self.youtubePlayer.volume = $0 }
                    ),
                    in: 0 ... 1
                )
                .controlSize(.mini)
                .frame(width: 70)
                .accessibilityLabel(String(localized: "Volume"))
            }

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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
}
