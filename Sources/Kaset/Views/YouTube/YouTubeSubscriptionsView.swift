import SwiftUI

// MARK: - YouTubeSubscriptionsView

/// Subscriptions surface: horizontal rail of subscribed channels above the
/// subscriptions feed grid.
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
        // Keyed on the view-model identity so a cold-launch account swap (which
        // rebuilds the model) re-fires the load instead of leaving the fresh,
        // idle model stuck. See YouTubeHomeView for the full rationale.
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
                                .task {
                                    await self.viewModel.loadMore()
                                }
                        }
                    }
                    // Vertical grid: inset its resting content; the channel rail
                    // above keeps its own edge-to-edge track so it slides under
                    // the floating glass sidebar on macOS 26.
                    .padding(.horizontal, DetailContentLayout.horizontalInset)
                }
            }
            .padding(.vertical, 20)
        }
    }

    private var channelRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Outer spacing:0 so the leading/trailing Spacers produce an exact
            // resting inset (no extra HStack spacing inflation); the rail track
            // stays edge-to-edge and slides under the floating glass sidebar.
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: DetailContentLayout.horizontalInset)

                HStack(spacing: 16) {
                    ForEach(self.viewModel.channels) { channel in
                        NavigationLink(value: YouTubeRoute.channel(channelId: channel.channelId)) {
                            VStack(spacing: 6) {
                                CachedAsyncImage(
                                    url: channel.thumbnailURL,
                                    targetSize: CGSize(width: 112, height: 112)
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

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let subscriptionsRail = "youtubeContent.subscriptionsRail"
}
