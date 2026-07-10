import SwiftUI

// MARK: - VideoRowView

/// Horizontal list row for a YouTube video (search results, related lists).
struct VideoRowView: View {
    let video: YouTubeVideo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VideoThumbnailView(video: self.video, targetSize: CGSize(width: 160, height: 90))
                .frame(width: 160)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.video.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let channelName = self.video.channelName {
                    Text(channelName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                let meta = [self.video.viewCountText, self.video.publishedText].compactMap(\.self)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ChannelRowView

/// List row for a YouTube channel (search results).
struct ChannelRowView: View {
    let channel: YouTubeChannel

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(
                url: self.channel.thumbnailURL,
                targetSize: CGSize(width: 48, height: 48)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: 48, height: 48)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.channel.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                let meta = [self.channel.handle, self.channel.subscriberCountText]
                    .compactMap(\.self)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let snippet = self.channel.descriptionSnippet {
                    Text(snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - YouTubePlaylistRowView

/// List row for a YouTube playlist (search results, library lists).
struct YouTubePlaylistRowView: View {
    let playlist: YouTubePlaylist

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CachedAsyncImage(
                url: self.playlist.thumbnailURL,
                targetSize: CGSize(width: 160, height: 90)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "list.and.film")
                            .foregroundStyle(.tertiary)
                    }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(width: 160)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if let videoCountText = self.playlist.videoCountText {
                    Text(videoCountText)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: .rect(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(self.playlist.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let channelName = self.playlist.channelName {
                    Text(channelName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("Playlist", comment: "Kind label on playlist rows")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - YouTubePlaylistCard

/// Grid card for a YouTube playlist: 16:9 thumbnail with a count badge,
/// title, and channel line (matches `VideoCard`'s layout).
struct YouTubePlaylistCard: View {
    let playlist: YouTubePlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(
                url: self.playlist.thumbnailURL,
                targetSize: CGSize(width: 320, height: 180)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "list.and.film")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                    }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if let videoCountText = self.playlist.videoCountText {
                    Text(videoCountText)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: .rect(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(self.playlist.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let channelName = self.playlist.channelName {
                    Text(channelName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
