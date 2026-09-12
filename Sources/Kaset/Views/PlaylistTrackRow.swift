import SwiftUI

// MARK: - PlaylistTrackRow

/// A single track row in a playlist or album detail view.
///
/// Shows track number/now-playing indicator, thumbnail (for non-album views),
/// title, artist links or subtitle, like button, and duration.
/// Artist names are rendered as clickable navigation links when they have
/// navigable IDs; non-navigable artists fall back to plain text.
@available(macOS 26.0, *)
struct PlaylistTrackRow<Menu: View>: View {
    let track: Song
    let index: Int
    let isAlbum: Bool
    let subtitle: String?
    let artists: [Artist]?
    let allowsLikeActions: Bool
    let onPlay: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovered: Bool = false
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        self.rowContent
            .background { self.playbackButton }
            .onHover { hovering in self.isHovered = hovering }
            .contextMenu { self.menu() }
    }

    private var rowContent: some View {
        let isCurrent = self.playerService.currentTrack?.videoId == self.track.videoId

        return HStack(spacing: 12) {
            Group {
                if isCurrent {
                    NowPlayingIndicator(isPlaying: self.playerService.isPlaying, size: 14)
                } else {
                    Text("\(self.index + 1)")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, alignment: .trailing)
            .allowsHitTesting(false)

            if !self.isAlbum {
                CachedAsyncImage(url: self.track.thumbnailURL, targetSize: CGSize(width: 40, height: 40)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 4))
                .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(self.track.title)
                        .font(.system(size: 14))
                        .foregroundStyle(isCurrent ? .red : .primary)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                    if self.track.isExplicit == true {
                        ExplicitBadge()
                    }
                }
                .allowsHitTesting(false)
                if let subtitle = self.subtitle {
                    if self.hasNavigableArtists {
                        self.artistLinksView
                    } else {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LikeButton(song: self.track, isRowHovered: self.isHovered, allowsActions: self.allowsLikeActions)
                .disabled(!self.track.isPlayable)
                .allowsHitTesting(self.allowsLikeActions && self.track.isPlayable)

            Text(self.track.durationDisplay)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .trailing)
                .allowsHitTesting(false)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .opacity(self.track.isPlayable ? 1 : 0.5)
    }

    private var playbackButton: some View {
        Button(action: self.onPlay) {
            Color.clear
                .contentShape(Rectangle())
        }
        .buttonStyle(.interactiveRow(cornerRadius: 6))
        .disabled(!self.track.isPlayable)
        .accessibilityLabel(Text(verbatim: self.playbackAccessibilityLabel))
        .accessibilityHint(Text(String(localized: "Play")))
    }

    private var playbackAccessibilityLabel: String {
        guard let subtitle = self.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty
        else { return self.track.title }

        return "\(self.track.title), \(subtitle)"
    }

    private var hasNavigableArtists: Bool {
        self.artists?.contains(where: \.hasNavigableId) ?? false
    }

    @ViewBuilder
    private var artistLinksView: some View {
        let artists = self.artists ?? []

        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                if artist.hasNavigableId {
                    HoverUnderlineNavigationLink(
                        value: artist,
                        title: artist.name,
                        font: .system(size: 12),
                        foregroundStyle: .secondary
                    )
                } else {
                    Text(artist.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }

                if index < artists.count - 1 {
                    Text(verbatim: ", ")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }

            Spacer(minLength: 0)
        }
    }
}
