import SwiftUI

// MARK: - YouTubeHomeView

/// The YouTube home (recommended) feed: an adaptive grid of video cards.
struct YouTubeHomeView: View {
    let viewModel: YouTubeHomeViewModel

    private static let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16),
    ]

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                self.loadingGrid
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
                if self.viewModel.videos.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No recommendations yet"), systemImage: "play.rectangle")
                    } description: {
                        Text("Watch some videos to build your feed.", comment: "Empty YouTube home feed description")
                    }
                } else {
                    self.feedGrid
                }
            }
        }
        .navigationTitle(Text("Home", comment: "YouTube home feed title"))
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.homeGrid)
        .task {
            await self.viewModel.load()
        }
    }

    private var feedGrid: some View {
        ScrollView {
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
                        .gridCellColumns(1)
                        .task {
                            await self.viewModel.loadMore()
                        }
                }
            }
            .padding(.vertical, 20)
        }
        // Edge-to-edge with a resting inset so the grid extends under the
        // floating glass sidebar.
        .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
    }

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(0 ..< 12, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonView.rectangle(cornerRadius: 8)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                        SkeletonView.rectangle(cornerRadius: 4)
                            .frame(width: 220, height: 12)
                        SkeletonView.rectangle(cornerRadius: 4)
                            .frame(width: 140, height: 10)
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
        .disabled(true)
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let homeGrid = "youtubeContent.homeGrid"
}
