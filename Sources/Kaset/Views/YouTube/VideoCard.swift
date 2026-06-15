import SwiftUI

// MARK: - VideoCard

/// Grid card for a YouTube video: 16:9 thumbnail with duration badge,
/// title, and channel/meta lines.
struct VideoCard: View {
    let video: YouTubeVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoThumbnailView(video: self.video)

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

                if let metaText = self.metaText {
                    Text(metaText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityText)
    }

    private var metaText: String? {
        let parts = [self.video.viewCountText, self.video.publishedText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [self.video.title]
        if let channelName = self.video.channelName {
            parts.append(channelName)
        }
        if let metaText = self.metaText {
            parts.append(metaText)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - VideoThumbnailView

/// 16:9 video thumbnail with a duration (or LIVE) badge.
struct VideoThumbnailView: View {
    let video: YouTubeVideo

    var body: some View {
        CachedAsyncImage(
            url: self.video.thumbnailURL,
            targetSize: CGSize(width: 640, height: 360)
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            self.badge
        }
    }

    @ViewBuilder
    private var badge: some View {
        if self.video.isLive {
            Text("LIVE", comment: "Badge on live stream thumbnails")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.red.opacity(0.9), in: .rect(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(6)
        } else if let lengthText = self.video.lengthText {
            Text(lengthText)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.75), in: .rect(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(6)
        }
    }
}

#Preview {
    VideoCard(
        video: YouTubeVideo(
            videoId: "preview",
            title: "A Very Interesting Video About Swift Concurrency and Other Things",
            channelName: "Apple Developer",
            lengthText: "28:01",
            viewCountText: "29K views",
            publishedText: "1 year ago"
        )
    )
    .frame(width: 320)
    .padding()
}
