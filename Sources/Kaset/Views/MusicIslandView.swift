import SwiftUI

@available(macOS 26.0, *)
struct MusicIslandView: View {
    @Environment(NowPlayingSnapshotStore.self) private var snapshots
    @State private var isHovered = false

    let metrics: MusicIslandLayoutMetrics
    let openMainWindow: @MainActor () -> Void

    var body: some View {
        let snapshot = self.snapshots.snapshot

        VStack(spacing: 0) {
            // Reserve the real camera housing depth so content starts below the notch.
            Color.clear
                .frame(height: self.metrics.notchDepth)

            HStack(alignment: .center, spacing: 12) {
                self.artwork(snapshot: snapshot)

                VStack(alignment: .leading, spacing: 2) {
                    self.primaryText(snapshot: snapshot)
                    self.secondaryText(snapshot: snapshot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: self.metrics.contentHeight)
        }
        .frame(width: self.metrics.windowWidth, height: self.metrics.windowHeight)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
                .fill(.black)
        )
        .overlay(alignment: .topTrailing) {
            if self.isHovered {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.top, self.metrics.notchDepth + 8)
                    .padding(.trailing, 12)
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
                    CassetteIcon(size: 34)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.68))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            CassetteIcon(size: 44)
        }
    }

    @ViewBuilder
    private func primaryText(snapshot: NowPlayingSnapshot) -> some View {
        if let line = snapshot.currentLyricLine {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .contentTransition(.numericText())
        } else {
            Text(snapshot.track?.title ?? "Kaset")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }

    @ViewBuilder
    private func secondaryText(snapshot: NowPlayingSnapshot) -> some View {
        if let romanizedText = snapshot.currentLyricLine?.romanizedText {
            Text(romanizedText)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .contentTransition(.numericText())
        } else {
            Text(snapshot.track?.artist ?? "Not Playing")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}
