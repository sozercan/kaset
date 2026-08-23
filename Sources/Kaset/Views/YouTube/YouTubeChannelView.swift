import SwiftUI

/// A YouTube channel page: header plus the landing-tab video grid.
struct YouTubeChannelView: View {
    @State private var viewModel: YouTubeChannelViewModel

    private static let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16),
    ]

    init(channelId: String, client: any YouTubeClientProtocol) {
        self._viewModel = State(
            initialValue: YouTubeChannelViewModel(channelId: channelId, client: client)
        )
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView()
            case let .error(error):
                ErrorView(
                    title: error.title,
                    message: error.message,
                    isRetryable: error.isRetryable
                ) {
                    Task {
                        await self.viewModel.load()
                    }
                }
            case .loaded, .loadingMore:
                if let detail = self.viewModel.detail {
                    self.content(for: detail)
                }
            }
        }
        .navigationTitle(Text(self.viewModel.detail?.channel.name ?? ""))
        .task {
            await self.viewModel.load()
        }
    }

    private func content(for detail: YouTubeChannelDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                self.header(for: detail.channel)

                if detail.videos.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No videos"), systemImage: "play.rectangle")
                    }
                } else {
                    LazyVGrid(columns: Self.columns, spacing: 20) {
                        ForEach(detail.videos) { video in
                            NavigationLink(value: YouTubeRoute.watch(video)) {
                                VideoCard(video: video)
                            }
                            .buttonStyle(.interactiveCard)
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
        // Edge-to-edge with a resting inset so content extends under the
        // floating glass sidebar.
        .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
    }

    private func header(for channel: YouTubeChannel) -> some View {
        HStack(spacing: 16) {
            CachedAsyncImage(
                url: channel.thumbnailURL,
                targetSize: CGSize(width: 80, height: 80)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: 80, height: 80)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.title.bold())
                    .lineLimit(1)

                let meta = [channel.handle, channel.subscriberCountText].compactMap(\.self)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let description = channel.descriptionSnippet, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
    }
}
