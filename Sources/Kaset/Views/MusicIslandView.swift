import SwiftUI

@available(macOS 26.0, *)
struct MusicIslandView: View {
    @Environment(NowPlayingSnapshotStore.self) private var snapshots
    @State private var isHovered = false

    let openMainWindow: @MainActor () -> Void

    var body: some View {
        let snapshot = self.snapshots.snapshot

        HStack(alignment: .top, spacing: 14) {
            self.artwork(snapshot: snapshot)

            VStack(alignment: .leading, spacing: 3) {
                if let line = snapshot.currentLyricLine {
                    Text(line.text.isEmpty ? "♪" : line.text)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())

                    if let romanizedText = line.romanizedText {
                        Text(romanizedText)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                } else {
                    Text(snapshot.track?.title ?? "Kaset")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(snapshot.track?.artist ?? "Not Playing")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 24)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(minWidth: 220, idealWidth: 360, maxWidth: 498)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous)
                .fill(.black)
                .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 8)
        )
        .overlay(alignment: .topTrailing) {
            if self.isHovered {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isHovered = hovering
            }
        }
        .onTapGesture {
            self.openMainWindow()
        }
    }

    @ViewBuilder
    private func artwork(snapshot: NowPlayingSnapshot) -> some View {
        if let url = snapshot.track?.artworkURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if phase.error != nil {
                    CassetteIcon(size: 48)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            CassetteIcon(size: 64)
        }
    }
}
