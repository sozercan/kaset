import SwiftUI

/// Custom logarithmic volume slider view with decibel indicators and gain boost toggle.
struct SpotlightVolumeSliderView: View {
    @Binding var volume: Double
    @Binding var isMuted: Bool

    @State private var isBoostActive = false

    private var decibelText: String {
        if self.isMuted || self.volume == 0 {
            return "-∞ dB"
        }
        let db = 20.0 * log10(max(0.001, self.volume))
        return String(format: "%.1f dB", db + (self.isBoostActive ? 3.0 : 0.0))
    }

    var body: some View {
        HStack(spacing: 16) {
            // Mute Button Toggle
            Button(action: {
                self.isMuted.toggle()
            }, label: {
                Image(systemName: self.isMuted || self.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.body)
                    .foregroundStyle(self.isMuted ? Color.red : Color.secondary)
            })
            .buttonStyle(.plain)
            .help("Mute / Unmute Volume")

            // Slider Lane
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { self.isMuted ? 0.0 : self.volume },
                        set: { newValue in
                            self.isMuted = (newValue == 0)
                            self.volume = newValue
                        }
                    ),
                    in: 0.0 ... 1.0
                )
                .tint(self.isBoostActive ? Color.orange : Color.primary)

                HStack {
                    Text("0%")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(self.decibelText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(self.isBoostActive ? "125%" : "100%")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 180)

            // Gain Boost Toggle Button
            Button(action: {
                self.isBoostActive.toggle()
            }, label: {
                Text("+3dB")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(self.isBoostActive ? Color.orange : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(self.isBoostActive ? AnyShapeStyle(Color.orange.opacity(0.15)) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            })
            .buttonStyle(.plain)
            .help("Toggle +3dB Audio Gain Boost")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
