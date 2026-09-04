import SwiftUI

/// Media playback control section for the Spotlight view including seek bar, repeat, shuffle, and volume controls.
struct SpotlightControlsSection: View {
    let isPlaying: Bool
    let progress: TimeInterval
    let duration: TimeInterval
    let volume: Double
    let isMuted: Bool
    let onPlayPause: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onVolumeChange: (Double) -> Void
    let onToggleMute: () -> Void

    @State private var isShuffleActive = false
    @State private var repeatState: Int = 0 // 0: off, 1: all, 2: one

    var body: some View {
        VStack(spacing: 20) {
            // Scrubber Progress Lane
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { self.progress },
                        set: { newValue in self.onSeek(newValue) }
                    ),
                    in: 0 ... max(1, self.duration)
                )
                .tint(.primary)

                HStack {
                    Text(Self.formatTime(self.progress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("-" + Self.formatTime(max(0, self.duration - self.progress)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 48)

            // Primary Playback Controls Bar
            HStack(spacing: 36) {
                // Shuffle button toggle
                Button(action: { self.isShuffleActive.toggle() }, label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 18, weight: self.isShuffleActive ? .bold : .regular))
                        .foregroundStyle(self.isShuffleActive ? Color.accentColor : Color.secondary)
                })
                .buttonStyle(.plain)

                // Previous track
                Button(action: self.onPrevious, label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.primary)
                })
                .buttonStyle(.plain)

                // Play / Pause button
                Button(action: self.onPlayPause, label: {
                    Image(systemName: self.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.primary)
                })
                .buttonStyle(.plain)

                // Next track
                Button(action: self.onNext, label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.primary)
                })
                .buttonStyle(.plain)

                // Repeat button toggle
                Button(action: { self.repeatState = (self.repeatState + 1) % 3 }, label: {
                    Image(systemName: self.repeatState == 2 ? "repeat.1" : "repeat")
                        .font(.system(size: 18, weight: self.repeatState > 0 ? .bold : .regular))
                        .foregroundStyle(self.repeatState > 0 ? Color.accentColor : Color.secondary)
                })
                .buttonStyle(.plain)
            }

            // Volume Control Slider Lane
            HStack(spacing: 12) {
                Button(action: self.onToggleMute) {
                    Image(systemName: self.isMuted || self.volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { self.isMuted ? 0.0 : self.volume },
                        set: { newValue in self.onVolumeChange(newValue) }
                    ),
                    in: 0.0 ... 1.0
                )
                .tint(.primary)
                .frame(width: 140)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    private static func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, !time.isNaN else { return "0:00" }
        let totalSeconds = Int(max(0, time))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
