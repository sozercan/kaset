import SwiftUI

// MARK: - HomeSectionItemCard

/// Reusable card view for home section items (songs, playlists, albums, artists).
@available(macOS 26.0, *)
struct HomeSectionItemCard: View {
    let item: HomeSectionItem
    let rank: Int?
    let action: () -> Void

    /// Card dimensions.
    private static let squareThumbnailSize = CGSize(width: 160, height: 160)
    private static let videoThumbnailSize = CGSize(width: 284, height: 160)

    /// Hover state for play overlay.
    @State private var isHovering = false
    @State private var failedThumbnailURLs: Set<URL> = []

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
        .onChange(of: self.item.id) { _, _ in
            self.failedThumbnailURLs = []
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
            self.thumbnailBackground

            if let url = self.thumbnailURL {
                CachedAsyncImage(url: url, targetSize: self.thumbnailSize, onFailure: self.thumbnailFailureHandler) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: self.thumbnailContentMode)
                } placeholder: {
                    self.placeholderView
                }
            } else {
                self.placeholderView
            }
        }
        .frame(width: self.thumbnailSize.width, height: self.thumbnailSize.height)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
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
        .overlay(alignment: .topTrailing) {
            // Favorite heart in the corner for songs
            if case let .song(song) = self.item {
                LikeButton(song: song, isRowHovered: self.isHovering)
                    .padding(6)
            }
        }
    }

    @ViewBuilder
    private var thumbnailBackground: some View {
        if self.isVideoSong {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        }
    }

    private var thumbnailURL: URL? {
        self.thumbnailURLs.first { !self.failedThumbnailURLs.contains($0) }
    }

    private var thumbnailURLs: [URL] {
        if self.isVideoSong {
            return Self.uniqueURLs([
                self.videoThumbnailURL,
                self.item.thumbnailURL?.highQualityThumbnailURL,
                self.videoFallbackThumbnailURL,
            ])
        }

        return Self.uniqueURLs([self.item.thumbnailURL?.highQualityThumbnailURL])
    }

    private var thumbnailFailureHandler: (@MainActor () -> Void)? {
        guard let thumbnailURL,
              self.hasFallback(after: thumbnailURL)
        else {
            return nil
        }

        return {
            self.failedThumbnailURLs.insert(thumbnailURL)
        }
    }

    private var videoThumbnailURL: URL? {
        guard case let .song(song) = self.item else { return nil }
        return song.wideHighQualityThumbnailURL
    }

    private var videoFallbackThumbnailURL: URL? {
        guard case let .song(song) = self.item else { return nil }
        return song.fallbackThumbnailURL
    }

    private var thumbnailContentMode: ContentMode {
        self.isVideoSong ? .fit : .fill
    }

    private func hasFallback(after url: URL) -> Bool {
        guard let index = self.thumbnailURLs.firstIndex(of: url) else { return false }
        let fallbackURLs = self.thumbnailURLs.dropFirst(index + 1)
        return fallbackURLs.contains { !self.failedThumbnailURLs.contains($0) }
    }

    private static func uniqueURLs(_ urls: [URL?]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { url in
            guard let url, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    /// Placeholder view for items without thumbnails.
    /// Uses the API-provided color for mood/genre cards, or a gradient based on the title.
    private var placeholderView: some View {
        let gradient = self.gradientForItem
        return Rectangle()
            .fill(gradient)
            .overlay {
                // Show a contextual icon based on item type
                Image(systemName: self.placeholderIcon)
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.8))
            }
    }

    /// Returns appropriate icon for the placeholder based on item type.
    private var placeholderIcon: String {
        switch self.item {
        case .song: self.isVideoSong ? "play.rectangle" : "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .artist: "person.fill"
        }
    }

    /// Generates a gradient for the card.
    /// Uses API-provided color (from description) for mood cards, or title-based hash.
    private var gradientForItem: LinearGradient {
        // Check if this is a mood card with color in description
        if case let .playlist(playlist) = item,
           let colorHex = playlist.description,
           colorHex.hasPrefix("#"),
           let color = Color(hex: colorHex)
        {
            // Create a gradient from the API color
            return LinearGradient(
                colors: [color, color.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        // Fallback to title-based gradient
        return Self.gradientForTitle(self.item.title)
    }

    /// Generates a consistent gradient color based on the title string.
    private static func gradientForTitle(_ title: String) -> LinearGradient {
        let hash = abs(title.hashValue)
        let hue1 = Double(hash % 360) / 360.0
        let hue2 = (hue1 + 0.1).truncatingRemainder(dividingBy: 1.0)

        let color1 = Color(hue: hue1, saturation: 0.6, brightness: 0.5)
        let color2 = Color(hue: hue2, saturation: 0.7, brightness: 0.35)

        return LinearGradient(
            colors: [color1, color2],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var titleAndSubtitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(self.item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if case let .song(song) = self.item, song.isExplicit == true {
                    ExplicitBadge()
                }
            }
            .frame(width: self.cardWidth, alignment: .leading)

            if let subtitle = self.item.homeCardSubtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: self.cardWidth, alignment: .leading)
            }
        }
    }

    private var cardWidth: CGFloat {
        self.thumbnailSize.width
    }

    private var thumbnailSize: CGSize {
        self.isVideoSong ? Self.videoThumbnailSize : Self.squareThumbnailSize
    }

    private var isVideoSong: Bool {
        guard case let .song(song) = self.item else { return false }

        if let musicVideoType = song.musicVideoType {
            return musicVideoType != .atv
        }

        let subtitle = song.artistsDisplay.lowercased()
        return subtitle.contains("views") || subtitle.contains("video")
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
