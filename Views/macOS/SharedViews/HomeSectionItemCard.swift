import SwiftUI

// MARK: - HomeSectionItemCard

/// Reusable card view for home section items (songs, playlists, albums, artists).
@available(macOS 26.0, *)
struct HomeSectionItemCard: View {
    let item: HomeSectionItem
    let rank: Int?
    let action: () -> Void

    /// Card dimensions.
    private static let cardWidth: CGFloat = 160
    private static let cardHeight: CGFloat = 160

    /// Hover state for play overlay.
    @State private var isHovering = false

    init(item: HomeSectionItem, rank: Int? = nil, action: @escaping () -> Void) {
        self.item = item
        self.rank = rank
        self.action = action
    }

    var body: some View {
        Button(action: self.action) {
            if let rank {
                self.chartContent(rank: rank)
            } else {
                self.regularContent
            }
        }
        .buttonStyle(.interactiveCard)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) {
                self.isHovering = hovering
            }
        }
    }

    // MARK: - Regular Card Content

    private var regularContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.thumbnail
            self.titleAndSubtitle
        }
    }

    // MARK: - Chart Card Content

    private func chartContent(rank: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 8) {
                self.thumbnail
                self.titleAndSubtitle
            }

            // Rank badge overlay with adaptive styling
            Text("\(rank)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(0.8), radius: 4, x: 0, y: 1)
                .padding(.leading, 8)
                .padding(.bottom, 60)
        }
    }

    // MARK: - Shared Components

    private var thumbnail: some View {
        ZStack {
            CachedAsyncImage(url: self.item.thumbnailURL?.highQualityThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .clipShape(.rect(cornerRadius: 8))

            // Play overlay on hover (for songs)
            if case .song = self.item, self.isHovering {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .offset(x: 2)
                    }
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var titleAndSubtitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: Self.cardWidth, alignment: .leading)

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.cardWidth, alignment: .leading)
            }
        }
    }
}

#Preview {
    let song = Song(
        id: "test",
        title: "Test Song with a Very Long Title That Should Wrap",
        artists: [Artist(id: "artist1", name: "Test Artist")],
        videoId: "testVideo"
    )
    HStack {
        HomeSectionItemCard(item: .song(song)) {
            // No-op for preview
        }
        HomeSectionItemCard(item: .song(song), rank: 1) {
            // No-op for preview
        }
    }
    .padding()
}
