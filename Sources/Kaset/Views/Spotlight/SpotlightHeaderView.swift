import SwiftUI

/// Top navigation header for the Now-Playing Spotlight presentation view.
struct SpotlightHeaderView: View {
    let onDismiss: () -> Void
    let onAirPlay: () -> Void

    var body: some View {
        HStack {
            // Left brand pill badge
            HStack(spacing: 6) {
                Image(systemName: "music.note.house.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("SPOTLIGHT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())

            Spacer()

            // Header Action Buttons
            HStack(spacing: 16) {
                Button(action: self.onAirPlay) {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("AirPlay & Wireless Audio")

                Button(action: self.onDismiss) {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Spotlight View")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}
