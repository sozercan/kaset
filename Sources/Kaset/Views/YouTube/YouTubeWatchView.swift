import SwiftUI

// MARK: - YouTubeWatchView

/// Watch page for a YouTube video.
///
/// M2: metadata + related list with a placeholder surface; the extracted
/// WebView video surface and native controls land with the playback
/// milestone (M3), which docks into the placeholder area.
struct YouTubeWatchView: View {
    let video: YouTubeVideo

    @State private var viewModel: YouTubeWatchViewModel

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self._viewModel = State(
            initialValue: YouTubeWatchViewModel(video: video, client: client)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.videoSurfacePlaceholder

                self.metadataSection

                Divider()

                self.relatedSection
            }
            .padding(20)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text(self.video.title))
        .task {
            await self.viewModel.load()
        }
    }

    // MARK: - Video Surface (placeholder until M3)

    private var videoSurfacePlaceholder: some View {
        Rectangle()
            .fill(.black)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 44))
                    Text("Video playback is coming soon.", comment: "Placeholder in the watch view before playback ships")
                        .font(.callout)
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchSurface)
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.viewModel.data.videoTitle ?? self.video.title)
                .font(.title2.bold())
                .lineLimit(3)

            let meta = [
                self.viewModel.data.viewCountText ?? self.video.viewCountText,
                self.viewModel.data.publishedText ?? self.video.publishedText,
            ].compactMap(\.self)
            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let channel = self.viewModel.data.channel {
                NavigationLink(value: YouTubeRoute.channel(channelId: channel.channelId)) {
                    HStack(spacing: 10) {
                        CachedAsyncImage(
                            url: channel.thumbnailURL,
                            targetSize: CGSize(width: 72, height: 72)
                        ) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle().fill(.quaternary)
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(.circle)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            if let subscriberCountText = channel.subscriberCountText {
                                Text(subscriberCountText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Related

    @ViewBuilder
    private var relatedSection: some View {
        Text("Related", comment: "Related videos section header")
            .font(.title3.bold())

        switch self.viewModel.loadingState {
        case .idle, .loading:
            ForEach(0 ..< 5, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonView.rectangle(cornerRadius: 8)
                        .frame(width: 160, height: 90)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonView.rectangle(cornerRadius: 4)
                            .frame(width: 240, height: 12)
                        SkeletonView.rectangle(cornerRadius: 4)
                            .frame(width: 140, height: 10)
                    }
                    Spacer()
                }
            }
        case let .error(error):
            Text(error.message)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .loaded, .loadingMore:
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(self.viewModel.data.related) { related in
                    NavigationLink(value: YouTubeRoute.watch(related)) {
                        VideoRowView(video: related)
                    }
                    .buttonStyle(.interactiveRow)
                }
            }
        }
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let watchSurface = "youtubeContent.watchSurface"
}
