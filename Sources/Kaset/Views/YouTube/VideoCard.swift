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
        if let percent = self.video.watchedPercent {
            parts.append(String(
                localized: "Watched \(percent)%",
                comment: "Accessibility label for a partially-watched video card"
            ))
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
            // Cards render at ≤320 pt wide (~640 px @2x). ImageCache doubles
            // targetSize for Retina, so 320×180 → a 640 px decode that matches
            // the displayed size. The previous 640×360 decoded at 1280 px — ~4×
            // the pixels — wasting CPU on first paint and thrashing the 50 MB
            // memory cache (fewer images fit → re-decode on scroll).
            targetSize: CGSize(width: 320, height: 180)
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
        .overlay(alignment: .bottom) {
            if let percent = self.video.watchedPercent {
                self.watchedProgressBar(percent: percent)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            self.badge
        }
    }

    /// Thin red resume-progress bar pinned flush to the thumbnail's bottom edge.
    /// Clipped by the parent's rounded corners. Exposed as its own labeled
    /// accessibility element so consumers that combine children (the related
    /// rail and list rows) announce the watched percent; `VideoCard` overrides
    /// this with its own curated label, which already includes it.
    @ViewBuilder
    private func watchedProgressBar(percent: Int) -> some View {
        let fraction = CGFloat(min(max(percent, 0), 100)) / 100
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.white.opacity(0.3))
            Rectangle()
                .fill(.red)
                .scaleEffect(x: fraction, anchor: .leading)
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel(Text(
            "Watched \(percent)%",
            comment: "Accessibility label describing how much of a video has been watched"
        ))
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
            publishedText: "1 year ago",
            watchedPercent: 65
        )
    )
    .frame(width: 320)
    .padding()
}
