import SwiftUI

struct YouTubeSubscriptionsView: View {
    let viewModel: YouTubeSubscriptionsViewModel

    private static let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16),
    ]

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
                        await self.viewModel.refresh()
                    }
                }
            case .loaded, .loadingMore:
                self.content
            }
        }
        .navigationTitle(Text("Subscriptions", comment: "YouTube subscriptions title"))
        .task(id: ObjectIdentifier(self.viewModel)) {
            await self.viewModel.load()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !self.viewModel.channels.isEmpty {
                    self.channelRail
                }

                if self.viewModel.videos.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No subscription videos"), systemImage: "rectangle.stack.badge.play")
                    } description: {
                        Text("Videos from channels you subscribe to appear here.", comment: "Empty subscriptions feed description")
                    }
                    .padding(.horizontal, DetailContentLayout.horizontalInset)
                } else {
                    LazyVGrid(columns: Self.columns, spacing: 20) {
                        ForEach(self.viewModel.videos) { video in
                            NavigationLink(value: YouTubeRoute.watch(video)) {
                                VideoCard(video: video)
                            }
                            .buttonStyle(.interactiveCard)
                        }

                        if self.viewModel.hasMoreVideos {
                            ProgressView()
                                .controlSize(.small)
                                .task(id: self.viewModel.paginationTrigger) {
                                    await self.viewModel.loadMore()
                                }
                        }
                    }
                    .padding(.horizontal, DetailContentLayout.horizontalInset)
                }
            }
            .padding(.vertical, 20)
        }
    }

    private var channelRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: DetailContentLayout.horizontalInset)

                HStack(spacing: 16) {
                    ForEach(self.viewModel.channels) { channel in
                        NavigationLink(value: YouTubeRoute.channel(channelId: channel.channelId)) {
                            VStack(spacing: 6) {
                                CachedAsyncImage(
                                    url: channel.thumbnailURL,
                                    targetSize: CGSize(width: 56, height: 56)
                                ) { image in
                                    image
                                        .resizable()
                                        .scaledToFill()
                                } placeholder: {
                                    Circle()
                                        .fill(.quaternary)
                                        .overlay {
                                            Image(systemName: "person.fill")
                                                .foregroundStyle(.tertiary)
                                        }
                                }
                                .frame(width: 56, height: 56)
                                .clipShape(.circle)

                                Text(channel.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: 72)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(channel.name)
                    }
                }

                Spacer()
                    .frame(width: DetailContentLayout.horizontalInset)
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.subscriptionsRail)
    }
}

extension AccessibilityID.YouTubeContent {
    static let subscriptionsRail = "youtubeContent.subscriptionsRail"
}
